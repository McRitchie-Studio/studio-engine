# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# Renders the link-sidebar family (components/_link_sidebar, _sidebar_panel,
# _link_sidebar_trigger) through ActionView and pins the emitted contract:
# dual desktop/mobile panels driven by the `sidebars` Alpine store, the
# engine-owned store bridge, section/link rendering (admin chip, emoji swap,
# descriptions), and the trigger's aria wiring.
class LinkSidebarTest < Minitest::Test
  SECTIONS = [
    { title: "Site", links: [
      { label: "Home", href: "/", emoji: "🏠", desc: "Front door" },
      { label: "Docs", href: "/docs", emoji: "📚", hover_emoji: "🔎", target: "_blank" }
    ] },
    { title: "Ops", admin: true, links: [
      { label: "Errors", href: "/error_logs", emoji: "🚨" }
    ] }
  ].freeze

  def test_renders_dual_panels_with_sections_and_the_store_bridge
    html = render_sidebar(sections: SECTIONS, admin: true)
    doc = Nokogiri::HTML5.fragment(html)

    desktop = doc.at_css("#studio-link-sidebar")
    mobile  = doc.at_css("#studio-link-sidebar-mobile")
    refute_nil desktop, "expected the desktop panel"
    refute_nil mobile, "expected the mobile panel"
    assert_includes desktop["class"], "hidden md:flex"
    assert_includes mobile["class"], "md:hidden"
    assert_includes desktop["class"], "studio-link-sidebar-layer"
    assert_equal "$store.sidebars.linkTreeOpen", desktop["x-show"]
    refute_nil desktop["x-cloak"], "panel must cloak until Alpine boots"

    assert_includes html, "window.__studioLinkSidebarBridge"
    assert_includes html, "Alpine.store('sidebars', { linkTreeOpen: false })"
    assert_includes html, "turbo:before-cache"
    assert_includes html, "pageshow"
    assert_includes html, "html { overflow-x: clip; }"
  end

  def test_renders_sections_links_admin_chip_and_emoji_swap
    html = render_sidebar(sections: SECTIONS, admin: true)

    assert_includes html, "Site"
    assert_includes html, "Front door"
    assert_includes html, %(href="/docs")
    assert_includes html, %(target="_blank")
    assert_includes html, %(rel="noopener")
    assert_includes html, ">ADMIN<", "admin-flagged section must show the ADMIN chip"
    assert_includes html, "studio-emoji-swap", "hover_emoji links render through emoji_swap"
    assert_includes html, "Admin Menu", "admin viewers see the admin title"
  end

  def test_non_admin_render_uses_links_title_and_shows_logout_when_logged_in
    html = render_sidebar(sections: [SECTIONS.first], admin: false, logged_in: true)

    assert_includes html, ">Links<"
    assert_includes html, "Log out"
    assert_includes html, "/logout"
  end

  def test_logged_out_render_omits_the_logout_footer
    html = render_sidebar(sections: [SECTIONS.first], admin: false, logged_in: false)

    refute_includes html, "Log out"
  end

  def test_trigger_wires_aria_to_both_panels
    html = view(sections: [], admin: false)
           .render(partial: "components/link_sidebar_trigger", locals: { class_name: "hidden md:inline-flex" })
    doc = Nokogiri::HTML5.fragment(html)
    button = doc.at_css("button[data-link-sidebar-trigger]")

    refute_nil button
    assert_equal "studio-link-sidebar studio-link-sidebar-mobile", button["aria-controls"]
    assert_equal "dialog", button["aria-haspopup"]
    assert_includes button["class"], "hidden md:inline-flex"
    assert_includes button["@click.stop"], "$store.sidebars.linkTreeOpen"
  end

  # Regression pin (industries wave-1): the base class string used to hardcode
  # inline-flex AFTER the caller's class_name, so `hidden md:inline-flex` lost
  # the cascade and the desktop trigger rendered on mobile beside the real
  # mobile trigger. The caller owns the display class; bare renders default it.
  def test_trigger_class_name_owns_the_display_class
    html = view(sections: [], admin: false)
           .render(partial: "components/link_sidebar_trigger", locals: { class_name: "hidden md:inline-flex" })
    classes = Nokogiri::HTML5.fragment(html).at_css("button")["class"].split

    assert_includes classes, "hidden"
    assert_includes classes, "md:inline-flex"
    refute_includes classes, "inline-flex",
                    "a bare inline-flex token beats the caller's hidden in the cascade"
  end

  def test_trigger_defaults_to_inline_flex_without_class_name
    html = view(sections: [], admin: false)
           .render(partial: "components/link_sidebar_trigger")
    classes = Nokogiri::HTML5.fragment(html).at_css("button")["class"].split

    assert_includes classes, "inline-flex"
    refute_includes classes, "hidden"
  end

  # --- the geo signpost: THE REACH THIS PANEL OWES ---------------------------
  #
  # These are the tests whose absence let the gap ship. The 0.58.0 signpost went
  # into components/_admin_dropdown under the premise that the shared dropdown
  # reaches every app "from one change" — and this panel is precisely where that
  # premise breaks: wherever the host declares an admin-flagged section, the
  # engine SUPPRESSES the dropdown (studio_sidebar_replaces_admin_menu?, so two
  # cog glyphs do not read as a double gear) and this panel becomes the admin
  # menu. mcritchie-studio is that app — layouts/application.html.erb renders
  # this partial and link_tree_helper.rb stamps admin: true — so the app with
  # the largest admin surface in the ecosystem was the one guaranteed never to
  # see the row. A dropdown-only test can never catch that; this one does.

  def test_the_sidebar_carries_the_geo_signpost_for_an_admin
    html = render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true)
    doc = Nokogiri::HTML5.fragment(html)

    refute_nil doc.at_css(%(a[href="/admin/geo"])), "a sidebar-chrome app must reach the geo manager"
    assert_includes html, ">Geo<", "and the row must say what it is"
  end

  # Signage, not silence, for an app that has not turned geo on — the same
  # contract the dropdown carries, in the chrome that suppresses the dropdown.
  def test_the_sidebar_signposts_geo_even_where_it_is_unreachable
    html = render_sidebar(sections: SECTIONS, admin: true, geo_flag: false, geo_routes: false)

    assert_includes html, "geo-signpost-disabled"
    assert_includes html, "Draw the geo routes first"
    refute_includes html, "/admin/geo", "a row you are told is off must not be linked"
  end

  # Admin chrome, like every other admin row here. The panel renders for signed-in
  # non-admins too (public sections), and geo signage is not theirs.
  def test_the_geo_signpost_is_admin_only
    html = render_sidebar(sections: [SECTIONS.first], admin: false, geo_flag: true, geo_routes: true)

    refute_includes html, ">Geo<"
    refute_includes html, "/admin/geo"
  end

  # The panel closes behind the row, driven by THIS panel's store flag — the
  # partial takes the expression from its caller so a forked chrome can pass its
  # own (turf-monster's gear sidebar drives gearOpen, not linkTreeOpen).
  def test_the_geo_row_closes_the_panel_behind_it
    html = render_sidebar(sections: SECTIONS, admin: true, geo_flag: true, geo_routes: true)
    row = Nokogiri::HTML5.fragment(html).at_css(%(a[href="/admin/geo"]))

    assert_equal "$store.sidebars.linkTreeOpen = false", row["@click"]
  end

  private

  def render_sidebar(sections:, admin:, logged_in: true, geo_flag: nil, geo_routes: false)
    previous = Studio.geo_blocking_enabled
    Studio.geo_blocking_enabled = geo_flag
    view(sections: sections, admin: admin, logged_in: logged_in, geo_routes: geo_routes)
      .render(partial: "components/link_sidebar")
  ensure
    Studio.geo_blocking_enabled = previous
  end

  def view(sections:, admin:, logged_in: true, geo_routes: false)
    resolved = Studio::SidebarSections.resolve(sections, Struct.new(:a) { def admin? = true }.new(1))
    resolved = resolved.reject { |s| s[:admin] } unless admin
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.define_singleton_method(:studio_sidebar_sections) { resolved }
    view.define_singleton_method(:admin?) { admin }
    view.define_singleton_method(:logged_in?) { logged_in }
    view.define_singleton_method(:logout_path) { "/logout" }
    # Present only where the host drew the geo routes — the state that decides
    # whether the signpost links or explains.
    view.define_singleton_method(:admin_geo_path) { "/admin/geo" } if geo_routes
    view
  end
end
