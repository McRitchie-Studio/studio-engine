# frozen_string_literal: true

require "test_helper"

# The rules behind Studio.sidebar_style: which values it takes, and which row a page lights.
class SidebarStyleTest < Minitest::Test
  LINKS = [
    { title: "Admin", links: [
      { label: "Design", href: "/admin/style" },
      { label: "Requests", href: "/build/requests" },
      { label: "Books", href: "/books" }
    ] },
    { title: "Studio", links: [
      { label: "Home", href: "/" },
      { label: "Build", href: "/build" },
      { label: "Turf", href: "https://turf.example/docs" },
      { label: "Top", href: "#top" },
      { label: "Mail", href: "mailto:team@example.com" }
    ] }
  ].freeze

  def current(path, host: "hub.example") = Studio::SidebarSections.current_href(LINKS, path, host: host)

  def test_style_takes_the_known_values_as_symbol_or_string
    assert_equal :glass, Studio::SidebarSections.style!(:glass)
    assert_equal :glass, Studio::SidebarSections.style!("glass")
    assert_equal :default, Studio::SidebarSections.style!(:default)
  end

  def test_style_refuses_anything_else_and_names_the_choices
    [:frosted, "", nil, 1].each do |bad|
      error = assert_raises(ArgumentError) { Studio::SidebarSections.style!(bad) }
      assert_includes error.message, "default, glass"
    end
  end

  def test_a_page_lights_its_own_row
    assert_equal "/books", current("/books")
    assert_equal "/books", current("/books/")
    assert_equal "/books", current("/books?entity=1")
  end

  def test_a_row_owns_the_pages_beneath_it
    assert_equal "/books", current("/books/2026/march")
  end

  def test_a_shared_prefix_that_is_not_a_segment_does_not_count
    assert_nil current("/booksellers")
  end

  # Both orders: a first-match walk passes one of them and fails the other.
  def test_the_longest_match_wins_whatever_the_order
    short_first = [{ links: [{ href: "/build" }, { href: "/build/requests" }] }]
    long_first = [{ links: [{ href: "/build/requests" }, { href: "/build" }] }]
    across_sections = [{ links: [{ href: "/build" }] }, { links: [{ href: "/build/requests" }] }]

    [short_first, long_first, across_sections].each do |sections|
      assert_equal "/build/requests", Studio::SidebarSections.current_href(sections, "/build/requests")
      assert_equal "/build/requests", Studio::SidebarSections.current_href(sections, "/build/requests/9")
      assert_equal "/build", Studio::SidebarSections.current_href(sections, "/build/9")
    end
  end

  def test_root_only_matches_itself
    assert_equal "/", current("/")
    assert_nil current("/somewhere")
  end

  def test_an_absolute_href_counts_only_on_its_own_host
    assert_nil current("/docs")
    assert_equal "https://turf.example/docs", current("/docs", host: "turf.example")
  end

  def test_an_anchor_or_a_mailto_never_lights
    assert_nil Studio::SidebarSections.current_href([{ links: [{ href: "#top" }, { href: "mailto:a@b.c" }, { href: "" }, { href: nil }] }], "/", host: nil)
  end

  # URI.parse raises InvalidComponentError for this, not InvalidURIError. This runs on every
  # page under glass, so a raise here is a 500 for a host with such an href.
  def test_an_href_uri_refuses_lights_nothing_and_leaves_the_other_rows_alone
    sections = [{ links: [{ href: "mailto:foo?bar" }, { href: "http://exa mple.com/" }, { href: "/books" }] }]

    assert_nil Studio::SidebarSections.current_href(sections, "/nowhere")
    assert_equal "/books", Studio::SidebarSections.current_href(sections, "/books")
  end

  def test_nothing_lights_without_a_path
    assert_nil current("")
    assert_nil current(nil)
  end

  def test_the_profile_row_carries_its_line_icon
    view = Struct.new(:logged_in) do
      def profile_path = "/profile"
      def logged_in? = true
    end.new(true)
    prior = Studio.respond_to?(:draw_profile_routes) && Studio.draw_profile_routes
    Studio.draw_profile_routes = true

    assert_equal "user", Studio::SidebarSections.standard(view).first[:links].first[:icon]
    assert Studio::Icons.known?("user"), "the engine must vendor the icon it names"
  ensure
    Studio.draw_profile_routes = prior
  end
end
