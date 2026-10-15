# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "active_support/testing/time_helpers"
require "action_dispatch"
require "action_dispatch/testing/integration"

ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email, null: false
    t.string :name
    t.timestamps
  end

  create_table :error_logs, force: true do |t|
    t.string :slug
    t.text   :message
    t.text   :inspect
    t.text   :backtrace
    t.string :target_type
    t.bigint :target_id
    t.string :parent_type
    t.bigint :parent_id
    t.timestamps
  end
end

# A HOST's ApplicationController as hostile as a real one gets: it demands a
# sign-in by redirecting, and stamps a cookie on every response. The endpoint
# must run neither (it answers a server-to-server fetch with no session), so a
# 200 here with no Set-Cookie proves it does not inherit the host's base.
class ApplicationController < ActionController::Base
  before_action { cookies[:host_touched] = "1" }
  before_action { redirect_to "/login" }
end

class User < ApplicationRecord
  def display_name = name.presence || email
end

# [integration] GET /_studio/health_report through the dummy host's real
# router (Studio.routes(self)), controller and database: the 404 while no
# token is configured, 401 to a wrong or missing token, 400 to a bad
# `?ending=`, and the counts-only JSON contract the hub's 07:00 pull reads.
# The pure rules (token fallback, header parsing, the payload shape) are
# test/lib/studio/health_report_endpoint_test.rb.
class HealthReportEndpointTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  TOKEN   = "hub-pull-token-0123456789"
  PATH    = "/_studio/health_report"
  ENDING  = "2026-10-13T07:00:00-06:00"         # the window is Oct 12 07:00 to Oct 13 07:00 Denver
  INSIDE  = Time.utc(2026, 10, 13, 2)            # Oct 12, 8 PM MDT
  OUTSIDE = Time.utc(2026, 10, 12, 12, 59, 59)   # one second before the window opens

  def setup
    @saved_token = Studio.class_variable_get(:@@health_report_token)
    @saved_app = Studio.app_name
    @saved_env = ENV.fetch("STUDIO_HEALTH_TOKEN", nil)
    ENV.delete("STUDIO_HEALTH_TOKEN")
    Studio.health_report_token = nil
    Studio.app_name = "Dummy"
    [User, ErrorLog].each(&:delete_all)
  end

  def teardown
    Studio.health_report_token = @saved_token
    Studio.app_name = @saved_app
    @saved_env ? ENV["STUDIO_HEALTH_TOKEN"] = @saved_env : ENV.delete("STUDIO_HEALTH_TOKEN")
  end

  def pull(token: TOKEN, ending: ENDING, headers: nil)
    params = ending ? { ending: ending } : {}
    headers ||= token ? { "Authorization" => "Bearer #{token}" } : {}
    get PATH, params: params, headers: headers
  end

  def body = JSON.parse(response.body)

  # --- the gate --------------------------------------------------------------

  test "the route is drawn by Studio.routes, as JSON" do
    assert_equal PATH, Rails.application.routes.url_helpers.studio_health_report_path
    route = Rails.application.routes.routes.find { |r| r.name == "studio_health_report" }
    assert_equal "studio/health_reports", route.defaults[:controller]
    assert_equal "show", route.defaults[:action]
  end

  test "the route is drawn in production too" do
    original = Rails.env
    Rails.env = "production"
    set = ActionDispatch::Routing::RouteSet.new
    set.draw { Studio.routes(self) }
    names = set.routes.map(&:name).compact
    assert_includes names, "studio_health_report"
    refute_includes names, "studio_local_review", "sanity: the draw really ran as production"
  ensure
    Rails.env = original
  end

  test "no token configured answers a bare 404, even to a request carrying one" do
    pull
    assert_response :not_found
    assert_empty response.body.to_s.strip
  end

  test "the env var arms it" do
    ENV["STUDIO_HEALTH_TOKEN"] = TOKEN
    pull
    assert_response :ok
  end

  test "a wrong or missing token answers 401 JSON and reveals no report" do
    Studio.health_report_token = TOKEN
    User.create!(email: "ann@example.com", name: "Ann", created_at: INSIDE)

    [{ token: "wrong" }, { token: nil }, { headers: { "Authorization" => TOKEN } }].each do |opts|
      pull(**opts)
      assert_response :unauthorized, opts.inspect
      assert_equal({ "error" => "unauthorized" }, body)
      assert_match(/\ABearer /, response.headers["WWW-Authenticate"].to_s)
      refute_includes response.body, "signups"
    end
  end

  test "a bad ending answers 400" do
    Studio.health_report_token = TOKEN
    pull(ending: "yesterday")
    assert_response :bad_request
    assert_match(/ISO 8601/, body["error"])
  end

  # --- the report --------------------------------------------------------------

  test "the right token gets the counts-only contract for the requested day" do
    Studio.health_report_token = TOKEN
    User.create!(email: "ann@example.com", name: "Ann Lead", created_at: INSIDE)
    User.create!(email: "bob@example.com", name: "Bob Lead", created_at: INSIDE + 60)
    User.create!(email: "old@example.com", name: "Old", created_at: OUTSIDE)
    2.times { |i| ErrorLog.create!(message: "boom", inspect: "#<KeyError: key not found: :x>", created_at: INSIDE + i) }
    ErrorLog.create!(message: "late", inspect: "#<RuntimeError: late>", created_at: OUTSIDE)

    pull
    assert_response :ok
    assert_equal "application/json", response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["Set-Cookie"], "no session, no cookie: the host's before_actions never ran"

    assert_equal %w[schema app engine_version window quiet sections error_kinds error_groups], body.keys
    assert_equal 1, body["schema"]
    assert_equal "Dummy", body["app"]
    assert_equal Studio::VERSION, body["engine_version"]
    assert_equal({ "begin" => "2026-10-12T07:00:00-06:00", "end" => "2026-10-13T07:00:00-06:00",
                   "label" => "Oct 12, 7:00 AM to Oct 13, 7:00 AM MDT" }, body["window"])
    assert_equal false, body["quiet"]
    assert_equal [{ "key" => "signups", "title" => "Signups", "count" => 2, "failure" => nil },
                  { "key" => "errors", "title" => "Errors", "count" => 2, "failure" => nil }], body["sections"]
    assert_equal 1, body["error_kinds"]
    group = body["error_groups"].sole
    assert_equal({ "error_class" => "KeyError", "message" => "key not found: :x", "count" => 2 },
                 group.slice("error_class", "message", "count"))
    assert_equal Time.iso8601(group["first_seen"]), INSIDE
    assert_equal Time.iso8601(group["last_seen"]), INSIDE + 1

    # Counts only: the builder lists these users by name and email for the
    # email; none of it may reach the hub.
    refute_includes response.body, "items"
    %w[ann@example.com bob@example.com Ann Bob].each { |pii| refute_includes response.body, pii }
  end

  test "no ending reports the job's own window, ending at the last 07:00" do
    Studio.health_report_token = TOKEN
    travel_to(Time.utc(2026, 10, 13, 15)) do # 09:00 MDT
      User.create!(email: "ann@example.com", created_at: INSIDE)
      pull(ending: nil)
    end
    assert_response :ok
    assert_equal "2026-10-13T07:00:00-06:00", body["window"]["end"]
    assert_equal 1, body["sections"].find { |s| s["key"] == "signups" }["count"]
  end

  test "a quiet day says so" do
    Studio.health_report_token = TOKEN
    pull
    assert_response :ok
    assert_equal true, body["quiet"]
    assert_equal [], body["error_groups"]
  end
end
