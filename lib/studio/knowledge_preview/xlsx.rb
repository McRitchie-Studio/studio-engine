# frozen_string_literal: true

require "nokogiri"
require "set"
require_relative "zip"
require_relative "number_format"

module Studio
  module KnowledgePreview
    # Reads the first rows of every sheet in an .xlsx workbook as display text.
    #
    # A formula cell is read as its CACHED value (the <v> Excel wrote when the
    # file was last calculated); nothing is evaluated here. A formula saved
    # with no cached value reads as blank. Numbers are rendered through their
    # number format (NumberFormat), so dates, percentages and currency read as
    # they do in Excel.
    #
    # Memory stays bounded by the caps, not by the file. Each sheet is pulled
    # through a streaming XML reader that stops at the first row past
    # `max_rows`, so a sheet of a million rows costs what its first rows cost.
    # Shared strings are read AFTER the sheets and only the ones a kept cell
    # points at are stored, so a workbook with a huge string table costs a
    # scan, not a copy.
    #
    # XML is read with entity substitution and DTD loading off and the network
    # barred, so a workbook cannot make the server read a file or a URL.
    class Xlsx
      Workbook = Struct.new(:sheets, :omitted_sheets, keyword_init: true)

      WORKBOOK_PATH = "xl/workbook.xml"
      WORKBOOK_RELS = "xl/_rels/workbook.xml.rels"
      WORKSHEET_TYPE = %r{/worksheet\z}
      SHARED_STRINGS_TYPE = %r{/sharedStrings\z}
      STYLES_TYPE = %r{/styles\z}
      TEXT_NODE_TYPES = [
        Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_CDATA,
        Nokogiri::XML::Reader::TYPE_WHITESPACE, Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE
      ].freeze
      ELEMENT     = Nokogiri::XML::Reader::TYPE_ELEMENT
      END_ELEMENT = Nokogiri::XML::Reader::TYPE_END_ELEMENT
      XML_OPTIONS = Nokogiri::XML::ParseOptions::NONET

      # A cell pointing into the shared string table, resolved after the
      # sheets are read.
      SharedRef = Struct.new(:index)

      def self.read(bytes, max_rows:, max_columns:, max_sheets:, max_cells:, inflate_cap:)
        new(bytes, max_rows: max_rows, max_columns: max_columns, max_sheets: max_sheets,
                   max_cells: max_cells, inflate_cap: inflate_cap).read
      end

      def initialize(bytes, max_rows:, max_columns:, max_sheets:, max_cells:, inflate_cap:)
        @zip = Zip.new(bytes, inflate_cap: inflate_cap)
        @max_rows = max_rows
        @max_columns = max_columns
        @max_sheets = max_sheets
        # Filled cells still allowed across the WHOLE workbook: the page is one
        # response, and twenty sheets each at the row and column caps would be
        # half a million cells of it.
        @cells_left = max_cells
        @shared_wanted = Set.new
      end

      def read
        raise Unreadable, "it is not an Excel workbook" unless @zip.entry?(WORKBOOK_PATH)

        listed = read_workbook
        relationships = read_relationships
        read_styles(relationships.values.find { |rel| rel[:type].match?(STYLES_TYPE) }&.fetch(:target) || "xl/styles.xml")

        worksheets = listed.filter_map do |sheet|
          rel = relationships[sheet[:rid]]
          next unless rel && rel[:type].match?(WORKSHEET_TYPE)

          sheet.merge(path: rel[:target])
        end
        raise Unreadable, "it has no worksheets" if worksheets.empty?

        sheets = []
        worksheets.first(@max_sheets).each do |sheet|
          break if @cells_left <= 0

          sheets << read_sheet(sheet)
        end
        resolve_shared_strings(
          sheets,
          relationships.values.find { |rel| rel[:type].match?(SHARED_STRINGS_TYPE) }&.fetch(:target) || "xl/sharedStrings.xml"
        )
        Workbook.new(sheets: sheets, omitted_sheets: worksheets.size - sheets.size)
      rescue Nokogiri::XML::SyntaxError, Zlib::Error
        raise Unreadable, "its contents are damaged"
      end

      private

      # --- the workbook's parts -------------------------------------------------

      def read_workbook
        sheets = []
        @date1904 = false
        each_node(WORKBOOK_PATH) do |node|
          next unless node.node_type == ELEMENT

          case node.local_name
          when "workbookPr"
            @date1904 = %w[1 true].include?(node.attribute("date1904").to_s)
          when "sheet"
            sheets << { name: node.attribute("name").to_s,
                        rid: relationship_id(node),
                        hidden: %w[hidden veryHidden].include?(node.attribute("state").to_s) }
          end
        end
        sheets
      end

      # The relationship attribute is r:id by convention, but the prefix is the
      # writer's choice; the local name is not.
      def relationship_id(node)
        node.attributes.find { |name, _| name == "id" || name.end_with?(":id") }&.last
      end

      def read_relationships
        relationships = {}
        each_node(WORKBOOK_RELS) do |node|
          next unless node.node_type == ELEMENT && node.local_name == "Relationship"

          target = node.attribute("Target").to_s
          path = target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}"
          relationships[node.attribute("Id").to_s] = { type: node.attribute("Type").to_s, target: path }
        end
        relationships
      end

      # cellXfs is the list a cell's `s` attribute indexes; each entry names a
      # numFmtId, which is a built-in format or one of this workbook's own.
      def read_styles(path)
        custom = {}
        format_ids = []
        in_cell_formats = false
        each_node(path) do |node|
          case node.node_type
          when ELEMENT
            case node.local_name
            when "numFmt"
              custom[node.attribute("numFmtId").to_i] = node.attribute("formatCode").to_s
            when "cellXfs" then in_cell_formats = !node.empty_element?
            when "xf" then format_ids << node.attribute("numFmtId").to_i if in_cell_formats
            end
          when END_ELEMENT
            in_cell_formats = false if node.local_name == "cellXfs"
          end
        end
        @style_sections = format_ids.map { |id| NumberFormat.tokenize(NumberFormat.code_for(id, custom)) }
        @general = NumberFormat.tokenize("General")
      end

      # --- one sheet --------------------------------------------------------------

      def read_sheet(sheet)
        rows = {}
        truncated_rows = false
        truncated_columns = false
        row_limit = @max_rows
        row_number = 0
        column = 0
        cell = nil
        capture = nil
        text = +""

        each_node(sheet[:path]) do |node|
          case node.node_type
          when ELEMENT
            case node.local_name
            when "row"
              previous = row_number
              row_number = node.attribute("r")&.to_i || (row_number + 1)
              column = 0
              if row_number > @max_rows
                truncated_rows = true
                break
              elsif @cells_left <= 0
                # The workbook's cell budget ran out on the row before this one.
                truncated_rows = true
                row_limit = previous
                break
              end
            when "c"
              reference = node.attribute("r")
              column = reference ? column_index(reference) : column + 1
              cell = node.empty_element? ? nil : { type: node.attribute("t"), style: node.attribute("s") }
              text = +""
            when "v" then capture = :value unless node.empty_element?
            # <t> is the inline string's text; phonetic runs (<rPh>) are a
            # reading aid, never part of the value.
            when "t" then capture = :value unless node.empty_element? || cell.nil? || cell[:type] != "inlineStr"
            end
          when END_ELEMENT
            case node.local_name
            when "v", "t" then capture = nil
            when "c"
              if cell
                if column > @max_columns
                  truncated_columns = true
                elsif (value = cell_value(cell, text))
                  (rows[row_number] ||= {})[column] = value
                  @cells_left -= 1
                end
              end
              cell = nil
            when "sheetData" then break
            end
          else
            text << node.value.to_s if capture && cell && TEXT_NODE_TYPES.include?(node.node_type)
          end
        end

        Sheet.new(name: sheet[:name], rows: dense(rows), truncated_rows: truncated_rows,
                  truncated_columns: truncated_columns, hidden: sheet[:hidden], row_limit: row_limit)
      end

      def cell_value(cell, text)
        case cell[:type]
        when "s"
          index = Integer(text, exception: false)
          return nil unless index

          @shared_wanted << index
          SharedRef.new(index)
        when "inlineStr", "str", "e", "d"
          text.empty? ? nil : Cell.new(text, false)
        when "b"
          text.empty? ? nil : Cell.new(text == "1" ? "TRUE" : "FALSE", false)
        else
          return nil if text.strip.empty?

          number = Float(text, exception: false)
          return Cell.new(text, false) unless number

          sections = (cell[:style] && @style_sections[cell[:style].to_i]) || @general
          Cell.new(NumberFormat.render(number, sections, date1904: @date1904), true)
        end
      end

      # "BC12" -> 55. Letters are base 26 with no zero digit.
      def column_index(reference)
        reference.to_s.each_char.take_while { |char| char.match?(/[A-Za-z]/) }
                 .reduce(0) { |sum, char| (sum * 26) + (char.upcase.ord - 64) }
      end

      # Sparse {row => {column => cell}} to a rectangle, blank rows and cells
      # kept so the grid lines up with the workbook's own row numbers.
      def dense(rows)
        return [] if rows.empty?

        width = rows.values.flat_map(&:keys).max
        (1..rows.keys.max).map do |number|
          row = rows[number] || {}
          (1..width).map { |column| row[column] }
        end
      end

      # --- shared strings -----------------------------------------------------------

      def resolve_shared_strings(sheets, path)
        strings = @shared_wanted.empty? ? {} : read_shared_strings(path)
        sheets.each do |sheet|
          sheet.rows.each do |row|
            row.map! do |value|
              next value unless value.is_a?(SharedRef)

              string = strings[value.index]
              string.nil? || string.empty? ? nil : Cell.new(string, false)
            end
          end
        end
      end

      def read_shared_strings(path)
        strings = {}
        index = -1
        wanted = false
        capture = false
        phonetic = 0
        text = +""
        last = @shared_wanted.max

        each_node(path) do |node|
          case node.node_type
          when ELEMENT
            case node.local_name
            when "si"
              index += 1
              break if index > last

              wanted = @shared_wanted.include?(index)
              text = +""
              strings[index] = "" if wanted && node.empty_element?
            when "rPh" then phonetic += 1 unless node.empty_element?
            when "t" then capture = wanted && phonetic.zero? && !node.empty_element?
            end
          when END_ELEMENT
            case node.local_name
            when "t" then capture = false
            when "rPh" then phonetic -= 1
            when "si" then strings[index] = text if wanted
            end
          else
            text << node.value.to_s if capture && TEXT_NODE_TYPES.include?(node.node_type)
          end
        end
        strings
      end

      # --- xml ------------------------------------------------------------------------

      # Streams one zip entry through the pull parser. A missing entry yields
      # nothing: styles and shared strings are both optional parts.
      def each_node(path, &block)
        @zip.open(path) do |io|
          Nokogiri::XML::Reader.from_io(io, nil, nil, XML_OPTIONS).each(&block)
        end
      end
    end
  end
end
