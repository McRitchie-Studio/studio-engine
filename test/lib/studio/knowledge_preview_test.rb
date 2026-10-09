# frozen_string_literal: true

require_relative "../../test_helper"
require "tempfile"
require_relative "../../support/xlsx_builder"
require_relative "../../../lib/studio/knowledge_preview"
# The readers load lazily in an app (test_requiring_the_module_loads_no_reader
# proves that in a process of its own). Here they are named directly, in an
# order minitest shuffles, so they are loaded up front.
require_relative "../../../lib/studio/knowledge_preview/xlsx"

# [unit] Studio::KnowledgePreview: which files preview and as what, the
# workbook reader (shared strings, formulas' cached values, number formats,
# the row, column and sheet caps, damaged and hostile files), the CSV reader,
# and the Result a document gets, including every fallback.
#
# All data is invented. Workbooks are built by XlsxBuilder, a writer that
# shares no code with the reader, and one fixture was written by openpyxl.
class KnowledgePreviewTest < Minitest::Test
  Preview = Studio::KnowledgePreview
  FIXTURE = File.expand_path("../../fixtures/files/knowledge_preview_sample.xlsx", __dir__)

  def read(bytes, **caps)
    Preview::Xlsx.read(bytes, **{ max_rows: 500, max_columns: 50, max_sheets: 20, max_cells: 50_000, max_cell_chars: 32_767,
                                max_text_bytes: 2 * 1_048_576, max_grid_cells: 100_000, max_parsed_text_bytes: 16 * 1_048_576,
                                inflate_budget: 8 * 1_048_576, deadline_seconds: 600 }.merge(caps))
  end

  def texts(sheet)
    sheet.rows.map { |row| row.map { |cell| cell&.text } }
  end

  # --- kind resolution -----------------------------------------------------------

  def test_the_extension_decides_the_kind
    {
      "20310131-ab12cd34-ledger.xlsx" => :spreadsheet, "macro.XLSM" => :spreadsheet,
      "export.csv" => :delimited, "export.tsv" => :delimited,
      "letter.pdf" => :pdf, "scan.PNG" => :image, "photo.jpeg" => :image, "anim.gif" => :image, "shot.webp" => :image,
      "call.txt" => :text, "notes.md" => :text, "captions.vtt" => :text, "payload.json" => :text
    }.each do |name, kind|
      assert_equal kind, Preview.kind_for(filename: name), name
    end
  end

  def test_out_of_scope_and_unsafe_types_have_no_preview
    assert_nil Preview.kind_for(filename: "legacy.xls", mime_type: "application/vnd.ms-excel")
    assert_nil Preview.kind_for(filename: "memo.docx",
                                mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    assert_nil Preview.kind_for(filename: "logo.svg", mime_type: "image/svg+xml"),
               "an SVG can carry script; it is never embedded"
    assert_nil Preview.kind_for(filename: "archive.zip", mime_type: "application/zip")
    assert_nil Preview.kind_for(filename: "document", mime_type: nil)
  end

  def test_the_mime_type_answers_only_for_a_name_that_says_nothing
    assert_equal :spreadsheet, Preview.kind_for(filename: "document", mime_type: Preview::XLSX_MIME)
    assert_equal :delimited, Preview.kind_for(filename: "document", mime_type: "text/csv; charset=utf-8")
    assert_equal :text, Preview.kind_for(filename: "document", mime_type: "text/x-anything")
    assert_equal :spreadsheet, Preview.kind_for(filename: "ledger.xlsx", mime_type: "application/octet-stream"),
                 "a browser that guessed octet-stream does not cost the preview"
    assert_equal :pdf, Preview.kind_for(filename: "letter.pdf", mime_type: "text/html"),
                 "the name wins over a stored mime type"
  end

  def test_inline_content_type_is_chosen_from_the_kind_never_copied
    assert_equal "application/pdf", Preview.inline_content_type(filename: "letter.pdf", mime_type: "text/html")
    assert_equal "image/jpeg", Preview.inline_content_type(filename: "photo.jpg", mime_type: "image/svg+xml")
    assert_equal "image/png", Preview.inline_content_type(filename: "document", mime_type: "image/png")
    assert_nil Preview.inline_content_type(filename: "document", mime_type: "text/html")
  end

  def test_column_letters
    assert_equal %w[A B Z AA AB AZ BA], [0, 1, 25, 26, 27, 51, 52].map { |i| Preview.column_letter(i) }
  end

  # --- the workbook reader -----------------------------------------------------------

  def test_reads_a_workbook_written_by_another_library
    workbook = Preview.read_spreadsheet(File.binread(FIXTURE))

    assert_equal %w[Summary Notes], workbook.sheets.map(&:name)
    summary = texts(workbook.sheets.first)
    assert_equal ["Widget line", "Units", "Unit price", "Revenue", "Share", "As of"], summary[0]
    # Column D is a formula openpyxl saved with no cached value: blank, not "=B2*C2".
    assert_equal ["Alpha widgets", "120", "$4.50", nil, "25.0%", "Jan 31, 2031"], summary[1]
    assert_equal "$2,000.00", summary[3][2], "1999.999 at two decimals rounds up"
    assert_equal [nil, "(1,234.50)"], texts(workbook.sheets.last)[2]
    assert_equal 0, workbook.omitted_sheets
  end

  def test_shared_strings_resolve_including_rich_text_and_skip_phonetic_runs
    shared = ["Region", "<r><t>North</t></r><r><t xml:space=\"preserve\"> East</t></r>",
              "<t>Kana</t><rPh sb=\"0\" eb=\"1\"><t>READING</t></rPh>", "never referenced"]
    rows = %(<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>)
    sheet = read(XlsxBuilder.workbook({ "Data" => rows }, shared: shared)).sheets.first

    assert_equal [["Region", "North East", "Kana"]], texts(sheet)
    refute sheet.rows.flatten.any?(&:numeric), "strings are not numbers"
  end

  def test_a_formula_shows_its_cached_value_never_its_text
    rows = <<~XML
      <row r="1">
        <c r="A1" s="1"><f>SUM(B1:B9)</f><v>1234.5</v></c>
        <c r="B1" t="str"><f>CONCATENATE("a","b")</f><v>ab</v></c>
        <c r="C1"><f>NOW()</f></c>
        <c r="D1" t="b"><f>1=1</f><v>1</v></c>
        <c r="E1" t="e"><f>1/0</f><v>#DIV/0!</v></c>
      </row>
    XML
    sheet = read(XlsxBuilder.workbook({ "Calc" => rows }, formats: ["#,##0.00"])).sheets.first

    assert_equal [["1,234.50", "ab", nil, "TRUE", "#DIV/0!"]], texts(sheet)
    refute_includes texts(sheet).flatten.compact.join, "SUM"
  end

  def test_numbers_render_through_their_number_format
    formats = ["#,##0.00;(#,##0.00)", "0.0%", '"$"#,##0', "m/d/yyyy", "yyyy-mm-dd h:mm"]
    rows = <<~XML
      <row r="1">
        <c r="A1" s="1"><v>-98765.432</v></c>
        <c r="B1" s="2"><v>0.0825</v></c>
        <c r="C1" s="3"><v>1500000</v></c>
        <c r="D1" s="4"><v>47880</v></c>
        <c r="E1" s="5"><v>47880.75</v></c>
        <c r="F1"><v>42</v></c>
        <c r="G1"><v>0.30000000000000004</v></c>
      </row>
    XML
    sheet = read(XlsxBuilder.workbook({ "Formats" => rows }, formats: formats)).sheets.first

    assert_equal [["(98,765.43)", "8.3%", "$1,500,000", "2/1/2031", "2031-02-01 18:00", "42", "0.3"]], texts(sheet)
    assert sheet.rows.first.all?(&:numeric), "numeric cells are marked so the page can right-align them"
  end

  def test_the_1904_date_system_is_honoured
    rows = %(<row r="1"><c r="A1" s="1"><v>0</v></c></row>)
    assert_equal "1904-01-01",
                 texts(read(XlsxBuilder.workbook({ "D" => rows }, formats: ["yyyy-mm-dd"], date1904: true)).sheets.first)[0][0]
    assert_equal "1900-01-01",
                 texts(read(XlsxBuilder.workbook({ "D" => %(<row r="1"><c r="A1" s="1"><v>1</v></c></row>) },
                                                 formats: ["yyyy-mm-dd"])).sheets.first)[0][0]
  end

  def test_gaps_keep_the_grid_aligned_with_the_workbooks_own_rows_and_columns
    rows = %(<row r="2"><c r="C2"><v>7</v></c></row><row r="4"><c r="A4" t="inlineStr"><is><t>end</t></is></c></row>)
    sheet = read(XlsxBuilder.workbook({ "Sparse" => rows })).sheets.first

    assert_equal [[nil, nil, nil], [nil, nil, "7"], [nil, nil, nil], ["end", nil, nil]], texts(sheet)
  end

  def test_the_row_cap_stops_the_read_and_says_so
    values = (1..40).map { |n| ["row #{n}", n] }
    sheet = read(XlsxBuilder.workbook({ "Long" => XlsxBuilder.rows(values) }), max_rows: 10).sheets.first

    assert_equal 10, sheet.rows.size
    assert_equal ["row 10", "10"], texts(sheet).last
    assert sheet.truncated_rows
    assert_equal 10, sheet.row_limit
    refute sheet.truncated_columns
  end

  def test_a_sheet_within_the_caps_is_not_marked_truncated
    sheet = read(XlsxBuilder.workbook({ "Short" => XlsxBuilder.rows([["a", 1], ["b", 2]]) }), max_rows: 2, max_columns: 2).sheets.first

    assert_equal 2, sheet.rows.size
    refute sheet.truncated_rows
    refute sheet.truncated_columns
  end

  def test_the_column_cap_drops_columns_and_says_so
    sheet = read(XlsxBuilder.workbook({ "Wide" => XlsxBuilder.rows([(1..12).to_a]) }), max_columns: 5).sheets.first

    assert_equal [%w[1 2 3 4 5]], texts(sheet)
    assert sheet.truncated_columns
    refute sheet.truncated_rows
  end

  def test_the_sheet_cap_counts_what_it_left_out_and_hidden_sheets_are_marked
    sheets = (1..5).to_h { |n| ["Tab #{n}", XlsxBuilder.rows([[n]])] }
    workbook = read(XlsxBuilder.workbook(sheets, hidden: ["Tab 2"]), max_sheets: 3)

    assert_equal ["Tab 1", "Tab 2", "Tab 3"], workbook.sheets.map(&:name)
    assert_equal 2, workbook.omitted_sheets
    assert_equal [false, true, false], workbook.sheets.map(&:hidden)
  end

  def test_the_cell_budget_cuts_the_sheet_that_spends_it_and_counts_the_rest
    grid = XlsxBuilder.rows((1..10).map { |r| (1..4).map { |c| (r * 10) + c } })
    workbook = read(XlsxBuilder.workbook({ "One" => grid, "Two" => grid, "Three" => grid, "Four" => grid }), max_cells: 60)

    assert_equal %w[One Two], workbook.sheets.map(&:name)
    assert_equal 2, workbook.omitted_sheets
    one, two = workbook.sheets
    assert_equal 10, one.rows.size
    refute one.truncated_rows
    # 40 cells went to the first sheet; the last 20 are five whole rows.
    assert_equal 5, two.rows.size
    assert two.truncated_rows
    assert_equal 5, two.row_limit, "the notice names the rows actually shown"
  end

  def test_a_workbook_inside_the_cell_budget_is_whole
    grid = XlsxBuilder.rows((1..10).map { |r| (1..4).map { |c| (r * 10) + c } })
    workbook = read(XlsxBuilder.workbook({ "One" => grid, "Two" => grid }), max_cells: 80)

    assert_equal [10, 10], workbook.sheets.map { |sheet| sheet.rows.size }
    assert_equal [false, false], workbook.sheets.map(&:truncated_rows)
    assert_equal 0, workbook.omitted_sheets
  end

  def test_stored_entries_and_data_descriptors_read_like_deflated_ones
    rows = XlsxBuilder.rows([["plain", 5]])
    [{ store: true }, { descriptor: true }, {}].each do |options|
      assert_equal [["plain", "5"]], texts(read(XlsxBuilder.workbook({ "S" => rows }, **options)).sheets.first), options.inspect
    end
  end

  def test_a_sheet_name_and_a_cell_keep_their_markup_as_text
    rows = XlsxBuilder.rows([["<script>alert(1)</script>"]])
    sheet = read(XlsxBuilder.workbook({ "<b>Tab</b>" => rows })).sheets.first

    assert_equal "<b>Tab</b>", sheet.name
    assert_equal "<script>alert(1)</script>", texts(sheet)[0][0]
  end

  # --- damaged and hostile files -------------------------------------------------------

  def test_bytes_that_are_not_a_zip_are_unreadable
    error = assert_raises(Preview::Unreadable) { Preview.read_spreadsheet("this is not a workbook at all") }
    assert_match(/not a zip archive/, error.message)
    assert_raises(Preview::Unreadable) { Preview.read_spreadsheet("") }
  end

  def test_a_zip_that_is_not_a_workbook_is_unreadable
    error = assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(XlsxBuilder.zip({ "readme.txt" => "hello" })) }
    assert_match(/not an Excel workbook/, error.message)
  end

  def test_a_truncated_workbook_is_unreadable
    bytes = XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([["a", 1]]) })
    [bytes.byteslice(0, bytes.bytesize / 2), bytes.byteslice(0, bytes.bytesize - 30)].each do |cut|
      assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(cut) }
    end
  end

  def test_malformed_sheet_xml_is_unreadable
    bytes = XlsxBuilder.workbook({ "S" => %(<row r="1"><c r="A1"><v>1</v></row>) })
    error = assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(bytes) }
    assert_match(/damaged/, error.message)
  end

  def test_corrupt_deflate_data_is_unreadable
    bytes = XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([["a" * 400, 1]]) })
    # Overwrite the middle of the first entry's compressed stream.
    start = bytes.index("xl/workbook.xml") + "xl/workbook.xml".bytesize + 10
    bytes[start, 24] = "\xFF".b * 24
    assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(bytes) }
  end

  def test_an_encrypted_or_zip64_archive_is_refused
    bytes = XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([[1]]) })
    encrypted = bytes.dup
    position = 0
    while (position = encrypted.index("PK\x01\x02".b, position))
      encrypted[position + 8, 2] = [1].pack("v")
      position += 4
    end
    assert_match(/password-protected/, assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(encrypted) }.message)

    zip64 = bytes.dup
    zip64[zip64.rindex("PK\x05\x06".b) + 16, 4] = [0xFFFFFFFF].pack("V")
    assert_match(/zip64/, assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(zip64) }.message)
  end

  def test_a_part_that_inflates_past_the_cap_is_refused_not_read
    # 6 MB of repeated shared strings in a file of a few kilobytes.
    shared = ["wanted"] + Array.new(60) { "x" * 100_000 }
    rows = %(<row r="1"><c r="A1" t="s"><v>60</v></c></row>)
    bytes = XlsxBuilder.workbook({ "S" => rows }, shared: shared)
    assert_operator bytes.bytesize, :<, 100_000

    error = assert_raises(Preview::TooLarge) { read(bytes, inflate_budget: 1_048_576) }
    assert_match(/expands past/, error.message)
    # Under a cap that admits the table, the wanted string reads (cut at the cell cap).
    assert_equal ("x" * 32_767) + "…", texts(read(bytes, inflate_budget: 16 * 1_048_576).sheets.first)[0][0]
  end

  def test_rows_past_the_cap_are_never_inflated
    # The sheet's first rows fit the inflate cap; the whole sheet does not.
    # Stopping at the row cap is what keeps the read inside it.
    values = (1..3000).map { |n| ["filler #{n} " + ("y" * 400), n] }
    bytes = XlsxBuilder.workbook({ "Big" => XlsxBuilder.rows(values) })

    assert_raises(Preview::TooLarge) { read(bytes, max_rows: 3000, inflate_budget: 200_000) }
    sheet = read(bytes, max_rows: 5, inflate_budget: 200_000).sheets.first
    assert_equal 5, sheet.rows.size
    assert sheet.truncated_rows
  end

  # --- sizes, not only counts ----------------------------------------------------------
  #
  # Each of these is a file of a few kilobytes that a count cap alone lets
  # through: the cost is in how BIG a kept thing is, or how long it takes to
  # compute, not in how many there are.

  def text_bytes(workbook)
    workbook.sheets.sum { |sheet| sheet.rows.flatten.compact.sum { |cell| cell.text.bytesize } }
  end

  def test_one_huge_shared_string_referenced_by_every_cell_is_cut_per_cell_and_in_total
    cells = (1..500).map { |r| %(<row r="#{r}">) + (0..49).map { |c| %(<c r="#{XlsxBuilder.column(c)}#{r}" t="s"><v>0</v></c>) }.join + "</row>" }.join
    bytes = XlsxBuilder.workbook({ "S" => cells, "After" => XlsxBuilder.rows([["never reached"]]) }, shared: ["q" * 1_000_000])
    assert_operator bytes.bytesize, :<, 200_000

    workbook = Preview.read_spreadsheet(bytes)
    sheet = workbook.sheets.first
    longest = sheet.rows.flatten.compact.map { |cell| cell.text.length }.max
    assert_equal Preview::MAX_CELL_CHARS + 1, longest, "a cell keeps Excel's own limit, plus the mark that says it was cut"
    assert sheet.rows.first.first.text.end_with?("…")
    assert_operator text_bytes(workbook), :<=, Preview::MAX_TEXT_BYTES
    assert sheet.truncated_rows, "the sheet that spends the text budget says it was cut"
    assert_equal sheet.rows.size, sheet.row_limit
    assert_operator sheet.rows.size, :<, 500
    assert_equal 1, workbook.sheets.size
    assert_equal 1, workbook.omitted_sheets, "sheets after the budget ran out are counted, not rendered"
  end

  def test_huge_inline_strings_are_cut_as_they_are_read
    big = "w" * 1_000_000
    workbook = Preview.read_spreadsheet(XlsxBuilder.workbook({ "One" => XlsxBuilder.rows((1..5).map { [big] }), "Two" => XlsxBuilder.rows([["x"]]) }))

    assert_equal Preview::MAX_CELL_CHARS + 1, workbook.sheets.first.rows.first.first.text.length
    assert_equal 5, workbook.sheets.first.rows.size
    assert_operator text_bytes(workbook), :<=, Preview::MAX_TEXT_BYTES
  end

  def test_megabyte_cells_on_many_sheets_end_the_read_before_they_fill_memory
    # Each cell would be cut to the cell cap, but the parser still hands every
    # megabyte over to be cut. The parsed-text budget ends the read first.
    big = "w" * 1_000_000
    sheets = (1..20).to_h { |n| ["T#{n}", XlsxBuilder.rows((1..50).map { [big] })] }
    error = assert_raises(Preview::TooLarge) { Preview.read_spreadsheet(XlsxBuilder.workbook(sheets)) }
    assert_match(/more text than a preview reads/, error.message)
  end

  def test_a_workbook_inside_the_text_budget_keeps_every_cell_whole
    workbook = read(XlsxBuilder.workbook({ "A" => XlsxBuilder.rows([["x" * 100, "y" * 100]]), "B" => XlsxBuilder.rows([["z" * 100]]) }),
                    max_text_bytes: 300)

    assert_equal [["x" * 100, "y" * 100]], texts(workbook.sheets.first)
    assert_equal [["z" * 100]], texts(workbook.sheets.last)
    refute workbook.sheets.any?(&:truncated_rows)
    assert_equal 0, workbook.omitted_sheets
  end

  def test_the_text_budget_cuts_at_the_row_that_would_overspend_it
    rows = XlsxBuilder.rows((1..6).map { |n| ["#{n}" * 100] })
    workbook = read(XlsxBuilder.workbook({ "A" => rows, "B" => rows }), max_text_bytes: 350)

    sheet = workbook.sheets.first
    assert_equal 3, sheet.rows.size
    assert sheet.truncated_rows
    assert_equal 3, sheet.row_limit
    assert_equal 1, workbook.omitted_sheets
  end

  def test_a_shared_string_table_too_big_to_hold_cuts_the_sheet_instead_of_blanking_cells
    shared = (1..40).map { |n| n.to_s.rjust(2, "0") * 50 }
    rows = (1..40).map { |r| %(<row r="#{r}"><c r="A#{r}" t="s"><v>#{r - 1}</v></c></row>) }.join
    sheet = read(XlsxBuilder.workbook({ "S" => rows }, shared: shared), max_text_bytes: 1000).sheets.first

    assert_equal 10, sheet.rows.size
    assert sheet.truncated_rows
    assert sheet.rows.flatten.none?(&:nil?), "a string that was not kept ends the sheet; it never reads as an empty cell"
  end

  def reader_for(bytes, **caps)
    Preview::Xlsx.new(bytes, **{ max_rows: 500, max_columns: 50, max_sheets: 20, max_cells: 50_000, max_cell_chars: 32_767,
                                 max_text_bytes: 2 * 1_048_576, max_grid_cells: 100_000, max_parsed_text_bytes: 16 * 1_048_576,
                                inflate_budget: 8 * 1_048_576, deadline_seconds: 600 }.merge(caps))
  end

  def test_a_cells_text_stops_growing_one_character_past_the_cap
    # The clip a kept cell gets hides this from the outside, so it is asserted
    # where it happens: a value arriving as many runs must not be gathered
    # whole before it is cut.
    reader = reader_for(XlsxBuilder.workbook({ "S" => "" }), max_cell_chars: 10)
    text = +""
    5.times { reader.send(:append, text, "abcdefg") }
    assert_equal 11, text.length
    assert_equal "abcdefgabc…", reader.send(:clipped, text)

    runs = (1..400).map { "<r><t>#{'r' * 100}</t></r>" }.join
    rows = %(<row r="1"><c r="A1" t="s"><v>0</v></c></row>)
    cell = read(XlsxBuilder.workbook({ "S" => rows }, shared: [runs]), max_cell_chars: 250).sheets.first.rows[0][0]
    assert_equal ("r" * 250) + "…", cell.text
  end

  def test_the_shared_string_table_holds_no_more_than_the_text_budget
    # Sixty distinct strings of a thousand bytes, all wanted, under a budget
    # of ten thousand: what is held is bounded by the budget, not by how many
    # distinct strings the cells point at.
    shared = (1..60).map { |n| n.to_s.rjust(2, "0") * 500 }
    rows = (1..60).map { |r| %(<row r="#{r}"><c r="A#{r}" t="s"><v>#{r - 1}</v></c></row>) }.join
    reader = reader_for(XlsxBuilder.workbook({ "S" => rows }, shared: shared), max_text_bytes: 10_000)
    reader.instance_variable_set(:@shared_wanted, Set.new(0...60))

    strings = reader.send(:read_shared_strings, "xl/sharedStrings.xml")
    held = strings.values.grep(String)
    assert_equal 10, held.size
    assert_operator held.sum(&:bytesize), :<=, 10_000
    assert_equal 50, strings.values.count { |value| value.equal?(Preview::Xlsx::OVER_BUDGET) }
  end

  def test_once_the_shared_table_is_full_nothing_more_is_read_into_it
    # 600 bytes fit a budget of 1,000; the next 600 do not; and the 100 after
    # that, which WOULD fit, are not read either: full is full, so a table of
    # small strings behind a big one cannot keep the parser handing text over.
    rows = (1..3).map { |r| %(<row r="#{r}"><c r="A#{r}" t="s"><v>#{r - 1}</v></c></row>) }.join
    reader = reader_for(XlsxBuilder.workbook({ "S" => rows }, shared: ["a" * 600, "b" * 600, "c" * 100]), max_text_bytes: 1000)
    reader.instance_variable_set(:@shared_wanted, Set.new(0..2))

    strings = reader.send(:read_shared_strings, "xl/sharedStrings.xml")
    assert_equal "a" * 600, strings[0]
    assert strings[1].equal?(Preview::Xlsx::OVER_BUDGET)
    assert strings[2].equal?(Preview::Xlsx::OVER_BUDGET)
  end

  def test_thousands_of_styles_on_one_format_tokenize_it_once
    code = '#,##0.00;[Red](#,##0.00)'
    styles = <<~XML
      <?xml version="1.0"?>
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="1"><numFmt numFmtId="164" formatCode="#{XlsxBuilder.escape(code)}"/></numFmts>
        <cellXfs count="5000">#{'<xf numFmtId="164"/>' * 5000}</cellXfs>
      </styleSheet>
    XML
    # Two hundred cells, each on a different style, every style the same format.
    cells = (0...200).map { |n| %(<c r="A#{n + 1}" s="#{n * 25}"><v>-1234.5</v></c>) }
    rows = cells.each_with_index.map { |cell, n| %(<row r="#{n + 1}">#{cell}</row>) }.join
    bytes = XlsxBuilder.workbook({ "S" => rows }, extra: { "xl/styles.xml" => styles })

    calls = 0
    format = Preview::NumberFormat
    original = format.method(:tokenize)
    format.define_singleton_method(:tokenize) { |value| calls += 1; original.call(value) }
    begin
      assert_equal [["(1,234.50)"]] * 200, texts(read(bytes).sheets.first)
    ensure
      format.define_singleton_method(:tokenize, original)
    end
    assert_equal 1, calls, "one tokenize per distinct format: not one per style, not one per cell"
  end

  def test_a_format_code_longer_than_excel_allows_renders_as_a_plain_number
    format = Preview::NumberFormat
    assert_equal "1234.5", format.format(1234.5, "0" * 100_000)
    assert_equal "1234.5", format.format(1234.5, "0" * (format::MAX_CODE_LENGTH + 1))
    assert_equal 255, format.format(1.0, "0" * format::MAX_CODE_LENGTH).length, "a code at the limit still applies"

    rows = %(<row r="1"><c r="A1" s="1"><v>1234.5</v></c></row>)
    assert_equal [["1234.5"]], texts(read(XlsxBuilder.workbook({ "S" => rows }, formats: ["#" * 2000 + "0"])).sheets.first)
  end

  def test_a_numbers_rendered_width_is_bounded
    format = Preview::NumberFormat
    assert_equal "0." + ("3" * 15) + ("0" * 15), format.format(1.0 / 3, "0." + ("0" * 200)), "decimals stop at thirty"
    assert_equal "0", format.format(1e-40, "0." + ("#" * 200)), "optional decimals stop at thirty too"
    assert_operator format.format(1e300, "#,##0.00").length, :<, 40, "a number too wide to be a figure renders compactly"
    assert_equal "1e+300", format.format(1e300, "#,##0.00")
  end

  def test_a_cell_reference_with_more_than_three_letters_is_past_the_last_column
    reader = Preview::Xlsx.allocate
    reader.instance_variable_set(:@max_columns, 50)
    assert_equal 16_384, reader.send(:column_index, "XFD1")
    assert_equal 51, reader.send(:column_index, "XFDA1")
    assert_equal 51, reader.send(:column_index, ("A" * 50_000) + "1")

    rows = %(<row r="1"><c r="A1"><v>1</v></c><c r="#{'B' * 50_000}1"><v>2</v></c></row>)
    sheet = read(XlsxBuilder.workbook({ "S" => rows })).sheets.first
    assert_equal [["1"]], texts(sheet)
    assert sheet.truncated_columns
  end

  def test_the_rendered_grid_is_budgeted_empty_cells_included
    far = %(<row r="500"><c r="AX500"><v>1</v></c></row>)
    workbook = Preview.read_spreadsheet(XlsxBuilder.workbook((1..20).to_h { |n| ["T#{n}", far] }))

    rendered = workbook.sheets.sum { |sheet| sheet.rows.sum(&:size) }
    assert_operator rendered, :<=, Preview::MAX_GRID_CELLS
    assert_equal 4, workbook.sheets.size, "four full rectangles fit the grid budget"
    assert_equal 16, workbook.omitted_sheets
  end

  def test_the_grid_budget_cuts_the_sheet_that_overspends_it
    grid = XlsxBuilder.rows((1..10).map { |r| (1..4).map { |c| (r * 10) + c } })
    workbook = read(XlsxBuilder.workbook({ "One" => grid, "Two" => grid, "Three" => grid }), max_grid_cells: 60)

    one, two = workbook.sheets
    assert_equal 2, workbook.sheets.size
    assert_equal 10, one.rows.size
    refute one.truncated_rows
    assert_equal 5, two.rows.size
    assert two.truncated_rows
    assert_equal 5, two.row_limit
    assert_equal 1, workbook.omitted_sheets
  end

  # --- the read as a whole ---------------------------------------------------------------
  #
  # The caps above each name one thing a file can make big. These bound the
  # read itself, so that a thing nobody named is bounded too.

  WORKSHEET_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"

  def rels(entries)
    body = entries.map { |id, target| %(<Relationship Id="#{id}" Type="#{WORKSHEET_REL}" Target="#{target}"/>) }.join
    %(<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">#{body}</Relationships>)
  end

  def sheet_part(rows)
    %(<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>#{rows}</sheetData></worksheet>)
  end

  def test_the_inflate_budget_is_one_for_the_whole_workbook_not_one_per_part
    # Six sheets that are all the same 150 KB part. Each read of it fits a
    # 400 KB budget; six do not, and it is the sum that is refused.
    part = sheet_part((1..300).map { |r| %(<row r="#{r}"><c r="A#{r}"><f>#{'A1+' * 160}1</f><v>#{r}</v></c></row>) }.join)
    assert_in_delta 150_000, part.bytesize, 20_000
    names = (1..6).map { |n| "T#{n}" }
    aliased = XlsxBuilder.workbook(names.to_h { |name| [name, ""] },
                                   extra: { "xl/worksheets/sheet1.xml" => part,
                                            "xl/_rels/workbook.xml.rels" => rels((1..6).map { |n| ["rId#{n}", "worksheets/sheet1.xml"] }) })

    error = assert_raises(Preview::TooLarge) { read(aliased, inflate_budget: 400_000) }
    assert_match(/expands past/, error.message)
    assert_equal 6, read(aliased, inflate_budget: 2_000_000).sheets.size

    once = XlsxBuilder.workbook({ "T1" => "" }, extra: { "xl/worksheets/sheet1.xml" => part })
    assert_equal 300, read(once, inflate_budget: 400_000).sheets.first.rows.size
  end

  def test_a_stored_part_spends_the_same_budget
    part = sheet_part(XlsxBuilder.rows([["s" * 5000]]))
    bytes = XlsxBuilder.workbook({ "A" => "", "B" => "", "C" => "" }, store: true,
                                 extra: { "xl/worksheets/sheet1.xml" => part,
                                          "xl/_rels/workbook.xml.rels" => rels((1..3).map { |n| ["rId#{n}", "worksheets/sheet1.xml"] }) })
    assert_raises(Preview::TooLarge) { read(bytes, inflate_budget: 12_000) }
    assert_equal 3, read(bytes, inflate_budget: 40_000).sheets.size
  end

  def test_the_deadline_ends_a_read_that_takes_too_long_on_an_injected_clock
    bytes = XlsxBuilder.workbook({ "S" => XlsxBuilder.rows((1..200).map { |n| ["row #{n}", n] }) })
    ticks = 0
    clock = -> { ticks += 1 } # one "second" per look at the clock

    error = assert_raises(Preview::TooLarge) { read(bytes, deadline_seconds: 50, clock: clock) }
    assert_equal "it takes more than 50 seconds to read", error.message
    assert_operator ticks, :<, 60, "the read stopped at the deadline; it did not run on and report late"

    ticks = 0
    assert_equal 200, read(bytes, deadline_seconds: 1_000_000, clock: clock).sheets.first.rows.size
    assert_operator ticks, :>, 1000, "the clock is looked at on every node"
  end

  def test_the_deadline_reaches_the_page_as_a_fallback
    bytes = XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([["a", 1]]) })
    ticks = 0
    error = assert_raises(Preview::TooLarge) { Preview.read_spreadsheet(bytes, clock: -> { ticks += 100 }) }
    assert_match(/takes more than #{Preview::SPREADSHEET_DEADLINE_SECONDS} seconds/, error.message)
  end

  def test_text_the_reader_would_never_keep_is_never_asked_of_the_parser
    megabyte = "z" * 1_000_000
    # Past the last column shown: twenty megabytes the parser is never asked for.
    outside = (1..20).map { |r| %(<row r="#{r}"><c r="A#{r}"><v>#{r}</v></c><c r="AZ#{r}" t="inlineStr"><is><t>#{megabyte}</t></is></c></row>) }.join
    sheet = read(XlsxBuilder.workbook({ "S" => outside }), max_parsed_text_bytes: 50_000, inflate_budget: 64 * 1_048_576).sheets.first
    assert_equal 20, sheet.rows.size
    assert sheet.truncated_columns

    # One cell in a thousand rich-text runs: reading stops once the cell is full.
    runs = "<r><t>#{'c' * 1000}</t></r>" * 1000
    rows = %(<row r="1"><c r="A1" t="inlineStr"><is>#{runs}</is></c></row>)
    cell = read(XlsxBuilder.workbook({ "S" => rows }), max_parsed_text_bytes: 100_000).sheets.first.rows[0][0]
    assert_equal Preview::MAX_CELL_CHARS + 1, cell.text.length

    # The same megabyte as adjacent CDATA sections reaches the reader as ONE
    # node (the parser joins them), so there is no stopping partway: it is
    # counted whole, and the parsed-text budget is what answers it.
    pieces = "<![CDATA[#{'c' * 1000}]]>" * 1000
    joined = %(<row r="1"><c r="A1" t="inlineStr"><is><t>#{pieces}</t></is></c></row>)
    assert_raises(Preview::TooLarge) { read(XlsxBuilder.workbook({ "S" => joined }), max_parsed_text_bytes: 100_000) }
  end

  def test_the_parsed_text_budget_ends_the_read
    rows = XlsxBuilder.rows((1..30).map { |n| ["#{n}" * 1000] })
    error = assert_raises(Preview::TooLarge) { read(XlsxBuilder.workbook({ "S" => rows }), max_parsed_text_bytes: 10_000) }
    assert_equal "it holds more text than a preview reads", error.message
    assert_equal 30, read(XlsxBuilder.workbook({ "S" => rows }), max_parsed_text_bytes: 200_000).sheets.first.rows.size
  end

  def test_attributes_are_counted_as_parsed_text_too
    # Text can hide in an attribute as easily as in a node: here, in format
    # codes that the table would never keep.
    formats = (0...300).map { |n| %(<numFmt numFmtId="#{164 + n}" formatCode="#{'0' * 250}"/>) }.join
    styles = %(<?xml version="1.0"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts>#{formats}</numFmts><cellXfs><xf numFmtId="0"/></cellXfs></styleSheet>)
    bytes = XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([[1]]) }, extra: { "xl/styles.xml" => styles })

    assert_raises(Preview::TooLarge) { read(bytes, max_parsed_text_bytes: 20_000) }
    assert_equal [["1"]], texts(read(bytes, max_parsed_text_bytes: 200_000).sheets.first)
  end

  def test_a_row_of_duplicate_cells_spends_the_cell_budget_cell_by_cell
    row = %(<row r="1">#{'<c r="A1"><v>7</v></c>' * 200}</row>)
    workbook = read(XlsxBuilder.workbook({ "S" => row, "After" => XlsxBuilder.rows([["x"]]) }), max_cells: 50)

    sheet = workbook.sheets.first
    assert sheet.truncated_rows, "the budget ran out inside the row, and the sheet says it was cut"
    assert_equal 0, sheet.row_limit
    assert_empty sheet.rows
    assert_equal 1, workbook.omitted_sheets

    whole = read(XlsxBuilder.workbook({ "S" => %(<row r="1">#{'<c r="A1"><v>7</v></c>' * 50}</row>) }), max_cells: 50).sheets.first
    assert_equal [["7"]], texts(whole)
    refute whole.truncated_rows
  end

  def test_a_number_format_table_past_its_cap_renders_general
    count = Preview::Xlsx::MAX_CUSTOM_FORMATS + 10
    formats = (0...count).map { |n| %(<numFmt numFmtId="#{164 + n}" formatCode="0.00"/>) }.join
    styles = %(<?xml version="1.0"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts>#{formats}</numFmts>) +
             %(<cellXfs><xf numFmtId="164"/><xf numFmtId="#{164 + count - 1}"/></cellXfs></styleSheet>)
    rows = %(<row r="1"><c r="A1" s="0"><v>1.5</v></c><c r="B1" s="1"><v>1.5</v></c></row>)
    reader = reader_for(XlsxBuilder.workbook({ "S" => rows }, extra: { "xl/styles.xml" => styles }))

    assert_equal [["1.50", "1.5"]], texts(reader.read.sheets.first), "a format past the table's cap is not known, so General"
    assert_equal Preview::Xlsx::MAX_CUSTOM_FORMATS, reader.instance_variable_get(:@custom_formats).size
  end

  def test_distinct_formats_past_the_tokenize_cap_render_general
    cap = Preview::Xlsx::MAX_TOKENIZED_FORMATS
    count = cap + 40
    formats = (0...count).map { |n| "0.00\"f#{n}\"" }
    row = %(<row r="1">#{(0...count).map { |n| %(<c r="A1" s="#{n + 1}"><v>2.5</v></c>) }.join}</row>)
    reader = reader_for(XlsxBuilder.workbook({ "S" => row }, formats: formats))
    sheet = reader.read.sheets.first

    assert_equal [["2.5"]], texts(sheet), "the last duplicate won, on a format the cache had no room for"
    assert_operator reader.instance_variable_get(:@sections).size, :<=, cap + 1

    few = read(XlsxBuilder.workbook({ "S" => %(<row r="1"><c r="A1" s="3"><v>2.5</v></c></row>) }, formats: formats.first(5))).sheets.first
    assert_equal [["2.50f2"]], texts(few)
  end

  def test_too_many_parts_or_sheets_is_refused
    cap = Preview::Xlsx::MAX_RELATIONSHIPS
    many = rels((1..(cap + 1)).map { |n| ["rId#{n}", "worksheets/sheet1.xml"] })
    error = assert_raises(Preview::Unreadable) do
      read(XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([[1]]) }, extra: { "xl/_rels/workbook.xml.rels" => many }))
    end
    assert_equal "it has too many parts", error.message

    at_cap = rels((1..cap).map { |n| ["rId#{n}", "worksheets/sheet1.xml"] })
    assert_equal [["1"]], texts(read(XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([[1]]) }, extra: { "xl/_rels/workbook.xml.rels" => at_cap })).sheets.first)

    sheets = (1..(Preview::Xlsx::MAX_LISTED_SHEETS + 1)).map { |n| %(<sheet name="s#{n}" sheetId="#{n}" r:id="rId1"/>) }.join
    book = %(<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>#{sheets}</sheets></workbook>)
    error = assert_raises(Preview::Unreadable) do
      read(XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([[1]]) }, extra: { "xl/workbook.xml" => book }))
    end
    assert_equal "it has too many sheets", error.message
  end

  def test_an_oversized_relationship_id_is_not_kept
    long = "x" * (Preview::Xlsx::MAX_ATTRIBUTE_CHARS + 1)
    reader = reader_for(XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([[1]]) },
                                             extra: { "xl/_rels/workbook.xml.rels" => rels([["rId1", "worksheets/sheet1.xml"], [long, "worksheets/sheet1.xml"]]) }))
    assert_equal ["rId1"], reader.send(:read_relationships).keys
  end

  def test_a_row_reference_is_never_read_as_a_huge_number
    reader = reader_for(XlsxBuilder.workbook({ "S" => "" }))
    assert_equal 12, reader.send(:small_number, "12")
    assert_equal 99_999_999, reader.send(:small_number, "99999999")
    assert_nil reader.send(:small_number, "999999999"), "nine characters is already more than any number Excel writes"
    assert_nil reader.send(:small_number, "9" * 2_000_000)
    assert_nil reader.send(:small_number, "-4")
    assert_nil reader.send(:small_number, "1e3")
    assert_nil reader.send(:small_number, nil)

    rows = %(<row r="1"><c r="A1"><v>1</v></c></row><row r="#{'9' * 60_000}"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>)
    sheet = read(XlsxBuilder.workbook({ "S" => rows })).sheets.first
    assert_equal [["1"]], texts(sheet)
    assert sheet.truncated_rows
  end

  def test_a_row_below_one_ends_the_sheet_and_cannot_buy_grid_budget
    bad = %(<row r="2"><c r="A2"><v>1</v></c></row><row r="-5"><c r="A1"><v>9</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>)
    only_bad = %(<row r="-500"><c r="AX1"><v>9</v></c></row>)
    far = %(<row r="10"><c r="D10"><v>1</v></c></row>)
    workbook = read(XlsxBuilder.workbook({ "Bad" => bad, "OnlyBad" => only_bad, "Zero" => %(<row r="0"><c r="A1"><v>9</v></c></row>), "Far" => far }),
                    max_grid_cells: 50)

    first, second, third, fourth = workbook.sheets
    assert_equal [[nil], ["1"]], texts(first)
    assert first.truncated_rows
    assert_equal 2, first.row_limit
    assert_empty second.rows
    assert second.truncated_rows
    assert_empty third.rows
    assert third.truncated_rows, "row 0 is not a row"
    # 2 cells went to the first sheet; the malformed ones added nothing back,
    # so the 40-cell rectangle of the last sheet still fits and no more would.
    assert_equal 10, fourth.rows.size
    assert_equal 8, reader_grid_left(workbook, 50)
  end

  def reader_grid_left(workbook, budget)
    budget - workbook.sheets.sum { |sheet| sheet.rows.sum(&:size) }
  end

  def test_a_cell_with_no_column_or_a_wild_style_or_string_index_is_harmless
    rows = %(<row r="1"><c r="1"><v>5</v></c><c r="B1" s="#{'9' * 5000}"><v>2.5</v></c><c r="C1" t="s"><v>#{'9' * 5000}</v></c><c r="D1" t="s"><v>-1</v></c></row>)
    sheet = read(XlsxBuilder.workbook({ "S" => rows }, formats: ["0.00"], shared: ["only"])).sheets.first
    assert_equal [[nil, "2.5"]], texts(sheet)

    no_column = read(XlsxBuilder.workbook({ "S" => %(<row r="1"><c r="1"><v>5</v></c></row>) })).sheets.first
    assert_empty no_column.rows, "a cell with no column letters is not a cell in column zero"
  end

  # --- below the parser ------------------------------------------------------------------
  #
  # libxml allocates inside one read, before any node reaches Ruby, and for a
  # DTD or a huge attribute list it spends many times the bytes it was given.
  # XmlGuard stands between the inflater and the parser so it never gets one.

  Guard = Studio::KnowledgePreview::XmlGuard

  # Feeds `bytes` through the guard the way the parser does, `ask` bytes at a
  # time, from a source that itself yields `step` bytes at a time.
  def guarded(bytes, ask: 4000, step: nil, **options)
    source = StringIO.new(bytes.b)
    source.define_singleton_method(:read) { |length = nil, *| super(step ? [length || step, step].min : length) } if step
    guard = Guard.new(source, **options)
    out = +"".b
    while (chunk = guard.read(ask))
      out << chunk
    end
    [out, guard.failure]
  end

  def test_the_guard_passes_an_ordinary_part_through_byte_for_byte
    part = %(<?xml version="1.0" encoding="UTF-8"?>\n<worksheet><!-- a < note --><sheetData><row r="1"><c t="inlineStr"><is><t><![CDATA[a < b]]></t></is></c></row></sheetData></worksheet>)
    [[4000, nil], [7, 3], [1, 1], [5, 2]].each do |ask, step|
      out, failure = guarded(part, ask: ask, step: step)
      assert_nil failure, "ask #{ask}, step #{step}"
      assert_equal part.b, out
    end
    out, failure = guarded("\xEF\xBB\xBF".b + part, ask: 2, step: 1)
    assert_nil failure
    assert_equal part.bytesize + 3, out.bytesize
  end

  def test_the_guard_refuses_a_doctype_wherever_a_chunk_boundary_falls
    part = %(<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x "y">]><a>&x;</a>)
    at = part.index("<!DOCTYPE")
    (1..12).each do |step|
      out, failure = guarded(part, ask: step, step: step)
      assert_kind_of Preview::Unreadable, failure, "step #{step}"
      assert_match(/document type declaration/, failure.message)
      refute_includes out, "ENTITY", "nothing of the DTD's body reaches the parser (step #{step})"
      assert_operator out.bytesize, :<, at + 9 + step
    end
  end

  def test_the_guard_matches_doctype_exactly_as_the_parser_does
    # libxml reads "<!doctype" as a malformed tag, not as a DTD, so it is not
    # this guard's business; the parser's own syntax error answers it.
    _out, failure = guarded(%(<?xml version="1.0"?><!doctype a [<!ENTITY x "y">]><a/>))
    assert_nil failure
    bytes = XlsxBuilder.workbook({ "S" => "" }, extra: { "xl/worksheets/sheet1.xml" => %(<?xml version="1.0"?><!doctype a []><worksheet/>) })
    assert_match(/damaged/, assert_raises(Preview::Unreadable) { read(bytes) }.message)

    # Inside a comment or a CDATA section the same bytes are only text.
    quoted = %(<?xml version="1.0"?><a><!-- <!DOCTYPE x> --><![CDATA[<!DOCTYPE html>]]></a>)
    [nil, 1, 4].each { |step| assert_nil guarded(quoted, ask: step || 4000, step: step).last, "step #{step.inspect}" }
  end

  def test_the_guard_measures_a_text_node_across_chunks
    limit = 1000
    fits = "<a>" + ("t" * limit) + "</a>"
    over = "<a>" + ("t" * (limit + 1)) + "</a>"
    [[4000, nil], [64, 64], [7, 3], [1, 1]].each do |ask, step|
      assert_nil guarded(fits, ask: ask, step: step, max_token_bytes: limit).last, "text of exactly the limit passes (ask #{ask})"
      out, failure = guarded(over, ask: ask, step: step, max_token_bytes: limit)
      assert_kind_of Preview::TooLarge, failure, "one byte more does not (ask #{ask})"
      assert_operator out.bytesize, :<=, limit + 3 + ask
    end
    many = "<a>" + ("<b>#{'t' * 900}</b>" * 50) + "</a>"
    assert_nil guarded(many, ask: 50, max_token_bytes: limit).last, "many text nodes under the limit are not one over it"
  end

  def test_the_guard_measures_a_start_tag_across_chunks
    limit = 1000
    # The tag is counted from its "<" to its ">", both included.
    fits = "<a " + ("b" * (limit - 5)) + "/><c/>"
    over = "<a " + ("b" * (limit - 4)) + "/><c/>"
    assert_equal limit, fits.index(">") + 1
    [[4000, nil], [64, 64], [7, 3], [1, 1]].each do |ask, step|
      assert_nil guarded(fits, ask: ask, step: step, max_open_tag_bytes: limit).last, "a tag of exactly the limit passes (ask #{ask})"
      out, failure = guarded(over, ask: ask, step: step, max_open_tag_bytes: limit)
      assert_kind_of Preview::TooLarge, failure, "one byte more does not (ask #{ask})"
      assert_operator out.bytesize, :<=, limit + ask, "and the parser is not handed the whole of it"
    end
  end

  def test_the_guard_counts_start_tags_across_every_element_open_at_once
    limit = 1000
    tag = ->(name) { "<#{name} #{'b' * 296}>" } # 300 bytes with a one-letter name
    assert_equal 300, tag.("x").bytesize
    three_open = tag.("x") * 3
    four_open = tag.("x") * 4
    [[4000, nil], [7, 3], [1, 1]].each do |ask, step|
      assert_nil guarded(three_open, ask: ask, step: step, max_open_tag_bytes: limit).last, "900 bytes open at once fit (ask #{ask})"
      assert_kind_of Preview::TooLarge, guarded(four_open, ask: ask, step: step, max_open_tag_bytes: limit).last,
                     "1,200 do not, though no one tag is over the limit (ask #{ask})"
    end

    # The same tags one after another are never open together.
    in_turn = "<r>" + ((tag.("x") + "</x>") * 40) + "</r>"
    assert_nil guarded(in_turn, ask: 13, max_open_tag_bytes: limit).last, "an end tag gives its element's bytes back"
    self_closing = "<r>" + ("<x #{'b' * 295}/>" * 40) + "</r>"
    assert_nil guarded(self_closing, ask: 13, max_open_tag_bytes: limit).last, "a self-closing tag is never open"
    # ...and what was given back can be spent again, but not twice at once.
    again = "<r>" + (tag.("x") * 3) + ("</x>" * 3) + (tag.("x") * 3) + tag.("x")
    assert_kind_of Preview::TooLarge, guarded(again, ask: 13, max_open_tag_bytes: limit).last
  end

  def test_the_guard_reads_a_tag_the_way_the_parser_does
    limit = 200
    # A ">" inside a quoted value does not end the tag, so the bytes after it
    # are still the tag's, in either kind of quote and across any boundary.
    [%(<a b=">#{'x' * 300}"/>), %(<a b='>#{'x' * 300}'/>), %(<a b="'>" c='">#{'x' * 300}'/>)].each do |hidden|
      [[4000, nil], [1, 1], [5, 2]].each do |ask, step|
        assert_kind_of Preview::TooLarge, guarded(hidden, ask: ask, step: step, max_open_tag_bytes: limit).last, hidden[0, 16]
      end
    end
    # "/>" split across chunks is still self-closing; "/" inside a value is not.
    split = "<r>" + ("<x #{'b' * 100}/>" * 30) + "</r>"
    (1..9).each { |step| assert_nil guarded(split, ask: step, step: step, max_open_tag_bytes: limit).last, "step #{step}" }
    slash_in_value = "<r>" + (%(<x b="#{'b' * 100}/">) * 2)
    assert_kind_of Preview::TooLarge, guarded(slash_in_value, max_open_tag_bytes: limit).last
  end

  # Builds a random well-formed document and, alongside it, the two figures
  # the guard is supposed to be measuring: the most start-tag bytes ever open
  # at once, and the longest text or opaque token.
  class RandomDocument
    attr_reader :xml, :max_open, :max_token, :asides

    def initialize(random)
      @random = random
      @max_open = 0
      @max_token = 0
      @asides = 0
      @xml = +""
      element(0, 0)
    end

    private

    def word(max) = Array.new(@random.rand(1..max)) { ("a".."z").to_a.sample(random: @random) }.join

    def value
      body = Array.new(@random.rand(0..6)) { ["x", ">", "/", " ", "'", "xmlns", "&lt;", "]]>", "-->", "?>"].sample(random: @random) }.join
      quote = ['"', "'"].sample(random: @random)
      quote == "'" ? "'#{body.delete("'")}'" : "\"#{body}\""
    end

    def element(depth, open_above)
      attributes = Array.new(@random.rand(0..4)) { |n| " #{word(3)}#{n}=#{value}" }.join
      space = [" ", "", "\n"].sample(random: @random)
      name = word(4)
      if depth > 5 || @random.rand < 0.3
        tag = "<#{name}#{attributes}#{space}/>"
        @max_open = [@max_open, open_above + tag.bytesize].max
        @xml << tag
        return
      end

      tag = "<#{name}#{attributes}#{space}>"
      open_here = open_above + tag.bytesize
      @max_open = [@max_open, open_here].max
      @xml << tag
      last_was_text = false
      @random.rand(0..5).times do
        case @random.rand(5)
        when 0
          next if last_was_text

          text = Array.new(@random.rand(1..40)) { ["t", " ", ">", "'", "\"", "&amp;", "/", "xmlns"].sample(random: @random) }.join
          @max_token = [@max_token, text.bytesize].max
          @xml << text
          last_was_text = true
          next
        when 1 then aside("<!--", Array.new(@random.rand(0..30)) { ["<", ">", "c", "- ", "<!DOCTYPE", "\""].sample(random: @random) }.join, "-->")
        when 2 then opaque("<![CDATA[", Array.new(@random.rand(0..30)) { ["<", ">", "] ", "d", "<!DOCTYPE", "'"].sample(random: @random) }.join, "]]>")
        when 3 then aside("<?pi ", Array.new(@random.rand(0..30)) { ["<", ">", "p", "? ", "\""].sample(random: @random) }.join, "?>")
        else element(depth + 1, open_here)
        end
        last_was_text = false
      end
      end_tag = "</#{name}#{space}>"
      # An end tag is read while its own element is still open.
      @max_open = [@max_open, open_here + end_tag.bytesize].max
      @xml << end_tag
    end

    def opaque(open, body, close)
      whole = open + body + close
      @max_token = [@max_token, whole.bytesize].max
      @xml << whole
    end

    # Comments and instructions are measured as one running total.
    def aside(open, body, close)
      whole = open + body + close
      @asides += whole.bytesize
      @xml << whole
    end
  end

  def test_the_guard_measures_random_documents_exactly_at_every_chunking
    random = Random.new(20_311_008)
    120.times do |round|
      document = RandomDocument.new(random)
      xml = %(<?xml version="1.0"?>) + document.xml
      # The parser is the referee for "well-formed": what the guard passes
      # must be a document libxml reads to the end.
      Nokogiri::XML::Reader.from_io(StringIO.new(xml), nil, "UTF-8", 2048).each { |_| nil }
      asides = document.asides + 21 # the XML declaration is an instruction too
      step = [nil, 1, 2, 3, 5, 8, 13].sample(random: random)
      ask = step || 4000
      label = "round #{round}, step #{step.inspect}"
      limits = { max_open_tag_bytes: document.max_open, max_token_bytes: [document.max_token, 1].max, max_aside_bytes: asides }

      out, failure = guarded(xml, ask: ask, step: step, **limits)
      assert_nil failure, "#{label}: limits equal to the document's own figures must pass\n#{xml}"
      assert_equal xml.b, out, label
      assert_kind_of Preview::TooLarge, guarded(xml, ask: ask, step: step, **limits, max_open_tag_bytes: document.max_open - 1).last,
                     "#{label}: one byte less of open-tag budget must refuse\n#{xml}"
      assert_kind_of Preview::TooLarge, guarded(xml, ask: ask, step: step, **limits, max_aside_bytes: asides - 1).last,
                     "#{label}: one byte less for comments and instructions must refuse\n#{xml}"
      next unless document.max_token > 1

      assert_kind_of Preview::TooLarge, guarded(xml, ask: ask, step: step, **limits, max_token_bytes: document.max_token - 1).last,
                     "#{label}: one byte less of token budget must refuse\n#{xml}"
    end
  end

  def test_the_guard_bounds_nesting_and_namespace_declarations
    deep = "<a>" * (Guard::MAX_DEPTH + 1)
    assert_kind_of Preview::TooLarge, guarded(deep).last
    assert_nil guarded("<a>" * Guard::MAX_DEPTH).last

    declared = "<r>" + (0...11).map { |n| %(<c xmlns:p#{n}="u"/>) }.join + "</r>"
    [[4000, nil], [1, 1], [6, 6]].each do |ask, step|
      assert_kind_of Preview::TooLarge, guarded(declared, ask: ask, step: step, max_namespace_declarations: 10).last, "ask #{ask}"
      assert_nil guarded(declared, ask: ask, step: step, max_namespace_declarations: 11).last, "ask #{ask}"
    end
    in_text = %(<r>xmlns xmlns xmlns <c b="xmlns xmlns"/></r>)
    assert_nil guarded(in_text, max_namespace_declarations: 1).last, "the word in text or in a value declares nothing"
  end

  def test_the_guard_measures_comments_cdata_and_instructions_which_may_hold_angle_brackets
    limit = 1000
    {
      "comment" => ["<!--", "-->"], "cdata" => ["<![CDATA[", "]]>"], "instruction" => ["<?p ", "?>"]
    }.each do |name, (open, close)|
      over = "<a>#{open}#{'<' * 2000}#{close}</a>"
      fits = "<a>#{open}#{'<' * 900}#{close}</a>"
      [[4000, nil], [9, 4], [1, 1]].each do |ask, step|
        assert_kind_of Preview::TooLarge, guarded(over, ask: ask, step: step, max_token_bytes: limit, max_aside_bytes: limit).last, "#{name}, ask #{ask}"
        assert_nil guarded(fits, ask: ask, step: step, max_token_bytes: limit, max_aside_bytes: limit).last, "#{name}, ask #{ask}"
      end
      # After it closes, measuring starts again.
      assert_nil guarded("<a>#{open}#{'<' * 900}#{close}#{'t' * 900}<b/></a>", max_token_bytes: limit, max_aside_bytes: limit).last, name
    end
  end

  def test_comments_and_instructions_are_held_to_their_own_smaller_limit
    # A CDATA section is cell text and gets the text limit; a comment or an
    # instruction gets the aside limit, and going back to text restores the
    # text limit.
    body = "<" * 500
    assert_nil guarded("<a><![CDATA[#{body}]]></a>", max_token_bytes: 1000, max_aside_bytes: 100).last
    assert_kind_of Preview::TooLarge, guarded("<a><!--#{body}--></a>", max_token_bytes: 1000, max_aside_bytes: 100).last
    assert_kind_of Preview::TooLarge, guarded("<a><?p #{body}?></a>", max_token_bytes: 1000, max_aside_bytes: 100).last
    assert_nil guarded("<a><!--ok-->#{'t' * 500}<b/></a>", max_token_bytes: 1000, max_aside_bytes: 100).last
    assert_kind_of Preview::TooLarge, guarded("<a><![CDATA[#{body}]]><!--#{'c' * 200}--></a>", max_token_bytes: 1000, max_aside_bytes: 100).last

    # The aside limit is a total for the part: many small ones add up.
    small = "<!--#{'c' * 13}-->" # 20 bytes
    assert_nil guarded("<a>#{small * 5}</a>", max_aside_bytes: 100).last
    assert_kind_of Preview::TooLarge, guarded("<a>#{small * 5}<?p?></a>", max_aside_bytes: 100).last
    assert_kind_of Preview::TooLarge, guarded("<a>#{(small + '<b/>') * 6}</a>", ask: 3, step: 3, max_aside_bytes: 100).last
  end

  def test_the_guard_refuses_a_part_that_is_not_utf8_markup_from_its_first_byte
    doc = %(<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x "y">]><a>&x;</a>)
    {
      "UTF-16LE with a byte order mark" => "\xFF\xFE".b + doc.encode("UTF-16LE").b,
      "UTF-16BE with a byte order mark" => "\xFE\xFF".b + doc.encode("UTF-16BE").b,
      "UTF-16LE with none" => doc.encode("UTF-16LE").b,
      "UTF-16BE with none" => doc.encode("UTF-16BE").b,
      "UTF-32" => doc.encode("UTF-32LE").b,
      "leading text" => "x" + doc,
      "a byte order mark and then text" => "\xEF\xBB\xBFx<a/>".b
    }.each do |name, bytes|
      [[4000, nil], [1, 1]].each do |ask, step|
        out, failure = guarded(bytes, ask: ask, step: step)
        assert_kind_of Preview::Unreadable, failure, name
        assert_equal "its XML is not UTF-8", failure.message
        assert_operator out.bytesize, :<=, 1, "#{name}: at most the one '<' byte that looked like markup is handed over"
      end
    end
    assert_kind_of Preview::Unreadable, guarded("<a>x\x00y</a>").last, "a NUL anywhere is not UTF-8 XML"
  end

  def sheet_workbook(sheet_xml)
    XlsxBuilder.workbook({ "S" => "" }, extra: { "xl/worksheets/sheet1.xml" => sheet_xml })
  end

  NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
  ONE_CELL = '<sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData>'

  def test_a_part_with_a_dtd_never_reaches_the_parser
    declarations = (0...20_000).map { |n| "<!ATTLIST a#{n} b CDATA #IMPLIED><!ENTITY e#{n} \"x\">" }.join
    bytes = sheet_workbook(%(<?xml version="1.0"?><!DOCTYPE worksheet [#{declarations}]><worksheet #{NS}>#{ONE_CELL}</worksheet>))

    error = assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(bytes) }
    assert_equal "it carries a document type declaration, which no workbook has", error.message
  end

  def test_a_utf16_part_carrying_a_dtd_is_refused_not_parsed
    doc = %(<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE worksheet [<!ENTITY x "y">]><worksheet #{NS}>#{ONE_CELL}</worksheet>)
    ["\xFF\xFE".b + doc.encode("UTF-16LE").b, doc.encode("UTF-16LE").b, doc.encode("UTF-16BE").b].each do |part|
      error = assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(sheet_workbook(part)) }
      assert_equal "its XML is not UTF-8", error.message
    end
  end

  def test_an_encoding_the_part_declares_for_itself_is_ignored
    # ASCII bytes that claim to be UTF-16, UTF-7 or EBCDIC: read as the UTF-8
    # they are, so what the guard scanned is what the parser parsed.
    %w[UTF-16 UTF-7 IBM037].each do |claimed|
      part = %(<?xml version="1.0" encoding="#{claimed}"?><worksheet #{NS}>#{ONE_CELL}</worksheet>)
      assert_equal [["1"]], texts(Preview.read_spreadsheet(sheet_workbook(part)).sheets.first), claimed
    end
    # UTF-7 spelling of "<!DOCTYPE" stays the text it is.
    hidden = %(<?xml version="1.0" encoding="UTF-7"?><worksheet #{NS}><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>+ADwAIQ-DOCTYPE</t></is></c></row></sheetData></worksheet>)
    assert_equal [["+ADwAIQ-DOCTYPE"]], texts(Preview.read_spreadsheet(sheet_workbook(hidden)).sheets.first)
    # And bytes that are NOT UTF-8 are refused, whatever they declare.
    latin = %(<?xml version="1.0" encoding="ISO-8859-1"?><worksheet #{NS}><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>caf\xE9</t></is></c></row></sheetData></worksheet>).b
    assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(sheet_workbook(latin)) }
  end

  def test_a_start_tag_past_the_open_tag_limit_is_refused_wherever_it_is
    attributes = (0...9_000).map { |n| %(z#{n.to_s(36)}="") }.join(" ")
    assert_operator attributes.bytesize, :>, Guard::MAX_OPEN_TAG_BYTES

    on_row = sheet_workbook(%(<?xml version="1.0"?><worksheet #{NS}><sheetData><row r="1" #{attributes}><c r="A1"><v>1</v></c></row></sheetData></worksheet>))
    on_cell = sheet_workbook(%(<?xml version="1.0"?><worksheet #{NS}><sheetData><row r="1"><c r="A1" #{attributes}><v>1</v></c></row></sheetData></worksheet>))
    book = %(<?xml version="1.0"?><workbook #{NS} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="S" sheetId="1" r:id="rId1" #{attributes}/></sheets></workbook>)
    on_sheet = XlsxBuilder.workbook({ "S" => XlsxBuilder.rows([[1]]) }, extra: { "xl/workbook.xml" => book })

    [on_row, on_cell, on_sheet].each do |bytes|
      error = assert_raises(Preview::TooLarge) { Preview.read_spreadsheet(bytes) }
      assert_equal "its XML holds more in one place than a preview reads", error.message
    end
  end

  def test_start_tags_nested_inside_one_another_are_refused_by_their_sum
    # Each tag is a quarter of the limit, so each passes alone; left open
    # inside one another, the fifth is past it. This is the input the parser
    # pays most for: it keeps every open element's attributes alive.
    attributes = (0...2_100).map { |n| %(z#{n.to_s(36)}="") }.join(" ")
    tag = "<x #{attributes}>"
    assert_in_delta Guard::MAX_OPEN_TAG_BYTES / 4, tag.bytesize, 2_000
    nested = sheet_workbook(%(<?xml version="1.0"?><worksheet #{NS}><sheetData><row r="1">#{tag * 60}#{'</x>' * 60}</row></sheetData></worksheet>))
    in_turn = sheet_workbook(%(<?xml version="1.0"?><worksheet #{NS}><sheetData><row r="1">#{(tag + '</x>') * 60}<c r="A1"><v>1</v></c></row></sheetData></worksheet>))

    assert_raises(Preview::TooLarge) { Preview.read_spreadsheet(nested) }
    assert_equal [["1"]], texts(Preview.read_spreadsheet(in_turn).sheets.first)
  end

  def test_a_text_node_past_the_token_limit_is_refused_before_the_parser_builds_it
    # Past the last column, so nothing in Ruby would ever ask for this text.
    row = %(<row r="1"><c r="ZZ1" t="inlineStr"><is><t>#{'q' * (Guard::MAX_TOKEN_BYTES + 10)}</t></is></c></row>)
    error = assert_raises(Preview::TooLarge) { Preview.read_spreadsheet(sheet_workbook(%(<?xml version="1.0"?><worksheet #{NS}><sheetData>#{row}</sheetData></worksheet>))) }
    assert_equal "its XML holds more in one place than a preview reads", error.message
  end

  def test_the_longest_cell_excel_allows_is_far_inside_the_token_limit
    # 32,767 characters, each written as the longest numeric reference.
    longest = "&#x1F600;" * Preview::MAX_CELL_CHARS
    assert_operator longest.bytesize, :<, Guard::MAX_TOKEN_BYTES / 3
    row = %(<row r="1"><c r="A1" t="inlineStr"><is><t>#{longest}</t></is></c></row>)
    cell = Preview.read_spreadsheet(sheet_workbook(%(<?xml version="1.0"?><worksheet #{NS}><sheetData>#{row}</sheetData></worksheet>))).sheets.first.rows[0][0]
    assert_equal Preview::MAX_CELL_CHARS, cell.text.length
  end

  def test_the_relationship_id_is_found_without_listing_a_big_tags_attributes
    many = (0...40).map { |n| %(z#{n}="") }.join(" ")
    conventional = %(<?xml version="1.0"?><workbook #{NS} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="S" sheetId="1" r:id="rId1" #{many}/></sheets></workbook>)
    other_prefix = %(<?xml version="1.0"?><workbook #{NS} xmlns:rel="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="S" sheetId="1" rel:id="rId1"/></sheets></workbook>)
    crowded = other_prefix.sub('rel:id="rId1"', %(rel:id="rId1" #{many}))
    rows = XlsxBuilder.rows([[1]])

    assert_equal [["1"]], texts(read(XlsxBuilder.workbook({ "S" => rows }, extra: { "xl/workbook.xml" => conventional })).sheets.first)
    assert_equal [["1"]], texts(read(XlsxBuilder.workbook({ "S" => rows }, extra: { "xl/workbook.xml" => other_prefix })).sheets.first)
    error = assert_raises(Preview::Unreadable) { read(XlsxBuilder.workbook({ "S" => rows }, extra: { "xl/workbook.xml" => crowded })) }
    assert_equal "it has no worksheets", error.message, "an unconventional prefix is honoured only on a tag small enough to list"
  end

  def test_an_external_entity_is_not_expanded_even_with_the_guard_out_of_the_way
    # The guard refuses any DTD, which is the first defence. This is the
    # second: with the guard replaced by a pass-through, the parser's own
    # options still leave the entity unexpanded and the file unread. (The
    # entity points at plain text, so an expansion would land in the cell;
    # with entity substitution switched on in the reader, this fails.)
    canary = Tempfile.new(["knowledge-preview-canary", ".txt"])
    canary.write("canary-7f3a91")
    canary.close
    sheet_xml = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE worksheet [<!ENTITY leak SYSTEM "file://#{canary.path}">]>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>before&leak;after</t></is></c></row></sheetData>
      </worksheet>
    XML
    bytes = XlsxBuilder.workbook({ "S" => "" }, extra: { "xl/worksheets/sheet1.xml" => sheet_xml })
    assert_raises(Preview::Unreadable) { Preview.read_spreadsheet(bytes) }

    pass_through = Struct.new(:io) do
      def read(*args) = io.read(*args)
      def failure = nil
    end
    original = Guard.method(:new)
    Guard.define_singleton_method(:new) { |io, **| pass_through.new(io) }
    text = begin
      texts(Preview.read_spreadsheet(bytes).sheets.first).flatten.compact.join
    ensure
      Guard.define_singleton_method(:new, original)
    end
    assert_equal "beforeafter", text, "the reference is dropped, and the file it names is never read"
  ensure
    canary&.unlink
  end

  # --- number formats --------------------------------------------------------------------

  def test_number_format_table
    {
      [1234.5, "#,##0.00"] => "1,234.50",
      [-1234.5, "#,##0.00;(#,##0.00)"] => "(1,234.50)",
      [-1234.5, "#,##0.00"] => "-1,234.50",
      [0.0825, "0.00%"] => "8.25%",
      [1.005, "0.00"] => "1.01",
      [-5.0, '"$"#,##0'] => "-$5",
      [1234.5, "[$€-407]#,##0.00"] => "€1,234.50",
      [1234.5, '_("$"* #,##0.00_);_("$"* \(#,##0.00\);_("$"* "-"??_);_(@_)'] => "$1,234.50",
      [-1234.5, '_("$"* #,##0.00_);_("$"* \(#,##0.00\);_("$"* "-"??_);_(@_)'] => "$(1,234.50)",
      [0.0, '_(* #,##0_);_(* \(#,##0\);_(* "-"_);_(@_)'] => "-",
      [1_234_567.0, '#,##0,"k"'] => "1,235k",
      [12_345.678, "0.00E+00"] => "1.23E+04",
      [0.5, "#.00"] => ".50",
      [2.5, "0.##"] => "2.5",
      [2.0, "0.##"] => "2",
      [-0.001, "0.00"] => "0.00",
      [7.0, "000"] => "007",
      [3.14159, "General"] => "3.14159",
      [5.0, "@"] => "5",
      [7.5, "# ?/?"] => "7.5",
      [47_880.0, "d-mmm-yy"] => "1-Feb-31",
      [47_880.75, "m/d/yyyy h:mm AM/PM"] => "2/1/2031 6:00 PM",
      [47_880.0, "mmmm yyyy"] => "February 2031",
      [47_880.0, "dddd"] => "Saturday",
      [0.5, "h:mm"] => "12:00",
      [0.0423, "mm:ss"] => "00:55",
      [1.5, "[h]:mm:ss"] => "36:00:00",
      [59.0, "m/d/yyyy"] => "2/28/1900",
      [61.0, "m/d/yyyy"] => "3/1/1900",
      [-3.0, "m/d/yyyy"] => "-3"
    }.each do |(value, code), expected|
      assert_equal expected, Preview::NumberFormat.format(value, code), "#{value} as #{code}"
    end
  end

  def test_built_in_format_ids_resolve_and_a_custom_one_wins
    format = Preview::NumberFormat
    assert_equal "0.00%", format.code_for(10)
    assert_equal "m/d/yyyy", format.code_for(14)
    assert_equal "General", format.code_for(9999)
    assert_equal "0.0", format.code_for(164, { 164 => "0.0" })
    assert format.date_format?("d-mmm-yy")
    refute format.date_format?('#,##0 "days"'), "a quoted word holding d, y and s is not a date"
    assert_equal "5 days", format.format(5.0, '#,##0 "days"')
  end

  # --- delimited text --------------------------------------------------------------------

  def test_csv_reads_as_one_sheet_with_quoted_fields_intact
    csv = %(Item,Amount,Note\n"Bolts, hex",1250.00,"said ""ok"""\nNuts,(40),\n)
    sheet = Preview.read_delimited(csv)

    assert_equal [["Item", "Amount", "Note"], ["Bolts, hex", "1250.00", 'said "ok"'], ["Nuts", "(40)", nil]], texts(sheet)
    assert_equal [false, true, false], sheet.rows[1].map { |cell| cell.numeric }
    refute sheet.truncated_rows
    assert_nil sheet.name
  end

  def test_csv_caps_rows_and_columns_and_says_so
    csv = (1..(Preview::MAX_ROWS + 25)).map { |n| (1..(Preview::MAX_COLUMNS + 3)).map { |c| "r#{n}c#{c}" }.join(",") }.join("\n")
    sheet = Preview.read_delimited(csv)

    assert_equal Preview::MAX_ROWS, sheet.rows.size
    assert_equal Preview::MAX_COLUMNS, sheet.rows.first.size
    assert sheet.truncated_rows
    assert sheet.truncated_columns
    assert_equal Preview::MAX_ROWS, sheet.row_limit
  end

  def test_a_partial_csv_drops_its_cut_last_line
    sheet = Preview.read_delimited("a,b\n1,2\n3,", partial: true)

    assert_equal [%w[a b], %w[1 2]], texts(sheet)
    assert sheet.truncated_rows, "a head read is always named as partial"
    assert_equal 2, sheet.row_limit
  end

  def test_tab_separated_values
    assert_equal [%w[a b], ["1,5", "2"]], texts(Preview.read_delimited("a\tb\n1,5\t2\n", separator: "\t"))
  end

  def test_empty_and_binary_delimited_files_are_unreadable
    assert_raises(Preview::Unreadable) { Preview.read_delimited("  \n") }
    assert_raises(Preview::Unreadable) { Preview.read_delimited("a,b\x00\x01\x02".b) }
  end

  def test_decode_handles_a_bom_windows_1252_utf16_and_a_cut_character
    assert_equal "naïve", Preview.decode("\xEF\xBB\xBFna\xC3\xAFve".b)
    assert_equal "café", Preview.decode("caf\xE9".b)
    assert_equal "hi", Preview.decode("\xFF\xFEh\x00i\x00".b)
    assert_equal "caf", Preview.decode("caf\xC3".b, partial: true)
    assert Preview.decode("caf\xE9".b).valid_encoding?
  end

  # --- the Result a document gets --------------------------------------------------------

  Doc = Struct.new(:s3_key, :mime_type, :byte_size, :signed, keyword_init: true) do
    def file? = !s3_key.to_s.empty?
    def filename = File.basename(s3_key.to_s)

    def signed_url(inline_as: nil)
      self.signed = inline_as
      "https://bucket.example.test/signed?type=#{inline_as}"
    end
  end

  # Answers download(key:, max_bytes:) from memory and records each call.
  class Storage
    attr_reader :calls

    def initialize(bytes = nil, &failure)
      @bytes = bytes
      @failure = failure
      @calls = []
    end

    def download(key:, max_bytes: nil)
      @calls << { key: key, max_bytes: max_bytes }
      @failure&.call
      max_bytes ? @bytes.byteslice(0, max_bytes) : @bytes
    end
  end

  def doc(name, **attrs)
    Doc.new(s3_key: "knowledge/acme/#{name}", **attrs)
  end

  def test_a_workbook_document_previews_as_a_table
    storage = Storage.new(XlsxBuilder.workbook({ "One" => XlsxBuilder.rows([["a", 1]]), "Two" => XlsxBuilder.rows([["b", 2]]) }))
    result = Preview.for(doc("ledger.xlsx"), storage: storage)

    assert_equal :table, result.kind
    refute result.fallback?
    assert_equal %w[One Two], result.sheets.map(&:name)
    assert_equal [{ key: "knowledge/acme/ledger.xlsx", max_bytes: Preview::SPREADSHEET_MAX_BYTES + 1 }], storage.calls,
                 "the read is capped at one byte past the limit, whatever byte_size claims"
  end

  def test_an_oversized_workbook_falls_back_without_touching_storage
    storage = Storage.new("unused")
    result = Preview.for(doc("ledger.xlsx", byte_size: Preview::SPREADSHEET_MAX_BYTES + 1), storage: storage)

    assert result.fallback?
    assert_match(/too large to preview/, result.reason)
    assert_match(/20 MB/, result.reason)
    assert_empty storage.calls
    assert_nil result.error
  end

  def test_a_workbook_within_its_recorded_size_but_not_its_real_one_still_falls_back
    storage = Storage.new("z" * (Preview::SPREADSHEET_MAX_BYTES + 5))
    result = Preview.for(doc("ledger.xlsx", byte_size: 10), storage: storage)

    assert result.fallback?
    assert_match(/too large to preview/, result.reason)
  end

  def test_a_workbook_exactly_at_the_cap_is_read
    # At the cap the size check passes and the READER rejects the junk bytes.
    storage = Storage.new("z" * Preview::SPREADSHEET_MAX_BYTES)
    result = Preview.for(doc("ledger.xlsx", byte_size: Preview::SPREADSHEET_MAX_BYTES), storage: storage)

    assert_match(/could not be previewed/, result.reason)
  end

  def test_a_damaged_workbook_falls_back_with_a_reason_and_no_error_to_log
    result = Preview.for(doc("ledger.xlsx"), storage: Storage.new("not a workbook"))

    assert result.fallback?
    assert_equal "This file could not be previewed: it is not a zip archive.", result.reason
    assert_nil result.error, "a bad file is an ordinary refusal, not an incident"
  end

  def test_a_csv_document_reads_only_its_head
    body = "h1,h2\n" + ("1,2\n" * 400_000)
    assert_operator body.bytesize, :>, Preview::DELIMITED_HEAD_BYTES
    storage = Storage.new(body)
    result = Preview.for(doc("export.csv", byte_size: body.bytesize), storage: storage)

    assert_equal :table, result.kind
    assert_equal 1, result.sheets.size
    assert_equal Preview::MAX_ROWS, result.sheets.first.rows.size
    assert result.sheets.first.truncated_rows
    assert_equal Preview::DELIMITED_HEAD_BYTES + 1, storage.calls.first[:max_bytes]
  end

  def test_a_tsv_document_splits_on_tabs
    result = Preview.for(doc("export.tsv"), storage: Storage.new("a\tb\n1\t2\n"))
    assert_equal [%w[a b], %w[1 2]], texts(result.sheets.first)
  end

  def test_a_text_document_previews_its_head_and_says_when_it_is_cut
    short = Preview.for(doc("call.txt"), storage: Storage.new("Speaker A: hello\n<b>not markup</b>\n"))
    assert_equal :text, short.kind
    assert_equal "Speaker A: hello\n<b>not markup</b>\n", short.text
    refute short.truncated

    long = Preview.for(doc("call.txt"), storage: Storage.new("line\n" * 100_000))
    assert long.truncated
    assert_equal Preview::TEXT_HEAD_BYTES, long.text.bytesize
  end

  def test_pdf_and_image_documents_get_a_signed_inline_url_and_read_nothing
    storage = Storage.new("unused")
    letter = doc("letter.pdf", mime_type: "text/html")
    result = Preview.for(letter, storage: storage)

    assert_equal :pdf, result.kind
    assert_equal "https://bucket.example.test/signed?type=application/pdf", result.url
    assert_equal "application/pdf", letter.signed, "served as a PDF whatever mime type was stored"

    photo = doc("photo.jpg")
    assert_equal :image, Preview.for(photo, storage: storage).kind
    assert_equal "image/jpeg", photo.signed
    assert_empty storage.calls
  end

  def test_an_inline_kind_with_no_type_of_our_choosing_falls_back_and_signs_nothing
    odd = doc("letter.pdf")
    # No real file reaches this state today (every inline kind maps to a
    # type); the guard is for the day the two tables drift apart.
    original = Preview.method(:inline_content_type)
    Preview.define_singleton_method(:inline_content_type) { |**| nil }
    result = begin
      Preview.for(odd)
    ensure
      Preview.define_singleton_method(:inline_content_type, original)
    end

    assert result.fallback?
    assert_equal "This file could not be previewed: its type cannot be shown inline.", result.reason
    assert_nil odd.signed, "no URL is signed for the stored type"
  end

  def test_an_oversized_pdf_falls_back
    result = Preview.for(doc("letter.pdf", byte_size: Preview::INLINE_MAX_BYTES + 1))
    assert result.fallback?
    assert_match(/100 MB/, result.reason)
  end

  def test_unknown_types_and_missing_files_fall_back_with_a_plain_reason
    assert_equal "There is no inline preview for .docx files.", Preview.for(doc("memo.docx")).reason
    assert_equal "There is no inline preview for .xls files.", Preview.for(doc("legacy.xls")).reason
    assert_equal "There is no inline preview for this kind of file.", Preview.for(doc("document")).reason
    assert_equal "No file is attached.", Preview.for(Doc.new(s3_key: nil)).reason
  end

  def test_a_storage_failure_falls_back_and_hands_back_the_error
    storage = Storage.new { raise IOError, "bucket unreachable" }
    result = Preview.for(doc("ledger.xlsx"), storage: storage)

    assert result.fallback?
    assert_equal "The preview could not be built.", result.reason
    assert_kind_of IOError, result.error
    refute_includes result.reason, "bucket unreachable", "the operator's sentence carries no internals"
  end

  # --- laziness --------------------------------------------------------------------------

  def test_requiring_the_module_loads_no_reader
    script = <<~RUBY
      require "bundler/setup"
      require "studio/knowledge_preview"
      loaded = $LOADED_FEATURES.grep(/nokogiri|csv\\.rb|knowledge_preview\\/(xlsx|zip|number_format)/)
      abort "loaded early: \#{loaded.first(3).inspect}" unless loaded.empty?
      Studio::KnowledgePreview.kind_for(filename: "a.xlsx")
      print "lazy"
    RUBY
    output = IO.popen([RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", script], err: File::NULL, &:read)
    assert_equal "lazy", output
  end
end
