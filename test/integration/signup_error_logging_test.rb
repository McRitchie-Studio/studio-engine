# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "nokogiri"

# [integration] POST /signup never fails silently, through the real router ->
# RegistrationsController -> view.
#
# THE DEFECT. #create ended in a method-level `rescue StandardError` that logged
# nothing and rendered registrations/new. The passwordless branch never sets
# @user, so a raise there (the Studio::Link mint, or Studio::Email.deliver) landed
# in that rescue and rendered a view that calls `@user.errors`: a NoMethodError on
# nil, an exception in place of the "check your inbox" page, and no ErrorLog row
# naming the delivery failure that started it. The password branch logged through
# rescue_and_log, but a missing `user` param raised before @user existed and took
# the same nil path.
#
# This lives in its OWN FILE: it arms raises on the mint, the mailer and
# User#save, and Minitest runs a file's classes in one process.
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

  before_action :verify_session_token
end

# A host User. `explode_on_save` arms an unexpected raise for one test; the
# password cases give it `authenticate` for the length of one test only.
class User < ApplicationRecord
  cattr_accessor :explode_on_save, default: false

  validates :email, presence: true
  before_save { raise ActiveRecord::StatementInvalid, "lab: the users table is gone" if self.class.explode_on_save }

  def display_name
    name.presence || email.split("@").first
  end
end

class SignupErrorLoggingTest < ActionDispatch::IntegrationTest
  DELIVERY_FAILURE = "lab: the mail transport refused the message"

  def setup
    @prior_auth = Studio.auth_methods
    @prior_params = Studio.registration_params
    Studio.auth_methods = %i[magic_link]
    Studio.registration_params = %i[name email]
    Studio::Link.delete_all
    User.delete_all
    ErrorLog.delete_all
    ActionMailer::Base.deliveries.clear
  end

  def teardown
    Studio.auth_methods = @prior_auth
    Studio.registration_params = @prior_params
    User.explode_on_save = false
    User.send(:remove_method, :authenticate) if User.method_defined?(:authenticate, false)
  end

  # --- passwordless ---------------------------------------------------------

  test "a passwordless delivery failure is logged and answered with a friendly page, not an exception" do
    with_failing_delivery do
      post "/signup", params: { user: { email: "new@example.com" } }
    end

    assert_redirected_to "/signup"
    assert_match(/could not send/i, flash[:alert])
    assert_nil flash[:notice], "a failed send never claims the link is in the inbox"
    assert_equal 1, ErrorLog.count, "the delivery failure leaves an ErrorLog row"
    assert_equal DELIVERY_FAILURE, ErrorLog.last.message, "the row names the ORIGINAL exception"
    assert_equal 0, User.count, "a failed signup creates no account"
  end

  test "a passwordless delivery failure answers the same for a known and an unknown email" do
    User.create!(email: "known@example.com")

    known = with_failing_delivery { post_signup("known@example.com") }
    unknown = with_failing_delivery { post_signup("unknown@example.com") }

    assert_equal unknown, known, "the failure response must not reveal whether the email has an account"
    assert_equal 2, ErrorLog.count
  end

  test "a passwordless link-mint failure is logged and answered with the same friendly page" do
    Studio::Link.singleton_class.alias_method(:__lab_create_magic_link, :create_magic_link)
    Studio::Link.define_singleton_method(:create_magic_link) { |**| raise ActiveRecord::StatementInvalid, "lab: studio_links is gone" }

    post "/signup", params: { user: { email: "new@example.com" } }

    assert_redirected_to "/signup"
    assert_match(/could not send/i, flash[:alert])
    assert_equal ["lab: studio_links is gone"], ErrorLog.pluck(:message)
    assert_empty ActionMailer::Base.deliveries
  ensure
    Studio::Link.singleton_class.alias_method(:create_magic_link, :__lab_create_magic_link)
    Studio::Link.singleton_class.remove_method(:__lab_create_magic_link)
  end

  test "a passwordless signup that sends still says check your inbox and logs nothing" do
    post "/signup", params: { user: { email: "new@example.com" } }

    assert_redirected_to "/login"
    assert_match(/check your inbox/i, flash[:notice])
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal 0, ErrorLog.count
    assert_equal 0, User.count, "proof of email ownership: the account waits for the link to be used"
  end

  # --- password -------------------------------------------------------------

  test "a password signup with invalid input re-renders the form with its errors and logs nothing" do
    enable_passwords

    post "/signup", params: { user: { name: "Karen", email: "" } }

    assert_response :unprocessable_entity
    page = Nokogiri::HTML(response.body)
    assert_includes page.text, "Email can't be blank", "the validation error renders on the form"
    assert page.at_css("form[action='/signup'] input#user_password"), "the password form re-renders"
    assert_equal 0, ErrorLog.count, "a validation error is the visitor's input, not an incident"
    assert_equal 0, User.count
  end

  test "a password signup with no user params re-renders the form instead of raising" do
    enable_passwords

    post "/signup", params: {}

    assert_response :unprocessable_entity
    assert_includes Nokogiri::HTML(response.body).text, "Email can't be blank"
    assert_equal 0, ErrorLog.count
  end

  test "a password signup that raises unexpectedly logs the original error and lets it surface" do
    enable_passwords
    User.explode_on_save = true

    error = assert_raises(ActiveRecord::StatementInvalid) do
      post "/signup", params: { user: { name: "Karen", email: "karen@example.com" } }
    end

    assert_equal "lab: the users table is gone", error.message
    assert_equal ["lab: the users table is gone"], ErrorLog.pluck(:message),
      "logged once, by rescue_and_log; the catch-all does not write a second row"
  end

  test "a valid password signup signs the visitor in" do
    enable_passwords

    post "/signup", params: { user: { name: "Karen", email: "karen@example.com" } }

    assert_redirected_to "/"
    assert_equal 1, User.count
    assert_equal 0, ErrorLog.count
  end

  private

  def enable_passwords
    Studio.auth_methods = %i[password magic_link]
    User.define_method(:authenticate) { |_password| self }
  end

  def post_signup(email)
    post "/signup", params: { user: { email: email } }
    [response.status, response.location, flash[:alert], flash[:notice]]
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
end
