# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# [unit] components/_page_header: what the row renders. Its behaviour is a browser's
# (e2e/page_header.spec.js); this tier pins the seams: the title, meta and tabs, the
# stack's attributes, and the row's element.
class PageHeaderRenderTest < Minitest::Test
  VIEWS = File.expand_path("../../app/views", __dir__)

  def render_row(**locals)
    view = ActionView::Base.with_empty_template_cache.new(
      ActionView::LookupContext.new([VIEWS]), {}, nil
    )
    Nokogiri::HTML.fragment(view.render(partial: "components/page_header", locals: locals))
  end

  TABS = [
    { label: "Users", href: "/users", current: "page" },
    { label: "Teams", href: "/teams", data: { kind: "tab" } }
  ].freeze

  def test_renders_title_meta_and_tabs
    doc = render_row(title: "Models", meta: "v1.2.3", meta_title: "studio-engine", label: "Models", tabs: TABS)
    row = doc.at_css("nav[aria-label='Models']")

    assert_equal "Models", row.at_css("h1").text
    assert_equal "v1.2.3", row.at_css(".page-header-meta").text
    assert_equal "studio-engine", row.at_css(".page-header-meta")["title"]
    assert_equal row.at_css(".page-header-lead"), row.at_css(".page-header-meta").parent, "the meta sits beside the title"
    assert_equal %w[Users Teams], row.css(".page-header-tabs a").map(&:text)
    assert_equal %w[/users /teams], row.css(".page-header-tabs a").map { |a| a["href"] }
  end

  def test_the_open_tab_is_primary_and_current_and_the_rest_are_not
    open_tab, other = render_row(title: "Models", label: "Models", tabs: TABS).css(".page-header-tabs a").to_a

    assert_equal "page", open_tab["aria-current"]
    assert_includes open_tab["class"].split, "btn-primary"
    assert_nil other["aria-current"]
    assert_includes other["class"].split, "btn-neutral"
    assert_equal "tab", other["data-kind"]
  end

  # --pin-stack-bottom includes the row's own edge, so positioning off it chases
  # itself down the page.
  def test_the_row_joins_the_stack_and_positions_off_what_is_above_it
    row = render_row(title: "Models", label: "Models", tabs: TABS).at_css("nav")

    assert_equal "page", row["data-pin"]
    assert_includes row["class"].split, "sticky"
    assert_includes row["style"], "top: var(--pin-page-top,"
    refute_includes row["style"], "--pin-stack-bottom"
    assert_includes row["style"], "z-index: var(--z-sticky"
  end

  # The publisher takes the document's first <header> as the navbar.
  def test_the_row_is_never_a_header_element
    assert_nil render_row(title: "Models", label: "Models", tabs: TABS).at_css("header")
    assert_nil render_row(title: "Plain").at_css("header")
  end

  def test_with_no_tabs_it_is_a_div_with_no_tab_strip
    doc = render_row(title: "Surveys")

    assert_nil doc.at_css("nav")
    assert_nil doc.at_css(".page-header-tabs")
    assert_nil doc.at_css(".page-header-meta")
    assert_equal "Surveys", doc.at_css("div.page-header h1").text
  end

  def test_actions_stand_where_the_tabs_would
    doc = render_row(title: "Survey", actions_html: "<a href='/x'>Export</a>".html_safe)

    assert_equal "Export", doc.at_css(".page-header-actions a").text
  end

  # The row is free for the page's own controller, and the row's own comes first in
  # the document, so it finds the row as its next sibling.
  def test_the_sentinel_carries_the_controller_and_the_row_keeps_its_own
    doc = render_row(title: "Style", label: "Sections", tabs: TABS,
                     data: { studio_controller: "style-section-nav" },
                     tabs_data: { style_section_nav_target: "scroller" })
    sentinel = doc.at_css(".page-header-sentinel")

    assert_equal "page-header", sentinel["data-studio-controller"]
    assert_equal "true", sentinel["aria-hidden"]
    assert_equal doc.at_css("nav"), sentinel.next_element
    assert_equal "style-section-nav", doc.at_css("nav")["data-studio-controller"]
    assert_equal "scroller", doc.at_css(".page-header-tabs")["data-style-section-nav-target"]
  end

  def test_row_class_replaces_the_bleed
    assert_includes render_row(title: "A").at_css(".page-header")["class"].split, "-mx-4"
    refute_includes render_row(title: "A", row_class: "mb-6").at_css(".page-header")["class"].split, "-mx-4"
  end
end
