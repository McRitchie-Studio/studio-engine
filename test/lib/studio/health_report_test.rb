# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/studio/health_report"

# [unit] Studio::HealthReport's pure rules: the 07:00-to-07:00 window in the
# app's zone, who it goes to, and how an ErrorLog row names its error. The
# database half (counts, grouping, the email) is test/integration/health_report_test.rb.
class StudioHealthReportTest < Minitest::Test
  def setup
    @saved = %i[health_report_to health_report_zone health_report_hour].to_h { |k| [k, Studio.public_send(k)] }
    @saved_env = ENV.fetch("STUDIO_HEALTH_REPORT_TO", nil)
    ENV.delete("STUDIO_HEALTH_REPORT_TO")
  end

  def teardown
    @saved.each { |k, v| Studio.public_send(:"#{k}=", v) }
    @saved_env ? ENV["STUDIO_HEALTH_REPORT_TO"] = @saved_env : ENV.delete("STUDIO_HEALTH_REPORT_TO")
  end

  def window(now, **opts) = Studio::HealthReport.window(now, **opts)

  # --- the window ----------------------------------------------------------

  def test_defaults_are_seven_am_denver
    assert_equal "America/Denver", Studio.health_report_zone
    assert_equal 7, Studio.health_report_hour
  end

  def test_on_time_run_covers_yesterday_seven_to_today_seven
    w = window(Time.utc(2026, 10, 7, 13, 0, 5)) # 07:00:05 MDT

    assert_equal Time.utc(2026, 10, 6, 13), w.begin
    assert_equal Time.utc(2026, 10, 7, 13), w.end
    assert w.exclude_end?, "07:00 today belongs to tomorrow's report, never to both"
  end

  def test_fall_back_day_is_twenty_five_hours
    # Nov 1 2026 Denver leaves MDT: 07:00 MDT Oct 31 (13:00Z) to 07:00 MST Nov 1 (14:00Z).
    w = window(Time.utc(2026, 11, 1, 14, 0, 5))

    assert_equal Time.utc(2026, 10, 31, 13), w.begin
    assert_equal Time.utc(2026, 11, 1, 14), w.end
    assert_equal 25 * 3600, (w.end - w.begin).to_i
  end

  def test_spring_forward_day_is_twenty_three_hours
    # Mar 8 2026 Denver enters MDT: 07:00 MST Mar 7 (14:00Z) to 07:00 MDT Mar 8 (13:00Z).
    w = window(Time.utc(2026, 3, 8, 13, 1))

    assert_equal Time.utc(2026, 3, 7, 14), w.begin
    assert_equal Time.utc(2026, 3, 8, 13), w.end
    assert_equal 23 * 3600, (w.end - w.begin).to_i
  end

  def test_late_run_reports_the_same_window_as_an_on_time_one
    assert_equal window(Time.utc(2026, 10, 7, 13, 0, 1)), window(Time.utc(2026, 10, 7, 21, 40))
  end

  def test_run_before_the_hour_reports_the_last_complete_day
    w = window(Time.utc(2026, 10, 7, 12, 59)) # 06:59 MDT

    assert_equal Time.utc(2026, 10, 5, 13), w.begin
    assert_equal Time.utc(2026, 10, 6, 13), w.end
  end

  def test_zone_and_hour_are_configurable
    Studio.health_report_zone = "America/New_York"
    Studio.health_report_hour = 6
    w = window(Time.utc(2026, 10, 7, 12))

    assert_equal Time.utc(2026, 10, 6, 10), w.begin
    assert_equal Time.utc(2026, 10, 7, 10), w.end
    assert_equal "America/New_York", w.end.time_zone.name
  end

  # --- the recipient -------------------------------------------------------

  def test_no_recipient_configured_means_nobody
    Studio.health_report_to = nil

    assert_equal [], Studio::HealthReport.recipients
  end

  def test_env_names_the_recipient_when_config_does_not
    Studio.health_report_to = nil
    ENV["STUDIO_HEALTH_REPORT_TO"] = " ops@example.test, cto@example.test ,"

    assert_equal %w[ops@example.test cto@example.test], Studio::HealthReport.recipients
  end

  def test_config_wins_over_env_and_takes_a_list_or_a_callable
    ENV["STUDIO_HEALTH_REPORT_TO"] = "env@example.test"

    Studio.health_report_to = ["a@example.test", "", nil]
    assert_equal ["a@example.test"], Studio::HealthReport.recipients

    Studio.health_report_to = -> { "b@example.test" }
    assert_equal ["b@example.test"], Studio::HealthReport.recipients
  end

  def test_blank_config_falls_through_to_env
    Studio.health_report_to = "  "
    ENV["STUDIO_HEALTH_REPORT_TO"] = "env@example.test"

    assert_equal ["env@example.test"], Studio::HealthReport.recipients
  end

  # --- naming an error -----------------------------------------------------

  def test_error_name_reads_class_and_message_from_the_safe_inspect
    assert_equal ["Net::ReadTimeout", "Net::ReadTimeout with #<TCPSocket>"],
      Studio::HealthReport.error_name("#<Net::ReadTimeout: Net::ReadTimeout with #<TCPSocket>>")
  end

  def test_error_name_keeps_a_multiline_message
    assert_equal ["RuntimeError", "line one\nline two"], Studio::HealthReport.error_name("#<RuntimeError: line one\nline two>")
  end

  def test_error_name_falls_back_to_the_raw_text
    assert_equal ["Error", "boom"], Studio::HealthReport.error_name("boom")
    assert_equal ["Error", "(no message)"], Studio::HealthReport.error_name(nil)
  end
end
