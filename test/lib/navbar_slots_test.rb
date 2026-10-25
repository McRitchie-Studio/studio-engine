# frozen_string_literal: true

require "test_helper"

# [unit] Config rules for Studio.navbar_items and Studio.navbar_avatar_badge
# (lib/studio/navbar_slots.rb): a partial spec is a String path or a Hash of
# partial: and locals:, both normalize to one shape, a callable resolves per
# view, a bad shape raises InvalidConfig, and a raising callable falls back to
# nothing and is reported once.
class NavbarSlotsTest < Minitest::Test
  S = Studio::NavbarSlots

  def setup
    S.reset_reported!
  end

  # ---- partial specs ----

  def test_a_string_spec_normalizes_to_a_partial_with_no_locals
    assert_equal({ partial: "components/geo_badge", locals: {} }, S.spec("components/geo_badge", "x"))
  end

  def test_a_symbol_spec_normalizes_the_same
    assert_equal({ partial: "geo_badge", locals: {} }, S.spec(:geo_badge, "x"))
  end

  def test_a_hash_spec_carries_its_locals_with_symbol_keys
    spec = S.spec({ "partial" => "shared/wallet_signal", "locals" => { "size" => :sm } }, "x")

    assert_equal({ partial: "shared/wallet_signal", locals: { size: :sm } }, spec)
  end

  def test_a_hash_spec_without_locals_gets_an_empty_hash
    assert_equal({ partial: "a/b", locals: {} }, S.spec({ partial: "a/b" }, "x"))
  end

  def test_bad_specs_are_refused_by_name
    error = assert_raises(S::InvalidConfig) { S.spec({ locals: {} }, "Studio.navbar_items[1]") }
    assert_match(/Studio\.navbar_items\[1\] needs a non-blank :partial/, error.message)

    assert_raises(S::InvalidConfig) { S.spec(" ", "x") }
    assert_raises(S::InvalidConfig) { S.spec(42, "x") }
    assert_raises(S::InvalidConfig) { S.spec({ partial: "a/b", locals: "size" }, "x") }
    error = assert_raises(S::InvalidConfig) { S.spec({ partial: "a/b", local: {} }, "x") }
    assert_match(/unknown key :local/, error.message)
  end

  # ---- Studio.navbar_items ----

  def test_items_default_and_nil_resolve_to_nothing
    assert_equal [], S.resolve_items([], Object.new)
    assert_equal [], S.resolve_items(nil, Object.new)
    assert_nil S.validate_items!([])
  end

  def test_a_static_item_list_resolves_in_order
    items = ["components/geo_badge", { partial: "shared/wallet_signal", locals: { tone: "muted" } }]

    assert_equal [{ partial: "components/geo_badge", locals: {} },
                  { partial: "shared/wallet_signal", locals: { tone: "muted" } }],
                 S.resolve_items(items, Object.new)
  end

  def test_an_items_callable_receives_the_view
    view = Struct.new(:geo?).new(true)
    items = ->(v) { v.geo? ? ["components/geo_badge"] : [] }

    assert_nil S.validate_items!(items), "a callable is checked when it resolves, not at assignment"
    assert_equal [{ partial: "components/geo_badge", locals: {} }], S.resolve_items(items, view)
  end

  def test_an_items_callable_answering_nil_renders_nothing
    assert_equal [], S.resolve_items(->(_view) {}, Object.new)
  end

  def test_bad_static_item_lists_are_refused_by_index
    assert_raises(S::InvalidConfig) { S.validate_items!("components/geo_badge") }
    error = assert_raises(S::InvalidConfig) { S.validate_items!(["a/b", { locals: {} }]) }
    assert_match(/Studio\.navbar_items\[1\]/, error.message)
  end

  def test_a_bad_items_callable_answer_is_refused_when_it_resolves
    assert_raises(S::InvalidConfig) { S.resolve_items(->(_view) { "a/b" }, Object.new) }
  end

  def test_a_raising_items_callable_falls_back_to_nothing_and_reports_once
    reports = capture_reports do
      2.times { assert_equal [], S.resolve_items(->(_view) { raise KeyError, "no geo" }, Object.new) }
    end

    assert_equal 1, reports.size, "reported once, not once per render"
    assert_instance_of KeyError, reports.first
  end

  # ---- Studio.navbar_avatar_badge ----

  def test_badge_default_nil_resolves_to_nil
    assert_nil S.resolve_badge(nil, Object.new)
    assert_nil S.validate_badge!(nil)
  end

  def test_a_static_badge_resolves_to_one_spec
    assert_equal({ partial: "components/entry_token_badge", locals: {} },
                 S.resolve_badge("components/entry_token_badge", Object.new))
  end

  def test_a_badge_callable_receives_the_view_and_may_answer_nil
    view = Struct.new(:tokens).new(0)
    badge = ->(v) { "components/entry_token_badge" if v.tokens.positive? }

    assert_nil S.validate_badge!(badge)
    assert_nil S.resolve_badge(badge, view)
  end

  def test_a_bad_static_badge_is_refused
    assert_raises(S::InvalidConfig) { S.validate_badge!(["components/entry_token_badge"]) }
    error = assert_raises(S::InvalidConfig) { S.validate_badge!({ path: "x" }) }
    assert_match(/Studio\.navbar_avatar_badge/, error.message)
  end

  def test_a_raising_badge_callable_falls_back_to_nil_and_reports_once
    reports = capture_reports do
      2.times { assert_nil S.resolve_badge(->(_view) { raise ArgumentError, "boom" }, Object.new) }
    end

    assert_equal 1, reports.size, "reported once, not once per render"
    assert_instance_of ArgumentError, reports.first
  end

  def test_each_setting_reports_its_own_first_failure
    reports = capture_reports do
      S.resolve_items(->(_view) { raise "x" }, Object.new)
      S.resolve_badge(->(_view) { raise "x" }, Object.new)
    end

    assert_equal 2, reports.size
  end

  # ---- Studio.navbar_header_bars ----

  def test_header_bars_resolve_like_items_and_name_their_own_setting
    assert_equal [], S.resolve_header_bars([], Object.new)
    assert_equal [{ partial: "shared/impersonation_banner", locals: {} }],
                 S.resolve_header_bars(->(_view) { ["shared/impersonation_banner"] }, Object.new)

    error = assert_raises(S::InvalidConfig) { S.validate_header_bars!("shared/impersonation_banner") }
    assert_match(/\AStudio\.navbar_header_bars must be an Array/, error.message)
    error = assert_raises(S::InvalidConfig) { S.validate_header_bars!([{ locals: {} }]) }
    assert_match(/Studio\.navbar_header_bars\[0\] needs a non-blank :partial/, error.message)
    assert_nil S.validate_header_bars!(->(_view) { 42 })
  end

  def test_a_raising_header_bars_callable_renders_none_and_reports_once
    reports = capture_reports do
      2.times { assert_equal [], S.resolve_header_bars(->(_view) { raise KeyError, "x" }, Object.new) }
    end

    assert_equal 1, reports.size
  end

  # ---- Studio.navbar_menu_trigger ----

  def test_menu_trigger_resolves_like_the_badge_and_names_its_own_setting
    assert_nil S.resolve_menu_trigger(nil, Object.new)
    assert_equal({ partial: "components/gear_sidebar_trigger", locals: {} },
                 S.resolve_menu_trigger("components/gear_sidebar_trigger", Object.new))
    assert_nil S.resolve_menu_trigger(->(_view) { raise "x" }, Object.new)

    error = assert_raises(S::InvalidConfig) { S.validate_menu_trigger!(["components/gear_sidebar_trigger"]) }
    assert_match(/\AStudio\.navbar_menu_trigger must be a partial path/, error.message)
    assert_nil S.validate_menu_trigger!(nil)
  end

  def test_every_setting_reports_its_own_first_failure
    reports = capture_reports do
      S.resolve_items(->(_view) { raise "x" }, Object.new)
      S.resolve_badge(->(_view) { raise "x" }, Object.new)
      S.resolve_header_bars(->(_view) { raise "x" }, Object.new)
      S.resolve_menu_trigger(->(_view) { raise "x" }, Object.new)
    end

    assert_equal 4, reports.size
  end

  private

  # Stands in for ErrorLog so the report-once rule is observable.
  class CaptureLog
    class << self
      attr_accessor :captured

      def capture!(error) = (self.captured ||= []) << error
    end
  end

  def capture_reports
    CaptureLog.captured = []
    stubbed = !defined?(::ErrorLog)
    Object.const_set(:ErrorLog, CaptureLog) if stubbed
    yield
    CaptureLog.captured
  ensure
    Object.send(:remove_const, :ErrorLog) if stubbed
  end
end
