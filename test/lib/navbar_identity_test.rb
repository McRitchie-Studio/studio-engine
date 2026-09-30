# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/string/output_safety"

# Resolution rules for Studio.navbar_user_name and Studio.sign_in_label
# (lib/studio/navbar_identity.rb).
class NavbarIdentityTest < Minitest::Test
  class Player
    attr_accessor :player_name

    def initialize(player_name = "Guest_4821") = @player_name = player_name
    def display_name = "Pat Studio"
    def explode = raise(ArgumentError, "no name for you")
  end

  # Stands in for ErrorLog so the report-once rule is observable.
  class CaptureLog
    class << self
      attr_accessor :captured

      def capture!(error) = (self.captured ||= []) << error
    end
  end

  def setup
    Studio::NavbarIdentity.reset_reported!
    CaptureLog.captured = []
    Object.const_set(:ErrorLog, CaptureLog) unless defined?(::ErrorLog)
    @stubbed_error_log = ::ErrorLog.equal?(CaptureLog)
  end

  def teardown
    Object.send(:remove_const, :ErrorLog) if @stubbed_error_log
    Studio::NavbarIdentity.reset_reported!
  end

  def resolve_name(config, user = Player.new, view = :the_view)
    Studio::NavbarIdentity.user_name(user, view, config: config)
  end

  def test_defaults_keep_the_pre_feature_behaviour
    assert_nil Studio.navbar_user_name
    assert_equal "Log in", Studio.sign_in_label
    assert_equal "Pat Studio", Studio.navbar_user_name_for(Player.new)
  end

  def test_nil_config_is_display_name
    assert_equal "Pat Studio", resolve_name(nil)
  end

  def test_a_symbol_calls_that_method_on_the_user
    assert_equal "Guest_4821", resolve_name(:player_name)
  end

  def test_a_string_method_name_works_too
    assert_equal "Guest_4821", resolve_name("player_name")
  end

  def test_a_two_argument_callable_receives_the_user_and_the_view
    seen = nil
    config = lambda do |user, view|
      seen = view
      "#{user.player_name}!"
    end

    assert_equal "Guest_4821!", resolve_name(config)
    assert_equal :the_view, seen
  end

  def test_a_one_argument_callable_receives_the_user_only
    assert_equal "Guest_4821", resolve_name(->(user) { user.player_name })
  end

  def test_a_blank_answer_falls_back_to_display_name_without_a_report
    assert_equal "Pat Studio", resolve_name(:player_name, Player.new(nil))
    assert_equal "Pat Studio", resolve_name(:player_name, Player.new("   "))
    assert_equal "Pat Studio", resolve_name(->(_user, _view) { "" })
    assert_empty CaptureLog.captured, "a blank name is data, not a fault"
  end

  def test_a_raising_method_falls_back_and_reports_once
    3.times { assert_equal "Pat Studio", resolve_name(:explode) }

    assert_equal 1, CaptureLog.captured.size, "reported once, not once per render"
    assert_instance_of ArgumentError, CaptureLog.captured.first
  end

  def test_a_missing_method_falls_back_rather_than_raising
    assert_equal "Pat Studio", resolve_name(:no_such_method)
    assert_instance_of NoMethodError, CaptureLog.captured.first
  end

  def test_a_raising_callable_falls_back
    assert_equal "Pat Studio", resolve_name(->(_user, _view) { raise "boom" })
    assert_equal 1, CaptureLog.captured.size
  end

  def test_reset_reported_lets_a_new_failure_report_again
    resolve_name(:explode)
    Studio::NavbarIdentity.reset_reported!
    resolve_name(:explode)

    assert_equal 2, CaptureLog.captured.size
  end

  def test_a_failing_error_log_still_falls_back
    CaptureLog.define_singleton_method(:capture!) { |_error| raise "db down" }

    assert_equal "Pat Studio", resolve_name(:explode)
  ensure
    CaptureLog.singleton_class.send(:remove_method, :capture!)
    CaptureLog.define_singleton_method(:capture!) { |error| (self.captured ||= []) << error }
  end

  def test_display_name_raising_under_the_default_is_not_swallowed
    user = Object.new
    def user.display_name = raise(KeyError, "real bug")

    assert_raises(KeyError) { resolve_name(nil, user) }
  end

  def test_the_name_is_plain_text_so_erb_escapes_it
    result = resolve_name(->(_user, _view) { "<b>x</b>".html_safe })

    assert_equal "<b>x</b>", result
    refute result.html_safe?, "an html_safe answer must lose the flag"
    assert_instance_of String, result
  end

  def test_validate_name_accepts_nil_symbol_string_and_callables
    [nil, :player_name, "player_name", ->(u, _v) { u }, ->(u) { u }].each do |config|
      assert_nil Studio::NavbarIdentity.validate_name!(config)
    end
  end

  def test_validate_name_refuses_anything_else
    [42, "", :"", ["player_name"]].each do |config|
      assert_raises(Studio::NavbarIdentity::InvalidConfig) { Studio::NavbarIdentity.validate_name!(config) }
    end
  end

  def test_validate_label_accepts_text_and_refuses_blank_or_non_text
    assert_nil Studio::NavbarIdentity.validate_label!("Sign in")
    [nil, "", "  ", :sign_in].each do |label|
      assert_raises(Studio::NavbarIdentity::InvalidConfig) { Studio::NavbarIdentity.validate_label!(label) }
    end
  end
end
