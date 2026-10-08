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
    # WHAT BOUNDS THE READ. A workbook is hostile input, and a few kilobytes of
    # it can ask for gigabytes, so every cap here is on a SIZE or a COST and
    # not only on a count:
    #
    #   rows, columns, sheets   each sheet streams through a pull parser that
    #                           stops at the first row past max_rows.
    #   filled cells            max_cells across the workbook.
    #   text per cell           max_cell_chars, applied as the text is read, in
    #                           the sheet and in the shared string table alike.
    #   text in total           max_text_bytes across the workbook, spent once
    #                           per CELL: a shared string is stored once but
    #                           rendered by every cell that points at it.
    #   the rendered grid       max_grid_cells, empty cells included, because
    #                           one value at AX500 is a 25,000-cell rectangle.
    #   number formats          a code is tokenized once per format, never once
    #                           per style, and NumberFormat refuses a code
    #                           longer than Excel allows.
    #   cell references         at most three column letters are read.
    #
    # The sheet that spends the last of a workbook-wide budget is cut at that
    # row and says so; the sheets after it are counted, not rendered.
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

      # Excel's last column is XFD: three letters. A fourth is past any sheet.
      MAX_COLUMN_LETTERS = 3
      # Excel allows 31 characters in a sheet name and 65,490 cell styles;
      # neither list is kept past a generous multiple of that.
      MAX_SHEET_NAME_CHARS = 255
      MAX_STYLES = 65_536
      MAX_LISTED_SHEETS = 10_000
      CUT_MARK = "…"

      # A cell pointing into the shared string table, resolved after the
      # sheets are read.
      SharedRef = Struct.new(:index)
      # A shared string a cell wanted that the text budget had no room to hold.
      OVER_BUDGET = Object.new.freeze
      # One sheet as read: sparse {row => {column => Cell or SharedRef}}.
      Draft = Struct.new(:name, :hidden, :rows, :truncated_rows, :truncated_columns, :row_limit, keyword_init: true)

      def self.read(bytes, **caps)
        new(bytes, **caps).read
      end

      def initialize(bytes, max_rows:, max_columns:, max_sheets:, max_cells:, max_cell_chars:,
                     max_text_bytes:, max_grid_cells:, inflate_cap:)
        @zip = Zip.new(bytes, inflate_cap: inflate_cap)
        @max_rows = max_rows
        @max_columns = max_columns
        @max_sheets = max_sheets
        @max_cell_chars = max_cell_chars
        @max_text_bytes = max_text_bytes
        # The three workbook-wide budgets. The page is one response, so what
        # matters is the whole workbook's cells, text and grid, not one sheet's.
        @cells_left = max_cells
        @text_left = max_text_bytes
        @grid_left = max_grid_cells
        @budget_spent = false
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

        drafts = []
        worksheets.first(@max_sheets).each do |sheet|
          # A budget that cut one sheet has nothing left for the next.
          break if @budget_spent || @cells_left <= 0

          drafts << read_sheet(sheet)
        end
        strings = read_shared_strings(
          relationships.values.find { |rel| rel[:type].match?(SHARED_STRINGS_TYPE) }&.fetch(:target) || "xl/sharedStrings.xml"
        )
        sheets = finish(drafts, strings)
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
            break if sheets.size >= MAX_LISTED_SHEETS

            sheets << { name: clip(node.attribute("name").to_s, MAX_SHEET_NAME_CHARS),
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
      #
      # Only the ids are kept here. A format is tokenized the first time a cell
      # uses it and once only (sections_for): tokenizing per <xf> let five
      # thousand styles on one long format cost a gigabyte.
      def read_styles(path)
        @custom_formats = {}
        @style_formats = []
        @sections = {}
        in_cell_formats = false
        each_node(path) do |node|
          case node.node_type
          when ELEMENT
            case node.local_name
            when "numFmt"
              code = node.attribute("formatCode").to_s
              # A code NumberFormat would refuse is not worth holding either.
              @custom_formats[node.attribute("numFmtId").to_i] = code if code.length <= NumberFormat::MAX_CODE_LENGTH
            when "cellXfs" then in_cell_formats = !node.empty_element?
            when "xf"
              @style_formats << node.attribute("numFmtId").to_i if in_cell_formats && @style_formats.size < MAX_STYLES
            end
          when END_ELEMENT
            in_cell_formats = false if node.local_name == "cellXfs"
          end
        end
      end

      def sections_for(style)
        id = (style && @style_formats[style.to_i]) || 0
        @sections[id] ||= NumberFormat.tokenize(NumberFormat.code_for(id, @custom_formats))
      end

      # --- one sheet --------------------------------------------------------------

      def read_sheet(sheet)
        draft = Draft.new(name: sheet[:name], hidden: sheet[:hidden], rows: {}, truncated_rows: false,
                          truncated_columns: false, row_limit: @max_rows)
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
                draft.truncated_rows = true
                break
              elsif @cells_left <= 0
                # The workbook's cell budget ran out on the row before this one.
                cut(draft, previous + 1)
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
                  draft.truncated_columns = true
                elsif (value = cell_value(cell, text))
                  # Text read here is spent here; a shared string's size is
                  # not known yet and is spent in `finish`.
                  if value.is_a?(Cell) && !spend_text(value.text)
                    cut(draft, row_number)
                    break
                  end
                  (draft.rows[row_number] ||= {})[column] = value
                  @cells_left -= 1
                end
              end
              cell = nil
            when "sheetData" then break
            end
          else
            append(text, node.value) if capture && cell && TEXT_NODE_TYPES.include?(node.node_type)
          end
        end
        draft
      end

      def cell_value(cell, text)
        case cell[:type]
        when "s"
          index = Integer(text, exception: false)
          return nil unless index && index >= 0

          @shared_wanted << index
          SharedRef.new(index)
        when "inlineStr", "str", "e", "d"
          text.empty? ? nil : Cell.new(clipped(text), false)
        when "b"
          text.empty? ? nil : Cell.new(text == "1" ? "TRUE" : "FALSE", false)
        else
          return nil if text.strip.empty?

          number = Float(text, exception: false)
          return Cell.new(clipped(text), false) unless number

          Cell.new(NumberFormat.render(number, sections_for(cell[:style]), date1904: @date1904), true)
        end
      end

      # "BC12" -> 55. Letters are base 26 with no zero digit. Only the first
      # letters are ever looked at: a reference with more than three is past
      # the last column Excel has, and is answered as past max_columns without
      # reading the rest of it.
      def column_index(reference)
        letters = reference.to_s[/\A[A-Za-z]{1,#{MAX_COLUMN_LETTERS + 1}}/].to_s
        return @max_columns + 1 if letters.length > MAX_COLUMN_LETTERS

        letters.each_char.reduce(0) { |sum, char| (sum * 26) + (char.upcase.ord - 64) }
      end

      # --- text sizes -----------------------------------------------------------------

      # Adds to a cell's text while it is being read, and stops one character
      # past the cap: enough to know it overflowed, never the megabyte after.
      def append(text, more)
        room = @max_cell_chars + 1 - text.length
        text << more.to_s[0, room] if room.positive?
      end

      # The text a cell keeps: whole, or cut at the cap with a mark saying so.
      def clipped(text)
        text.length > @max_cell_chars ? text[0, @max_cell_chars] + CUT_MARK : text
      end

      def clip(text, limit)
        text.length > limit ? text[0, limit] + CUT_MARK : text
      end

      # Takes a cell's text out of the workbook's budget; false when it does
      # not fit, and the caller cuts the sheet there.
      def spend_text(text)
        return false if text.bytesize > @text_left

        @text_left -= text.bytesize
        true
      end

      # Ends a sheet before `row`: that row and everything after it go, and
      # the notice names the rows that are left.
      def cut(draft, row)
        draft.rows.delete_if { |number, _| number >= row }
        draft.truncated_rows = true
        draft.row_limit = row - 1
        @budget_spent = true
      end

      # --- shared strings -----------------------------------------------------------

      # Stores only the strings a kept cell points at, each cut at the cell
      # cap, and no more of them in total than the text budget could ever
      # render: past that a wanted string is recorded as OVER_BUDGET, which
      # `finish` treats as the end of the sheet, never as a blank cell.
      def read_shared_strings(path)
        strings = {}
        return strings if @shared_wanted.empty?

        index = -1
        wanted = false
        capture = false
        phonetic = 0
        text = +""
        held = 0
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
            when "si"
              if wanted
                string = clipped(text)
                if held + string.bytesize > @max_text_bytes
                  strings[index] = OVER_BUDGET
                else
                  held += string.bytesize
                  strings[index] = string
                end
              end
            end
          else
            append(text, node.value) if capture && TEXT_NODE_TYPES.include?(node.node_type)
          end
        end
        strings
      end

      # --- drafts to sheets ---------------------------------------------------------

      # Resolves shared strings, spends what is left of the text budget on
      # them cell by cell, then lays each sheet out as a rectangle inside the
      # grid budget. Once a budget cuts a sheet, the sheets after it are left
      # out (and counted by the caller).
      def finish(drafts, strings)
        sheets = []
        spent = false
        drafts.each do |draft|
          break if spent

          spent = true if resolve(draft, strings) == :cut
          spent = true if fit_grid(draft) == :cut
          # A sheet cut down to nothing is one of the sheets not shown.
          next if spent && draft.rows.empty? && sheets.any?

          sheets << Sheet.new(name: draft.name, rows: dense(draft.rows), truncated_rows: draft.truncated_rows,
                              truncated_columns: draft.truncated_columns, hidden: draft.hidden,
                              row_limit: draft.row_limit)
        end
        sheets
      end

      def resolve(draft, strings)
        draft.rows.keys.sort.each do |number|
          row = draft.rows[number]
          row.keys.sort.each do |column|
            value = row[column]
            next unless value.is_a?(SharedRef)

            string = strings[value.index]
            if string.nil? || string == ""
              row.delete(column)
            elsif string.equal?(OVER_BUDGET) || !spend_text(string)
              cut(draft, number)
              return :cut
            else
              row[column] = Cell.new(string, false)
            end
          end
        end
        draft.rows.delete_if { |_, row| row.empty? }
        :whole
      end

      # A sheet renders as rows x columns whether or not the cells are filled.
      def fit_grid(draft)
        return :whole if draft.rows.empty?

        width = draft.rows.values.flat_map(&:keys).max
        height = draft.rows.keys.max
        if width * height <= @grid_left
          @grid_left -= width * height
          return :whole
        end

        rows = @grid_left / width
        cut(draft, rows + 1)
        @grid_left = 0
        :cut
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
