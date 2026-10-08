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
                                max_text_bytes: 2 * 1_048_576, max_grid_cells: 100_000, inflate_cap: 8 * 1_048_576 }.merge(caps))
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

    error = assert_raises(Preview::TooLarge) { read(bytes, inflate_cap: 1_048_576) }
    assert_match(/expands past/, error.message)
    # Under a cap that admits the table, the wanted string reads (cut at the cell cap).
    assert_equal ("x" * 32_767) + "…", texts(read(bytes, inflate_cap: 16 * 1_048_576).sheets.first)[0][0]
  end

  def test_rows_past_the_cap_are_never_inflated
    # The sheet's first rows fit the inflate cap; the whole sheet does not.
    # Stopping at the row cap is what keeps the read inside it.
    values = (1..3000).map { |n| ["filler #{n} " + ("y" * 400), n] }
    bytes = XlsxBuilder.workbook({ "Big" => XlsxBuilder.rows(values) })

    assert_raises(Preview::TooLarge) { read(bytes, max_rows: 3000, inflate_cap: 200_000) }
    sheet = read(bytes, max_rows: 5, inflate_cap: 200_000).sheets.first
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

  def test_huge_inline_strings_on_many_sheets_are_cut_as_they_are_read
    big = "w" * 1_000_000
    sheets = (1..20).to_h { |n| ["T#{n}", XlsxBuilder.rows((1..50).map { [big] })] }
    workbook = Preview.read_spreadsheet(XlsxBuilder.workbook(sheets))

    assert_operator text_bytes(workbook), :<=, Preview::MAX_TEXT_BYTES
    assert_equal Preview::MAX_CELL_CHARS + 1, workbook.sheets.first.rows.first.first.text.length
    assert_equal 20, workbook.sheets.size + workbook.omitted_sheets
    assert_operator workbook.omitted_sheets, :>, 0
    assert workbook.sheets.last.truncated_rows
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

  def test_thousands_of_styles_on_one_format_tokenize_it_once
    code = '#,##0.00;[Red](#,##0.00)'
    styles = <<~XML
      <?xml version="1.0"?>
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="1"><numFmt numFmtId="164" formatCode="#{XlsxBuilder.escape(code)}"/></numFmts>
        <cellXfs count="5000">#{'<xf numFmtId="164"/>' * 5000}</cellXfs>
      </styleSheet>
    XML
    rows = %(<row r="1"><c r="A1" s="4999"><v>-1234.5</v></c></row>)
    bytes = XlsxBuilder.workbook({ "S" => rows }, extra: { "xl/styles.xml" => styles })

    calls = 0
    format = Preview::NumberFormat
    original = format.method(:tokenize)
    format.define_singleton_method(:tokenize) { |value| calls += 1; original.call(value) }
    begin
      assert_equal [["(1,234.50)"]], texts(read(bytes).sheets.first)
    ensure
      format.define_singleton_method(:tokenize, original)
    end
    assert_operator calls, :<=, 3, "one tokenize per distinct format, not one per style"
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

  def test_an_external_entity_is_not_expanded
    # The entity points at a file of plain text, so that IF it were expanded
    # the canary would land in the cell as ordinary characters. (Pointed at a
    # file holding markup, an expansion fails to parse and the test passes
    # for the wrong reason; with entity substitution switched on in the
    # reader, this one fails.)
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

    text = texts(Preview.read_spreadsheet(bytes).sheets.first).flatten.compact.join
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
