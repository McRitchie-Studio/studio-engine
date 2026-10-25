# frozen_string_literal: true

require "test_helper"

# [unit] Config rules for Studio.navbar_account_sidebar
# (lib/studio/navbar_account_sidebar.rb): nil keeps the default account
# control, a Hash names the host store flag and the panels it opens, every name
# must be a plain identifier (no host JavaScript), a callable resolves per view,
# and a raising callable falls back and is reported once.
class NavbarAccountSidebarTest < Minitest::Test
  A = Studio::NavbarAccountSidebar

  def setup
    A.reset_reported!
  end

  def test_nil_resolves_to_nil_and_validates
    assert_nil A.resolve(nil, Object.new)
    assert_nil A.validate!(nil)
  end

  def test_a_hash_normalizes_with_the_sidebars_store_by_default
    assert_equal({ store: "sidebars", flag: "gearOpen", controls: "gear-sidebar gear-sidebar-mobile" },
                 A.normalize({ "flag" => :gearOpen, "controls" => "gear-sidebar  gear-sidebar-mobile" }))
  end

  def test_controls_may_be_an_array_and_the_store_named
    assert_equal({ store: "menus", flag: "open", controls: "menu" },
                 A.normalize({ store: "menus", flag: "open", controls: [:menu] }))
  end

  def test_names_must_be_plain_identifiers
    ["gearOpen = true; x", "a.b", "", nil, 4].each do |flag|
      error = assert_raises(A::InvalidConfig, flag.inspect) { A.normalize({ flag: flag, controls: "p" }) }
      assert_match(/:flag must be a plain JavaScript name/, error.message)
    end
    assert_raises(A::InvalidConfig) { A.normalize({ flag: "f", store: "s'x", controls: "p" }) }
  end

  def test_controls_must_name_panel_ids
    [nil, "", [], ['p" onclick="x'], [1]].each do |controls|
      error = assert_raises(A::InvalidConfig, controls.inspect) { A.normalize({ flag: "f", controls: controls }) }
      assert_match(/:controls must name the panel ids/, error.message)
    end
  end

  # studio/link_sidebar claims a click on any trigger whose aria-controls names
  # the engine's link sidebar, so a host sidebar control naming it would open
  # the engine's panel instead of the host's.
  def test_controls_naming_the_engine_link_sidebar_are_refused
    [["studio-link-sidebar"], "studio-link-sidebar-mobile", "gear-sidebar studio-link-sidebar",
     [:"studio-link-sidebar-mobile", "gear"]].each do |controls|
      error = assert_raises(A::InvalidConfig, controls.inspect) { A.normalize({ flag: "f", controls: controls }) }
      assert_match(/studio-link-sidebar/, error.message)
      assert_match(/engine's link sidebar/, error.message)
    end
    assert_equal "studio-link-sidebarx my-studio-link-sidebar",
                 A.normalize({ flag: "f", controls: "studio-link-sidebarx my-studio-link-sidebar" })[:controls],
                 "the control: only the engine's two ids are refused, not names that contain them"
  end

  def test_the_refused_ids_are_the_link_sidebar_panels_the_javascript_claims
    js = File.read(File.expand_path("../../app/javascript/studio/link_sidebar.js", __dir__))
    panels = js[/export const LINK_SIDEBAR_PANELS = "([^"]+)"/, 1]
    refute_nil panels, "link_sidebar.js no longer names its panels"
    assert_equal panels.split(",").map { |sel| sel.strip.delete_prefix("#") }, A::ENGINE_LINK_SIDEBAR_IDS
  end

    def test_bad_shapes_are_refused
    assert_raises(A::InvalidConfig) { A.validate!("gearOpen") }
    error = assert_raises(A::InvalidConfig) { A.validate!({ flag: "f", controls: "p", toggle: "x" }) }
    assert_match(/unknown key :toggle/, error.message)
    assert_nil A.validate!(->(_view) { 42 }), "a callable is checked when it resolves"
  end

  def test_a_callable_reads_the_view_and_nil_keeps_the_default
    view = Struct.new(:signed_in).new(true)

    assert_equal "f", A.resolve(->(v) { v.signed_in ? { flag: "f", controls: "p" } : nil }, view)[:flag]
    assert_nil A.resolve(->(_v) {}, view)
    assert_raises(A::InvalidConfig) { A.resolve(->(_v) { { flag: "x y", controls: "p" } }, view) }
  end

  def test_a_raising_callable_falls_back_and_reports_once
    reports = []
    log = Class.new { define_singleton_method(:capture!) { |error| reports << error } }
    stubbed = !defined?(::ErrorLog)
    Object.const_set(:ErrorLog, log) if stubbed
    2.times { assert_nil A.resolve(->(_v) { raise KeyError, "x" }, Object.new) }

    assert_equal 1, reports.size if stubbed
  ensure
    Object.send(:remove_const, :ErrorLog) if stubbed
  end
end
