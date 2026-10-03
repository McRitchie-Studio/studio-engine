# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "nokogiri"

# [integration] /signup renders from the app's configured auth_methods, as /login
# already does, driven through the real router -> RegistrationsController -> view.
#
# THE DEFECT. registrations/new rendered Password, Confirm Password and "Sign up
# with Google" whatever Studio.auth_methods said, while RegistrationsController#create,
# in passwordless mode, reads the email alone. So every passwordless consumer without
# its own override (Moms App, Cyvasse, Acquisition Studio) showed a signup page that
# asked for a password it threw away, and a name it threw away too. McRitchie
# Industries wrote a host override to hide it.
#
# The matrix below is the set of auth_methods the consumers actually configure
# (config/initializers/studio.rb in each), plus the engine's password opt-in.
# bin/release-check runs each test FILE in its own process, so the top-level
# constants here collide with nothing.
ActionDispatch::IntegrationTest.app = Rails.application

# Studio::Email.deliver calls deliver_later; resolve it inside the request so the
# passwordless POST's mail lands in ActionMailer::Base.deliveries.
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

# A passwordless host's User, as every consumer in the matrix ships it. The
# password cases give it `authenticate` for the length of one test only.
class User < ApplicationRecord
  def display_name
    name.presence || email.split("@").first
  end
end

class SignupHonoursAuthMethodsTest < ActionDispatch::IntegrationTest
  NAME_AND_EMAIL = %i[name email].freeze

  # [auth_methods, registration_params, the consumer that configures it]
  PASSWORDLESS = [
    [%i[magic_link google], NAME_AND_EMAIL, "hub, Moms App, Acquisition Studio, Cyvasse with Google"],
    [%i[magic_link], NAME_AND_EMAIL, "McRitchie Industries, Cyvasse without Google"],
    [%i[magic_link google wallet], %i[email reference], "Turf Monster"]
  ].freeze

  def setup
    @prior_auth = Studio.auth_methods
    @prior_params = Studio.registration_params
    Studio::Link.delete_all
    User.delete_all
    ActionMailer::Base.deliveries.clear
  end

  def teardown
    Studio.auth_methods = @prior_auth
    Studio.registration_params = @prior_params
    User.send(:remove_method, :authenticate) if User.method_defined?(:authenticate, false)
  end

  # --- the passwordless consumers ------------------------------------------

  PASSWORDLESS.each do |methods, params, consumer|
    test "#{methods.inspect} (#{consumer}) renders no password and no name field" do
      page = signup_page(methods, params)

      assert_empty page.css("input[type=password]"), "a passwordless app asks for no password"
      assert_nil page.at_css("#user_name"), "passwordless signup discards the name, so it asks for none"
      assert page.at_css("form[action='/signup'] input[type=email]#user_email"), "the email field posts to /signup"
      assert_equal "Send sign-in link", submit_text(page)
    end

    test "#{methods.inspect} (#{consumer}) renders the Google button only with :google" do
      page = signup_page(methods, params)

      if methods.include?(:google)
        assert google_button(page), "the Google button renders when :google is enabled"
        assert_includes page.text, "Sign up with Google"
        assert_includes page.text, "or", "the divider separates the email form from Google"
      else
        assert_nil google_button(page), "the Google button is gated on :google"
        assert_nil divider(page), "no divider without a second method under it"
      end
    end
  end

  test "a passwordless signup POST mails a magic link and creates no account yet" do
    Studio.auth_methods = %i[magic_link]
    Studio.registration_params = NAME_AND_EMAIL

    post "/signup", params: { user: { name: "Karen", email: "New@Example.com" } }

    assert_redirected_to "/login"
    assert_equal 1, ActionMailer::Base.deliveries.size, "one sign-in link is mailed"
    assert_equal ["new@example.com"], ActionMailer::Base.deliveries.last.to
    link = Studio::Link.find_by(kind: "magic_link")
    refute_nil link, "the mailed link is a live Studio::Link"
    assert_includes ActionMailer::Base.deliveries.last.body.encoded, link.token
    assert_equal 0, User.count, "the account is created when the link is used, not by the POST"
  end

  test "the passwordless signup button speaks Studio.sign_in_label, as /login does" do
    prior = Studio.sign_in_label
    Studio.sign_in_label = "Log on"

    assert_equal "Send log-on link", submit_text(signup_page(%i[magic_link], NAME_AND_EMAIL))
  ensure
    Studio.sign_in_label = prior
  end

  # --- Google only, and the password opt-in -------------------------------

  test "a Google-only app renders the Google button with no email form and no divider" do
    page = signup_page(%i[google], NAME_AND_EMAIL)

    assert_nil page.at_css("form[action='/signup']"), "no email form without :magic_link or :password"
    assert google_button(page)
    assert_nil divider(page)
  end

  test "a password app renders name, password and confirmation, as it always did" do
    User.define_method(:authenticate) { |_password| self }
    page = signup_page(%i[password google], NAME_AND_EMAIL)

    assert page.at_css("#user_name"), "the password path stores the name, so it asks for it"
    assert page.at_css("input[type=password]#user_password")
    assert page.at_css("input[type=password]#user_password_confirmation")
    assert_equal "Sign Up", submit_text(page)
    assert google_button(page)
    assert divider(page)
  end

  test "a password app without :name in registration_params renders no name field" do
    User.define_method(:authenticate) { |_password| self }
    page = signup_page(%i[password], %i[email password password_confirmation])

    assert_nil page.at_css("#user_name")
    assert page.at_css("input[type=password]#user_password")
    assert_nil google_button(page)
    assert_nil divider(page)
  end

  test "password in auth_methods but a User without authenticate renders no password field" do
    page = signup_page(%i[password magic_link], NAME_AND_EMAIL)

    assert_empty page.css("input[type=password]"), "password_login_available? gates it, as on /login"
    assert_equal "Send sign-in link", submit_text(page)

    # The action takes the same branch the view rendered: it mails a link rather
    # than trying to save a user from a form that carried no password.
    post "/signup", params: { user: { email: "reader@example.com" } }
    assert_redirected_to "/login"
    assert_equal ["reader@example.com"], ActionMailer::Base.deliveries.last&.to
    assert_equal 0, User.count
  end

  private

  def signup_page(methods, params)
    Studio.auth_methods = methods
    Studio.registration_params = params
    get "/signup"
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def submit_text(page)
    page.at_css("form[action='/signup'] button[type=submit]")&.text&.strip
  end

  def google_button(page)
    page.at_css("form[action='/auth/google_oauth2']")
  end

  def divider(page)
    page.css("span").find { |span| span.text.strip == "or" }
  end
end
