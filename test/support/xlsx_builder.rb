# frozen_string_literal: true

require "zlib"

# Builds a small .xlsx in memory for the knowledge-preview tests: a zip writer
# on Zlib and just enough SpreadsheetML for a reader to walk. Every figure and
# name a test passes in is invented.
#
# It is a SECOND, independent implementation of the container the reader
# parses, and it must stay that way: it never calls into
# Studio::KnowledgePreview. test/fixtures/files/knowledge_preview_sample.xlsx
# is the third, written by a real spreadsheet library, so the reader is not
# only ever tested against a writer that shares its author's assumptions.
module XlsxBuilder
  module_function

  # entries: { "path/in/zip" => "bytes" }. store: true writes entries
  # uncompressed (method 0); descriptor: true sets bit 3 and writes the sizes
  # AFTER the data, zeroed in the local header, as streaming writers do.
  def zip(entries, store: false, descriptor: false)
    out = +"".b
    central = +"".b
    entries.each do |name, content|
      content = content.b
      data = store ? content : Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS).deflate(content, Zlib::FINISH)
      crc = Zlib.crc32(content)
      flags = descriptor ? 8 : 0
      method = store ? 0 : 8
      offset = out.bytesize
      local_sizes = descriptor ? [0, 0, 0] : [crc, data.bytesize, content.bytesize]
      out << ["PK\x03\x04".b, 20, flags, method, 0, 0, *local_sizes, name.bytesize, 0].pack("a4vvvvvVVVvv") << name.b << data
      out << ["PK\x07\x08".b, crc, data.bytesize, content.bytesize].pack("a4VVV") if descriptor
      central << ["PK\x01\x02".b, 20, 20, flags, method, 0, 0, crc, data.bytesize, content.bytesize,
                  name.bytesize, 0, 0, 0, 0, 0, offset].pack("a4vvvvvvVVVvvvvvVV") << name.b
    end
    directory_offset = out.bytesize
    out << central
    out << ["PK\x05\x06".b, 0, 0, entries.size, entries.size, central.bytesize, directory_offset, 0].pack("a4vvvvVVv")
    out
  end

  def escape(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end

  # sheets: { "Name" => "<row>...</row> xml for sheetData" }.
  # formats: number format codes; a cell's s="N" picks formats[N - 1]
  # (style 0 is General). shared: the shared string table.
  def workbook(sheets, formats: [], shared: [], date1904: false, hidden: [], extra: {}, **zip_options)
    names = sheets.keys
    entries = {
      "[Content_Types].xml" => %(<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>),
      "xl/workbook.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <workbookPr#{' date1904="1"' if date1904}/>
          <sheets>
            #{names.each_with_index.map { |name, i| %(<sheet name="#{escape(name)}" sheetId="#{i + 1}" r:id="rId#{i + 1}"#{' state="hidden"' if hidden.include?(name)}/>) }.join}
          </sheets>
        </workbook>
      XML
      "xl/_rels/workbook.xml.rels" => <<~XML,
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          #{names.each_index.map { |i| %(<Relationship Id="rId#{i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{i + 1}.xml"/>) }.join}
          <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
          <Relationship Id="rIdStrings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
        </Relationships>
      XML
      "xl/styles.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <numFmts count="#{formats.size}">
            #{formats.each_with_index.map { |code, i| %(<numFmt numFmtId="#{164 + i}" formatCode="#{escape(code)}"/>) }.join}
          </numFmts>
          <cellStyleXfs count="1"><xf numFmtId="14"/></cellStyleXfs>
          <cellXfs count="#{formats.size + 1}">
            <xf numFmtId="0"/>
            #{formats.each_index.map { |i| %(<xf numFmtId="#{164 + i}" applyNumberFormat="1"/>) }.join}
          </cellXfs>
        </styleSheet>
      XML
      "xl/sharedStrings.xml" => <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="#{shared.size}" uniqueCount="#{shared.size}">
          #{shared.map { |entry| entry.start_with?("<") ? "<si>#{entry}</si>" : "<si><t>#{escape(entry)}</t></si>" }.join}
        </sst>
      XML
    }
    sheets.each_with_index do |(_name, rows), i|
      entries["xl/worksheets/sheet#{i + 1}.xml"] = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>#{rows}</sheetData>
        </worksheet>
      XML
    end
    zip(entries.merge(extra), **zip_options)
  end

  # rows: arrays of plain values; strings become inline strings, numbers
  # numeric cells, nil a gap. For anything finer, hand `workbook` raw XML.
  def rows(values)
    values.each_with_index.map { |row, r|
      cells = row.each_with_index.filter_map { |value, c|
        ref = "#{column(c)}#{r + 1}"
        case value
        when nil then nil
        when Numeric then %(<c r="#{ref}"><v>#{value}</v></c>)
        else %(<c r="#{ref}" t="inlineStr"><is><t>#{escape(value)}</t></is></c>)
        end
      }
      %(<row r="#{r + 1}">#{cells.join}</row>)
    }.join
  end

  def column(index)
    letters = +""
    number = index + 1
    while number.positive?
      number, remainder = (number - 1).divmod(26)
      letters.prepend((65 + remainder).chr)
    end
    letters
  end
end
