# frozen_string_literal: true

# [integration] Studio.navbar_header_bars: partials rendered INSIDE the engine
# navbar's pinned header, above its row, so a control bar (an impersonation
# escape) never scrolls away. Skipped on a preview; unset renders the header's
# 0.113.0 bytes; a raising callable renders nothing.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_render_host"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarHeaderBarsRenderTest < ActiveSupport::TestCase
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))

  setup { @prior = Studio.navbar_header_bars }
  teardown { Studio.navbar_header_bars = @prior }

  test "unset, an empty list, a nil-answering and a raising callable all render the same bytes" do
    Studio.navbar_header_bars = []
    empty = NavbarRenderHost.render_navbar(signed_in: true)
    refute_includes empty, "data-nav-header-bars"

    Studio.navbar_header_bars = ->(_view) {}
    assert_equal empty, NavbarRenderHost.render_navbar(signed_in: true)
    Studio.navbar_header_bars = ->(_view) { raise KeyError, "no session" }
    assert_equal empty, NavbarRenderHost.render_navbar(signed_in: true)
  end

  test "the bars render inside the header, before its row, in order" do
    Studio.navbar_header_bars = ["navbar_slot_fixtures/bar",
                                 { partial: "navbar_slot_fixtures/bar", locals: { name: "frozen" } }]
    header = Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true)).at_css("header")

    seat = header.element_children.reject { |el| el.name == "style" }.first
    assert seat.key?("data-nav-header-bars"), "the seat is the header's first child after its style"
    assert_equal %w[impersonation frozen], seat.css("[data-slot-bar]").map { |el| el["data-slot-bar"] }
    assert_includes seat.next_element["class"].split, "nav-row"
    assert_equal "Return to admin", seat.at_css("form button[type=submit]").text, "a JS-free escape survives"
  end

  test "signed out too, and a callable reads the view" do
    Studio.navbar_header_bars = ->(view) { view.logged_in? ? [] : ["navbar_slot_fixtures/bar"] }

    assert_includes NavbarRenderHost.render_navbar(signed_in: false), "data-slot-bar"
    refute_includes NavbarRenderHost.render_navbar(signed_in: true), "data-slot-bar"
  end

  test "a preview render carries no header bars" do
    Studio.navbar_header_bars = ["navbar_slot_fixtures/bar"]

    refute_includes NavbarRenderHost.render_navbar(signed_in: true, locals: "preview: true"), "data-nav-header-bars"
  end

  test "a bad static list is refused when assigned" do
    error = assert_raises(Studio::NavbarSlots::InvalidConfig) { Studio.navbar_header_bars = "navbar_slot_fixtures/bar" }
    assert_match(/Studio\.navbar_header_bars must be an Array/, error.message)
    error = assert_raises(Studio::NavbarSlots::InvalidConfig) { Studio.navbar_header_bars = [{ path: "x" }] }
    assert_match(/navbar_header_bars\[0\] has unknown key :path/, error.message)
  end

  test "on the scroll timeline engine.css carries the bars down by the band" do
    rule = CSS[/\.nav-shell\[data-nav-timeline\] > \[data-nav-header-bars\] \{[^}]*\}/]

    refute_nil rule
    assert_includes rule, "animation: nav-tl-header-bars linear both"
    assert_includes rule, "animation-range: var(--nav-start, 0px) calc(var(--nav-start, 0px) + var(--nav-band))"
    assert_match(/@keyframes nav-tl-header-bars \{ to \{ transform: translateY\(var\(--nav-band\)\); \} \}/, CSS)
  end
end
