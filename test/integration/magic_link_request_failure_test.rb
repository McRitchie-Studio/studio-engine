# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "json"

# [integration] POST /magic_link answers a failed mint or mail with one friendly,
# uniform reply, through the real router -> MagicLinksController.
#
# THE DEFECT. A raise from the Studio::Link mint or from Studio::Email.deliver
# fell to the engine's catch-all: logged, then "Something went wrong" on the
# home page for HTML and a bare 500 for JSON. It now matches the signup path:
# logged once through rescue_and_log, then the login page with one alert (HTML)
# or a 503 with a fixed body (JSON). The reply is the same for a known and an
# unknown address, because this action never looks an account up.
#
# This lives in its OWN FILE: it arms raises on the mint and the mailer, and
# Minitest runs a file's classes in one process.
ActionDispatch::IntegrationTest.app = Rails.application

require "active_job"
ActiveJob::Base.queue_adapter = :inline
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
ActionMailer::Base.default_url_options = { host: "example.com" }
Rails.application.routes.default_url_options[:host] = "example.com"

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :studio_links, force: true do |t|
    t.string   :token, null: false
    t.string   :kind, null: false
    t.string   :linkable_type
    t.bigint   :linkable_id
    t.json     :metadata
    t.datetime :expires_at
    t.datetime :consumed_at
    t.timestamps
  end
  add_index :studio_links, :token, unique: true

  create_table :users, force: true do |t|
    t.string   :email, null: false
    t.string   :name
    t.string   :session_token
    t.datetime :email_verified_at
    t.string   :provider
    t.string   :uid
    t.timestamps
  end
  add_index :users, :email, unique: true

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

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def display_name
    name.presence || email.split("@").first
  end
end

class MagicLinkRequestFailureTest < ActionDispatch::IntegrationTest
  DELIVERY_FAILURE = "lab: the mail transport refused the message"
  JSON_HEADERS = { "Accept" => "application/json" }.freeze

  def setup
    Studio::Link.delete_all
    User.delete_all
    ErrorLog.delete_all
    ActionMailer::Base.deliveries.clear
  end

  # --- HTML -----------------------------------------------------------------

  test "an HTML mail failure is logged once and goes back to the login page with one alert" do
    with_failing_delivery { post "/magic_link", params: { email: "new@example.com" } }

    assert_redirected_to "/login"
    assert_equal Studio::MagicLinkIssuing::DELIVERY_FAILED, flash[:alert]
    assert_nil flash[:notice], "a failed send never claims the link is in the inbox"
    assert_equal [DELIVERY_FAILURE], ErrorLog.pluck(:message), "logged once, naming the original failure"
  end

  test "an HTML mint failure is logged once and goes back to the login page with one alert" do
    with_failing_mint { post "/magic_link", params: { email: "new@example.com" } }

    assert_redirected_to "/login"
    assert_equal Studio::MagicLinkIssuing::DELIVERY_FAILED, flash[:alert]
    assert_equal ["lab: studio_links is gone"], ErrorLog.pluck(:message)
    assert_empty ActionMailer::Base.deliveries
  end

  test "an HTML failure answers the same for a known and an unknown email" do
    User.create!(email: "known@example.com")

    known = with_failing_delivery { html_request("known@example.com") }
    unknown = with_failing_delivery { html_request("unknown@example.com") }

    assert_equal unknown, known, "the failure reply must not reveal whether the email has an account"
  end

  # --- JSON -----------------------------------------------------------------

  test "a JSON mail failure is logged once and answers 503 with a fixed body" do
    with_failing_delivery { post "/magic_link", params: { email: "new@example.com" }, headers: JSON_HEADERS }

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal({ "success" => false, "error" => "delivery_failed", "message" => Studio::MagicLinkIssuing::DELIVERY_FAILED }, body)
    refute_includes response.body, DELIVERY_FAILURE, "the reply never leaks the internal error"
    assert_equal [DELIVERY_FAILURE], ErrorLog.pluck(:message)
  end

  test "a JSON mint failure answers the same 503" do
    with_failing_mint { post "/magic_link", params: { email: "new@example.com" }, headers: JSON_HEADERS }

    assert_response :service_unavailable
    assert_equal "delivery_failed", JSON.parse(response.body)["error"]
    assert_equal ["lab: studio_links is gone"], ErrorLog.pluck(:message)
  end

  test "a JSON failure answers the same for a known and an unknown email" do
    User.create!(email: "known@example.com")

    known = with_failing_delivery { json_request("known@example.com") }
    unknown = with_failing_delivery { json_request("unknown@example.com") }

    assert_equal unknown, known
  end

  # --- the happy path stays as it was ----------------------------------------

  test "a request that sends still says check your inbox and logs nothing" do
    post "/magic_link", params: { email: "new@example.com" }

    assert_redirected_to "/login"
    assert_match(/check your inbox/i, flash[:notice])
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal 0, ErrorLog.count

    post "/magic_link", params: { email: "new@example.com" }, headers: JSON_HEADERS
    assert_response :ok
    assert_equal({ "success" => true }, JSON.parse(response.body))
  end

  private

  def html_request(email)
    post "/magic_link", params: { email: email }
    [response.status, response.location, flash[:alert], flash[:notice]]
  end

  def json_request(email)
    post "/magic_link", params: { email: email }, headers: JSON_HEADERS
    [response.status, response.body]
  end

  def with_failing_delivery
    message = DELIVERY_FAILURE
    Studio::Email.singleton_class.alias_method(:__lab_deliver, :deliver)
    Studio::Email.define_singleton_method(:deliver) { |*, **| raise IOError, message }
    yield
  ensure
    Studio::Email.singleton_class.alias_method(:deliver, :__lab_deliver)
    Studio::Email.singleton_class.remove_method(:__lab_deliver)
  end

  def with_failing_mint
    Studio::Link.singleton_class.alias_method(:__lab_create_magic_link, :create_magic_link)
    Studio::Link.define_singleton_method(:create_magic_link) { |**| raise ActiveRecord::StatementInvalid, "lab: studio_links is gone" }
    yield
  ensure
    Studio::Link.singleton_class.alias_method(:create_magic_link, :__lab_create_magic_link)
    Studio::Link.singleton_class.remove_method(:__lab_create_magic_link)
  end
end
