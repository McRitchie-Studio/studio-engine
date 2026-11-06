# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# [unit] studio/_page_header: what the row renders. Its behaviour is a browser's
# (e2e/page_header.spec.js); this tier pins the seams: the title, meta and tabs, the
# stack's attributes, and the row's element.
class PageHeaderRenderTest < Minitest::Test
  VIEWS = File.expand_path("../../app/views", __dir__)

  def render_row(**locals)
    view = ActionView::Base.with_empty_template_cache.new(
      ActionView::LookupContext.new([VIEWS]), {}, nil
    )
    Nokogiri::HTML.fragment(view.render(partial: "studio/page_header", locals: locals))
  end

  TABS = [
    { label: "Users", href: "/users", current: "page" },
    { label: "Teams", href: "/teams", data: { kind: "tab" } }
  ].freeze

  def test_renders_title_meta_and_tabs
    doc = render_row(title: "Models", meta: "v1.2.3", meta_title: "studio-engine", label: "Models", tabs: TABS)
    row = doc.at_css("div.page-header")

    assert_equal "Models", row.at_css("nav.page-header-tabs")["aria-label"], "the label names the tabs' nav"
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
    row = render_row(title: "Models", label: "Models", tabs: TABS).at_css(".page-header")

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

  # With tabs, crumbs and links, the row holds three navs side by side. The row itself
  # is no landmark (a div with no role and no name), so none nests in another.
  def test_no_landmark_nests_in_another_and_the_row_is_none
    doc = render_row(title: "Models", label: "Models", tabs: TABS, crumbs: CRUMBS,
                     links: [{ label: "Sessions", href: "/sessions" }])
    row = doc.at_css(".page-header")

    assert_equal "div", row.name
    assert_nil row["role"]
    assert_nil row["aria-label"]
    navs = doc.css("nav")
    assert_equal %w[page-header-crumbs page-header-tabs page-header-links], navs.map { |nav| nav["class"] }
    navs.each { |nav| assert_empty nav.ancestors("nav, [role='navigation'], [role='region'], header, main, aside"), nav["class"] }
    assert_equal ["Breadcrumb", "Models", "More links"], navs.map { |nav| nav["aria-label"] }
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
    assert_equal doc.at_css(".page-header"), sentinel.next_element
    assert_equal "style-section-nav", doc.at_css(".page-header")["data-studio-controller"]
    assert_equal "scroller", doc.at_css(".page-header-tabs")["data-style-section-nav-target"]
  end

  def test_row_class_replaces_the_bleed
    assert_includes render_row(title: "A").at_css(".page-header")["class"].split, "-mx-4"
    refute_includes render_row(title: "A", row_class: "mb-6").at_css(".page-header")["class"].split, "-mx-4"
  end

  CRUMBS = [{ label: "Admin", href: "/admin" }, { label: "Deployments", href: "/deployments" }].freeze

  def test_crumbs_render_a_trail_that_ends_with_the_page_itself
    doc = render_row(title: "rel-20261105-9199b4", crumbs: CRUMBS)
    trail = doc.at_css(".page-header-trail nav.page-header-crumbs[aria-label='Breadcrumb'] ol")
    links = trail.css("li a.page-header-crumb")

    assert_equal %w[Admin Deployments], links.map(&:text)
    assert_equal %w[/admin /deployments], links.map { |a| a["href"] }
    current = trail.at_css("li:last-child .page-header-crumb-current")
    assert_equal "rel-20261105-9199b4", current.text
    assert_equal "page", current["aria-current"]
    assert_nil current.at_css("a"), "the page itself is not a link"
    assert_equal "rel-20261105-9199b4", doc.at_css("h1").text, "the title stays the one h1"
  end

  def test_the_trail_comes_before_the_title_and_crumb_label_shortens_the_current_crumb
    doc = render_row(title: "A very long release title", crumb_label: "Release", crumbs: CRUMBS)

    assert_equal "Release", doc.at_css(".page-header-crumb-current").text
    row = doc.at_css(".page-header")
    assert_operator row.css("*").index(row.at_css(".page-header-trail")), :<, row.css("*").index(row.at_css("h1"))
  end

  # A crumb that leads up the trail is a Back: the page transition plays the app's move
  # the other way for it (docs/PAGE_TRANSITIONS.md).
  def test_every_ancestor_and_the_phone_parent_link_are_back_links
    doc = render_row(title: "Release", crumbs: CRUMBS)

    doc.css("a.page-header-crumb").each { |a| assert a.key?("data-page-transition-back"), a.text }
    parent = doc.at_css("a.page-header-parent")
    assert parent.key?("data-page-transition-back")
    assert_equal "/deployments", parent["href"]
    assert_equal "Back to Deployments", parent["aria-label"]
    assert_includes parent.text, "Deployments"
  end

  def test_no_crumbs_render_no_trail_and_no_parent_link
    doc = render_row(title: "Models")

    assert_nil doc.at_css(".page-header-trail")
    assert_nil doc.at_css(".page-header-parent")
  end

  def test_links_render_on_their_own_line_inside_the_sticky_row
    doc = render_row(title: "Deployments", links: [{ label: "Epics", href: "/epics" }, { label: "Recent", href: "/tasks/recent", current: "page" }])
    line = doc.at_css(".page-header > nav.page-header-links")

    assert_equal "More links", line["aria-label"]
    assert_equal %w[Epics Recent], line.css("a.page-header-link").map(&:text)
    assert_equal "page", line.css("a").last["aria-current"]
    assert_nil line.css("a").first["aria-current"]
  end

  def test_tabs_and_one_action_render_together_on_the_right
    doc = render_row(title: "Deployments", label: "Views", tabs: TABS, actions_html: "<a href='/new'>New Task</a>".html_safe)

    assert_equal %w[Users Teams], doc.css(".page-header-tabs a").map(&:text)
    assert_equal "New Task", doc.at_css(".page-header-actions a").text
    assert_equal doc.at_css(".page-header-tabs"), doc.at_css(".page-header-actions").previous_element
  end

  # One pill per row, drawn once and anchored by CSS to the tab with aria-current.
  def test_the_tabs_carry_one_hidden_glide_pill_with_the_primary_look
    doc = render_row(title: "Style", label: "Sections", tabs: TABS)
    glides = doc.css(".page-header-track > .page-header-glide")

    assert_equal 1, glides.size
    assert_equal "true", glides.first["aria-hidden"]
    assert_includes glides.first["class"].split, "btn-primary"
    assert_equal glides.first, doc.at_css(".page-header-track").element_children.last, "after the tabs, so it can anchor to any of them"
    doc.css(".page-header-track > a").each { |tab| assert tab.at_css("span.page-header-tab-label"), tab.text }
    assert_nil render_row(title: "Plain").at_css(".page-header-glide")
  end
end
