# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

# [integration] components/_sidebar_panel's two opt-in locals: title_html, the
# header's lead slot (content in the title's place that never names the panel),
# and close_hook, which stamps the close button with its panel's id. Unset, the
# panel renders the bytes it rendered before either existed. Read through the
# HTML5 parser: HTML4 drops the @click attributes this partial carries.
class SidebarPanelLeadAndCloseHookTest < ActiveSupport::TestCase
  BASE = { id: "gear-sidebar", open: "$store.sidebars.gearOpen", close_action: "$store.sidebars.gearOpen = false" }.freeze
  LEAD = %(<span data-status-line>3 entries live</span>)

  test "unset, the panel renders the same bytes as passing the defaults explicitly" do
    plain = render_panel(**BASE, title: "Settings")

    assert_equal plain, render_panel(**BASE, title: "Settings", title_html: nil, close_hook: false)
    refute_includes plain, "data-sidebar-panel-close"
    refute_includes plain, "data-sidebar-panel-lead"
  end

  test "title_html renders in the title's place, before the actions, and names nothing" do
    doc = parse(render_panel(**BASE, title_html: LEAD.html_safe, aria_label: "Settings menu"))
    aside = doc.at_css("aside")
    header = aside.at_css("div.border-b")

    lead = header.element_children.first
    assert lead.key?("data-sidebar-panel-lead"), "the lead leads the header row"
    assert_equal "3 entries live", lead.at_css("[data-status-line]").text
    assert_includes lead["class"].split, "min-w-0", "a long status line truncates in its own box"
    assert_nil header.at_css("h3"), "no title heading when only the lead is passed"
    assert_nil aside["aria-labelledby"], "the lead never names the panel"
    assert_equal "Settings menu", aside["aria-label"]
  end

  test "title_html alone opens the header row" do
    doc = parse(render_panel(id: "p", open: "o", title_html: LEAD.html_safe, aria_label: "P"))

    refute_nil doc.at_css("aside div.border-b [data-status-line]")
  end

  test "title wins over title_html, and keeps naming the panel" do
    doc = parse(render_panel(**BASE, title: "Settings", title_html: LEAD.html_safe))

    assert_equal "Settings", doc.at_css("aside h3").text
    assert_nil doc.at_css("[data-status-line]")
    assert_equal "gear-sidebar-title", doc.at_css("aside")["aria-labelledby"]
  end

  test "an unsafe title_html string is escaped, never markup" do
    doc = parse(render_panel(**BASE, title_html: "<img src=x onerror=alert(1)>", aria_label: "P"))

    assert_nil doc.at_css("aside img")
    assert_equal "<img src=x onerror=alert(1)>", doc.at_css("[data-sidebar-panel-lead]").text
  end

  test "close_hook stamps the close button with its panel's id, beside the link-sidebar hook" do
    button = parse(render_panel(**BASE, title: "Settings", close_hook: true)).at_css("aside button")

    assert_equal "gear-sidebar", button["data-sidebar-panel-close"]
    assert_equal "true", button["data-link-sidebar-close"]
    assert_equal BASE[:close_action], button["@click"]
  end

  test "close_hook without an id adds nothing" do
    with_hook = render_panel(open: "o", close_action: "o = false", aria_label: "P", close_hook: true)

    assert_equal render_panel(open: "o", close_action: "o = false", aria_label: "P"), with_hook
  end

  private

  def parse(html) = Nokogiri::HTML5.fragment(html)

  def render_panel(**locals)
    ActionController::Base.render(partial: "components/sidebar_panel", locals: locals)
  end
end
