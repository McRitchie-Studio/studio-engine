# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../../lib/studio/health_report"

# [unit] The pure rules behind GET /_studio/health_report: which token counts
# (Studio.health_report_token, else ENV["STUDIO_HEALTH_TOKEN"]), when an
# Authorization header is accepted, which window `?ending=` picks, and the JSON
# contract the hub builds against, counts only. The request half (404/401/400/
# 200 through the router) is test/integration/health_report_endpoint_test.rb.
class StudioHealthReportEndpointTest < Minitest::Test
  HR = Studio::HealthReport
  TOKEN = "s3cret-token-value"

  def setup
    @saved = %i[health_report_token health_report_zone health_report_hour].to_h { |k| [k, read(k)] }
    @saved_env = ENV.fetch("STUDIO_HEALTH_TOKEN", nil)
    ENV.delete("STUDIO_HEALTH_TOKEN")
    Studio.health_report_token = nil
  end

  def teardown
    @saved.each { |k, v| Studio.public_send(:"#{k}=", v) }
    @saved_env ? ENV["STUDIO_HEALTH_TOKEN"] = @saved_env : ENV.delete("STUDIO_HEALTH_TOKEN")
  end

  # The configured value, not the env fallback, so teardown restores exactly.
  def read(key)
    key == :health_report_token ? Studio.class_variable_get(:@@health_report_token) : Studio.public_send(key)
  end

  # --- the token -------------------------------------------------------------

  def test_token_is_nil_when_nothing_is_configured
    assert_nil Studio.health_report_token
  end

  def test_token_falls_back_to_the_env_var_read_per_call
    ENV["STUDIO_HEALTH_TOKEN"] = "from-env"
    assert_equal "from-env", Studio.health_report_token

    ENV["STUDIO_HEALTH_TOKEN"] = "rotated"
    assert_equal "rotated", Studio.health_report_token, "a rotated env value must apply without a reboot of the config"
  end

  def test_configured_token_wins_over_the_env_var
    ENV["STUDIO_HEALTH_TOKEN"] = "from-env"
    Studio.health_report_token = "from-config"
    assert_equal "from-config", Studio.health_report_token
  end

  def test_blank_token_is_no_token
    Studio.health_report_token = "  "
    ENV["STUDIO_HEALTH_TOKEN"] = ""
    assert_nil Studio.health_report_token
  end

  # --- authorized? -----------------------------------------------------------

  def test_right_bearer_token_is_authorized
    assert HR.authorized?("Bearer #{TOKEN}", token: TOKEN)
    assert HR.authorized?("bearer #{TOKEN}", token: TOKEN), "the scheme is case-insensitive (RFC 7235)"
  end

  def test_wrong_missing_or_malformed_headers_are_refused
    refute HR.authorized?("Bearer wrong", token: TOKEN)
    refute HR.authorized?("Bearer #{TOKEN}x", token: TOKEN)
    refute HR.authorized?("Bearer #{TOKEN[0..-2]}", token: TOKEN)
    refute HR.authorized?(nil, token: TOKEN)
    refute HR.authorized?("", token: TOKEN)
    refute HR.authorized?(TOKEN, token: TOKEN), "the bare token without the Bearer scheme"
    refute HR.authorized?("Basic #{TOKEN}", token: TOKEN)
    refute HR.authorized?("Bearer ", token: TOKEN)
    refute HR.authorized?("Bearer #{TOKEN} extra", token: TOKEN)
  end

  def test_nothing_is_authorized_when_no_token_is_configured
    refute HR.authorized?("Bearer ", token: nil)
    refute HR.authorized?("Bearer #{TOKEN}", token: nil)
    refute HR.authorized?("Bearer #{TOKEN}", token: "")
  end

  def test_authorized_reads_the_configured_token_by_default
    Studio.health_report_token = TOKEN
    assert HR.authorized?("Bearer #{TOKEN}")
    refute HR.authorized?("Bearer nope")
  end

  # --- window_for ------------------------------------------------------------

  def test_no_ending_is_the_jobs_window_now
    now = Time.utc(2026, 10, 13, 13, 0, 5)
    assert_equal HR.window(now), HR.window_for(nil, now: now)
  end

  def test_ending_is_the_day_that_ends_there
    w = HR.window_for("2026-10-13T07:00:00-06:00")
    assert_equal Time.utc(2026, 10, 12, 13), w.begin
    assert_equal Time.utc(2026, 10, 13, 13), w.end
    assert w.exclude_end?
    assert_equal "America/Denver", w.end.time_zone.name
  end

  def test_ending_that_is_not_iso8601_raises
    ["yesterday", "2026-10-13 07:00", "2026-13-40T00:00:00Z", ""].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { HR.window_for(bad) }
    end
  end

  # --- payload: the contract -------------------------------------------------

  def report(signups: HR::Section.new(title: "Signups", count: 3, items: ["Ann <ann@example.com>"]),
             contacts: nil, errors: HR::Section.new(title: "Errors", count: 0, items: []), groups: [], kinds: 0)
    HR::Report.new(app_name: "Dummy", window: HR.window_for("2026-10-13T13:00:00Z"),
                   signups: signups, errors: errors, contacts: contacts, error_groups: groups, error_kinds: kinds)
  end

  def test_payload_has_exactly_the_contract_keys
    body = JSON.parse(JSON.generate(HR.payload(report)))

    assert_equal %w[schema app engine_version window quiet sections error_kinds error_groups], body.keys
    assert_equal 1, body["schema"]
    assert_equal "Dummy", body["app"]
    assert_equal Studio::VERSION, body["engine_version"]
    assert_equal %w[begin end label], body["window"].keys
    assert_equal "2026-10-12T07:00:00-06:00", body["window"]["begin"]
    assert_equal "2026-10-13T07:00:00-06:00", body["window"]["end"]
    assert_equal "Oct 12, 7:00 AM to Oct 13, 7:00 AM MDT", body["window"]["label"]
    assert_equal false, body["quiet"]
    assert_equal [{ "key" => "signups", "title" => "Signups", "count" => 3, "failure" => nil },
                  { "key" => "errors", "title" => "Errors", "count" => 0, "failure" => nil }], body["sections"]
    assert_equal 0, body["error_kinds"]
    assert_equal [], body["error_groups"]
  end

  def test_payload_carries_no_items_names_or_emails
    contacts = HR::Section.new(title: "Contact messages", count: 1, items: ["Bea <bea@lead.example>"])
    json = JSON.generate(HR.payload(report(contacts: contacts)))

    refute_includes json, "items"
    refute_includes json, "ann@example.com"
    refute_includes json, "Ann"
    refute_includes json, "bea@lead.example"
    assert_includes json, %("key":"contacts")
  end

  def test_sections_follow_the_report_and_carry_failures
    failed = HR::Section.new(title: "Signups", count: 0, items: [], failure: "ActiveRecord::StatementInvalid")
    body = HR.payload(report(signups: failed, contacts: HR::Section.new(title: "Contact messages", count: 2, items: [])))

    assert_equal %w[signups errors contacts], body[:sections].map { |s| s[:key] }
    assert_equal "ActiveRecord::StatementInvalid", body[:sections].first[:failure]
    assert_equal false, body[:quiet], "a failed section is never quiet"

    body = HR.payload(report(signups: nil))
    assert_equal %w[errors], body[:sections].map { |s| s[:key] }, "an absent section is absent, not zero"
  end

  def test_quiet_day
    body = HR.payload(report(signups: HR::Section.new(title: "Signups", count: 0, items: [])))
    assert_equal true, body[:quiet]
  end

  def test_error_messages_lose_email_addresses
    group = HR::ErrorGroup.new(error_class: "ActiveRecord::RecordNotFound", count: 1,
                               message: "no account for Ann.Lee+x@mail.example.co (retry ann@b.io)")
    body = HR.payload(report(groups: [group], kinds: 1))

    assert_equal "no account for [email] (retry [email])", body[:error_groups].sole[:message]
  end

  def test_error_groups_serialize_with_iso_times
    first = Time.utc(2026, 10, 12, 20)
    group = HR::ErrorGroup.new(error_class: "KeyError", message: "key not found: :x", count: 4,
                               first_seen: first, last_seen: first + 3600)
    body = JSON.parse(JSON.generate(HR.payload(report(groups: [group], kinds: 1,
                                                       errors: HR::Section.new(title: "Errors", count: 4, items: [])))))

    assert_equal 1, body["error_kinds"]
    assert_equal [{ "error_class" => "KeyError", "message" => "key not found: :x", "count" => 4,
                    "first_seen" => "2026-10-12T20:00:00Z", "last_seen" => "2026-10-12T21:00:00Z" }],
                 body["error_groups"]
  end
end
