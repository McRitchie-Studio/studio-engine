# frozen_string_literal: true

require "test_helper"

# [unit] ENABLE_GEO_BLOCKING — the switch behind the admin dropdown's Geo row.
#
# WHAT IT DOES NOT DO, first, because it is the important half: it does not gate
# the geo GATE. An app with the variable unset still detects, still blocks, still
# enforces its exclusion list. A default-off variable that switched enforcement
# would silently stop a live legal blocklist on the next deploy — the opposite of
# what a signpost is for. This governs the LINK and its signage.
class StudioGeoBlockingFlagTest < Minitest::Test
  def setup
    @previous_env = ENV["ENABLE_GEO_BLOCKING"]
    @previous_setting = Studio.geo_blocking_enabled
    Studio.geo_blocking_enabled = nil
  end

  def teardown
    ENV["ENABLE_GEO_BLOCKING"] = @previous_env
    ENV.delete("ENABLE_GEO_BLOCKING") if @previous_env.nil?
    Studio.geo_blocking_enabled = @previous_setting
  end

  # The house ENABLE_* spellings, whatever an operator types into a dyno.
  def test_the_truthy_spellings_all_count
    %w[1 true TRUE yes on].each do |value|
      ENV["ENABLE_GEO_BLOCKING"] = value

      assert Studio.geo_blocking_enabled?, "#{value.inspect} must read as on"
    end
  end

  def test_anything_else_is_off_including_unset
    ["0", "false", "no", "off", "", "  ", nil].each do |value|
      value.nil? ? ENV.delete("ENABLE_GEO_BLOCKING") : ENV["ENABLE_GEO_BLOCKING"] = value

      refute Studio.geo_blocking_enabled?, "#{value.inspect} must read as off"
    end
  end

  # An app that would rather decide in code sets the accessor, and the variable is
  # then ignored — including when it says the opposite. Same shape as
  # Studio.local_email_capture.
  def test_an_explicit_setting_wins_over_the_environment
    ENV["ENABLE_GEO_BLOCKING"] = "false"
    Studio.geo_blocking_enabled = true
    assert Studio.geo_blocking_enabled?

    ENV["ENABLE_GEO_BLOCKING"] = "true"
    Studio.geo_blocking_enabled = false
    refute Studio.geo_blocking_enabled?
  end

  # nil is not "false" — it is "ask the environment", which is what makes the
  # variable the switch at all.
  def test_nil_defers_to_the_environment
    Studio.geo_blocking_enabled = nil
    ENV["ENABLE_GEO_BLOCKING"] = "true"

    assert Studio.geo_blocking_enabled?
  end
end
