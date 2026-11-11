# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "view_component/test_case"

# [unit] Studio::TableComponent renders columns and rows, the sort hook as plain
# links with aria-sort, the empty row as an EmptyStateComponent, the phone
# scroll wrapper and the sticky-header hook, from its declared inputs.
class Studio::TableComponentTest < ViewComponent::TestCase
  ROWS = [{ name: "Ada", tasks: 3 }, { name: "Grace", tasks: 7 }].freeze
  COLUMNS = [{ key: :name, label: "Name", sortable: true }, { key: :tasks, label: "Tasks", align: :right }].freeze

  def render_inline(component, &block)
    @fragment = super
  end

  def table = @fragment.at_css("[data-table] > table")

  def render_table(**options)
    with_request_url("/lab/chips?page=3&q=a") do
      render_inline(Studio::TableComponent.new(rows: ROWS, columns: COLUMNS, **options))
    end
  end

  test "the wrapper scrolls on a phone and holds one table" do
    render_table

    wrapper = @fragment.at_css("div[data-table]")
    assert_includes wrapper[:class].split, "overflow-x-auto"
    assert_equal 1, wrapper.css("table").size
  end

  test "a header per column and a row per record, each cell in its column" do
    render_table

    assert_equal %w[Name Tasks], table.css("thead th").map { |th| th.text.strip }
    assert_equal [%w[Ada 3], %w[Grace 7]], table.css("tbody tr").map { |tr| tr.css("td").map { |td| td.text.strip } }
    table.css("thead th").each { |th| assert_equal "col", th[:scope] }
  end

  test "align sets the header and cell alignment" do
    render_table

    assert_includes table.css("thead th")[1][:class].split, "text-right"
    assert_includes table.css("tbody tr td")[1][:class].split, "text-right"
    assert_includes table.css("tbody tr td")[0][:class].split, "text-left"
  end

  test "an object row reads its attribute, and cell: overrides" do
    person = Struct.new(:name, :tasks).new("Katherine", 9)
    columns = [{ key: :name, label: "Name" }, { key: :tasks, label: "Tasks", cell: ->(row) { "#{row.tasks} open" } }]
    render_inline(Studio::TableComponent.new(rows: [person], columns: columns))

    assert_equal ["Katherine", "9 open"], table.css("tbody td").map { |td| td.text.strip }
  end

  test "a cell is escaped unless html_safe" do
    columns = [{ key: :a, label: "A" }, { key: :b, label: "B", cell: ->(_) { "<em>ok</em>".html_safe } }]
    render_inline(Studio::TableComponent.new(rows: [{ a: "<b>x</b>" }], columns: columns))

    assert_empty table.css("td b")
    refute_nil table.at_css("td em")
  end

  test "a sortable header links to the current URL with sort and direction, page dropped" do
    render_table

    th = table.at_css("th[data-table-sort-key='name']")
    href = th.at_css("a")[:href]
    uri = URI.parse(href)
    assert_equal "/lab/chips", uri.path
    assert_equal({ "q" => "a", "sort" => "name", "direction" => "asc" }, Rack::Utils.parse_query(uri.query))
    assert_nil th["aria-sort"], "an unsorted header claims a sort"
    assert_nil table.css("th")[1]["data-table-sort-key"], "a column not marked sortable got a sort hook"
    assert_empty table.css("th")[1].css("a")
  end

  test "the sorted column carries aria-sort and its arrow, and links to the other direction" do
    render_table(sort: "name", direction: "asc")
    th = table.at_css("th[data-table-sort-key='name']")
    assert_equal "ascending", th["aria-sort"]
    assert_equal "↑", th.at_css("[aria-hidden='true']").text
    assert_equal "desc", Rack::Utils.parse_query(URI.parse(th.at_css("a")[:href]).query)["direction"]

    render_table(sort: "name", direction: "desc")
    th = table.at_css("th[data-table-sort-key='name']")
    assert_equal "descending", th["aria-sort"]
    assert_equal "↓", th.at_css("[aria-hidden='true']").text
    assert_equal "asc", Rack::Utils.parse_query(URI.parse(th.at_css("a")[:href]).query)["direction"]
  end

  test "an unknown direction reads as asc" do
    render_table(sort: "name", direction: "sideways")

    assert_equal "ascending", table.at_css("th[data-table-sort-key='name']")["aria-sort"]
  end

  test "sort_url and custom param names" do
    render_table(sort_url: ->(key, dir) { "/x/#{key}/#{dir}" })
    assert_equal "/x/name/asc", table.at_css("th a")[:href]

    render_table(sort_param: "order", direction_param: "dir")
    query = Rack::Utils.parse_query(URI.parse(table.at_css("th a")[:href]).query)
    assert_equal %w[name asc], [query["order"], query["dir"]]
  end

  test "no rows renders one empty row: a bare EmptyStateComponent across every column" do
    render_inline(Studio::TableComponent.new(rows: [], columns: COLUMNS, empty: "No people yet."))

    rows = table.css("tbody tr")
    assert_equal 1, rows.size
    assert rows.first.key?("data-table-empty")
    td = rows.first.at_css("td")
    assert_equal "2", td[:colspan]
    empty = td.at_css("[data-empty-state]")
    refute_nil empty
    refute_includes empty[:class].split, "empty-state"
    assert_equal "No people yet.", empty.text.strip
  end

  test "id, min_width and sticky_header" do
    render_inline(Studio::TableComponent.new(rows: ROWS, columns: COLUMNS, id: "people", min_width: 640, sticky_header: true))

    assert_equal "people", table[:id]
    assert_equal "min-width: 640px", table[:style]
    assert table.key?("data-sticky-table-header")

    render_inline(Studio::TableComponent.new(rows: ROWS, columns: COLUMNS))
    refute table.key?("data-sticky-table-header")
    assert_nil table[:style]
  end

  test "the table and its header sit on the type scale" do
    render_table

    assert_includes table[:class].split, "type-body"
    assert_includes table.at_css("thead")[:class].split, "type-fine"
  end

  test "bad columns are refused" do
    assert_raises(ArgumentError) { Studio::TableComponent.new(rows: [], columns: []) }
    assert_raises(ArgumentError) { Studio::TableComponent.new(rows: [], columns: [{ key: :a }]) }
    assert_raises(ArgumentError) { Studio::TableComponent.new(rows: [], columns: [{ key: :a, label: "A", width: 3 }]) }
    assert_raises(ArgumentError) { Studio::TableComponent.new(rows: [], columns: [{ key: :a, label: "A", align: :middle }]) }
  end

  def wrapper = @fragment.at_css("div[data-table]")

  test "the scroll wrapper is keyboard-focusable, with an inset focus ring" do
    render_table

    assert_equal "0", wrapper[:tabindex]
    assert_includes wrapper[:class].split, "focus-visible:-outline-offset-2"
  end

  test "with no name the wrapper takes no role: a region with no name is noise" do
    render_table

    assert_nil wrapper[:role]
    assert_nil wrapper["aria-label"]
    assert_nil table.at_css("caption")
    assert_nil table["aria-label"]
  end

  test "caption renders a visually hidden caption and names the wrapper region" do
    render_table(caption: "Team members")

    caption = table.at_css("caption")
    assert_equal "Team members", caption.text
    assert_includes caption[:class].split, "sr-only"
    assert_equal table.element_children.first, caption, "a caption must be the table's first child"
    assert_equal "region", wrapper[:role]
    assert_equal "Team members", wrapper["aria-label"]
    assert_nil table["aria-label"], "the caption already names the table"
  end

  test "aria_label labels the table and the wrapper region without a caption" do
    render_table(aria_label: "Team members")

    assert_equal "Team members", table["aria-label"]
    assert_nil table.at_css("caption")
    assert_equal "region", wrapper[:role]
    assert_equal "Team members", wrapper["aria-label"]
  end

  test "a caption is escaped" do
    render_table(caption: "<b>x</b>")

    assert_equal "<b>x</b>", table.at_css("caption").text
    assert_empty table.css("b")
  end
end
