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

  private

  def render_sidebar(sections:, admin:, logged_in: true)
    view(sections: sections, admin: admin, logged_in: logged_in)
      .render(partial: "components/link_sidebar")
  end

  def view(sections:, admin:, logged_in: true)
    resolved = Studio::SidebarSections.resolve(sections, Struct.new(:a) { def admin? = true }.new(1))
    resolved = resolved.reject { |s| s[:admin] } unless admin
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.define_singleton_method(:studio_sidebar_sections) { resolved }
    view.define_singleton_method(:admin?) { admin }
    view.define_singleton_method(:logged_in?) { logged_in }
    view.define_singleton_method(:logout_path) { "/logout" }
    view
  end
end
