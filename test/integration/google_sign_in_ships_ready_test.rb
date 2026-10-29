# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "nokogiri"
require "stringio"

# [integration] Google sign-in ships ready with every engine app: a host with no
# omniauth gem of its own, no config/initializers/omniauth.rb and no
# User.from_omniauth (voicebox, 2026-10-29, which had to switch Google off).
#
# The dummy is exactly that host: it registers no provider and its User below
# defines no from_omniauth. With an OAuth client the button is a POST form and
# the ENGINE's strategy answers it; without one the button opens the setup modal
# and "Request Google setup" mails the team once per host per day.
ActionDispatch::IntegrationTest.app = Rails.application

require "active_job"
ActiveJob::Base.queue_adapter = :inline
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
ActionMailer::Base.default_url_options = { host: "example.com" }

# The rate limit lives in Rails.cache. A store of this process's own, so a
# previous run's claim on today (a file store under tmp/) cannot answer for this one.
Rails.cache = ActiveSupport::Cache::MemoryStore.new

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
    t.string   :email
    t.string   :name
    t.string   :slug
    t.string   :session_token
    t.string   :provider
    t.string   :uid
    t.timestamps
  end
  add_index :users, :email, unique: true
  add_index :users, :slug, unique: true

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

# A new app's User, with NO from_omniauth: the engine's default answers.
class User < ApplicationRecord
  include Sluggable

  def display_name
    name.presence || email.to_s.split("@").first
  end

  def admin?
    false
  end

  def name_slug
    (name.presence || email.to_s.split("@").first).to_s.parameterize
  end
end

class GoogleSignInShipsReadyTest < ActionDispatch::IntegrationTest
  GOOGLE_KEYS = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].freeze

  def setup
    @prior_auth = Studio.auth_methods
    @prior_env = GOOGLE_KEYS.to_h { |key| [key, ENV[key]] }
    Studio.auth_methods = %i[magic_link google]
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    Studio::GoogleSignIn.reset!
    User.delete_all
  end

  def teardown
    Studio.auth_methods = @prior_auth
    @prior_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  # --- with an OAuth client -------------------------------------------------

  test "with credentials the login button is a POST form to /auth/google_oauth2" do
    configure_google

    get "/login"
    assert_response :success
    form = page.at_css("form[action='/auth/google_oauth2'][method='post']")
    refute_nil form, "the Google button posts to the strategy"
    assert_includes form.text, "Sign in with Google"
    assert_nil page.at_css("[data-google-sign-in=setup]"), "no setup modal once the app has a client"
  end

  test "with credentials the signup button is a POST form too" do
    configure_google

    get "/signup"
    assert_response :success
    form = page.at_css("form[action='/auth/google_oauth2'][method='post']")
    refute_nil form
    assert_includes form.text, "Sign up with Google"
  end

  test "the engine registers the strategy itself: the POST goes to Google with the app's client" do
    configure_google(client_id: "engine-lab-client")

    assert_equal :engine, Studio::GoogleSignIn.registration
    post "/auth/google_oauth2"

    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal "accounts.google.com", location.host
    query = Rack::Utils.parse_query(location.query)
    assert_equal "engine-lab-client", query["client_id"]
    assert_equal "email profile", query["scope"]
    assert_equal "select_account", query["prompt"]
    assert_equal "http://www.example.com/auth/google_oauth2/callback", query["redirect_uri"]
  end

  test "the request phase is POST-only" do
    configure_google

    assert_equal [:post], OmniAuth.config.allowed_request_methods
    assert_raises(ActionController::RoutingError) { get "/auth/google_oauth2" }
  end

  test "a Google callback signs a brand-new person in with no User.from_omniauth in the app" do
    refute User.respond_to?(:from_omniauth), "the host under test defines none"
    configure_google
    mock_google(email: "New.Person@Example.com", uid: "g-new", name: "New Person")

    assert_difference -> { User.count }, 1 do
      post "/auth/google_oauth2"
      follow_redirect!
    end

    assert_redirected_to "/"
    user = User.find_by!(uid: "g-new")
    assert_equal "new.person@example.com", user.email
    assert_equal "google_oauth2", user.provider
    assert_equal user.id, session[Studio.session_key]
  end

  # --- without one ------------------------------------------------------------

  test "without credentials the login button opens the setup modal instead of posting" do
    get "/login"
    assert_response :success

    assert_nil page.at_css("form[action='/auth/google_oauth2']"), "no POST to a strategy with no client"
    opener = page.at_css("[data-google-sign-in=setup] button[type=button]")
    refute_nil opener, "the Google button is still there"
    assert_includes opener.text, "Sign in with Google"
    assert_includes opener["@click"], "googleSetupModals.open('google-setup')"

    modal = Nokogiri::HTML5.fragment(page.at_css("[data-google-sign-in=setup] template template").inner_html)
    assert_includes modal.text, "Google sign-in is still being set up"
    request_form = modal.at_css("form[action='/_studio/google_setup_request'][method='post']")
    refute_nil request_form, "Request Google setup posts to the engine endpoint"
    assert_includes request_form.text, "Request Google setup"
    assert_includes modal.text, "Use email instead"
  end

  test "without credentials the signup button opens the same modal" do
    get "/signup"
    assert_response :success

    assert_nil page.at_css("form[action='/auth/google_oauth2']")
    opener = page.at_css("[data-google-sign-in=setup] button[type=button]")
    refute_nil opener
    assert_includes opener.text, "Sign up with Google"
  end

  test "without credentials the engine strategy stays out of the way" do
    assert_equal :none, Studio::GoogleSignIn.registration
    assert_raises(ActionController::RoutingError) { post "/auth/google_oauth2" }
  end

  test "Request Google setup mails the team once, with the redirect URI, and logs every request" do
    log = StringIO.new
    prior_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    https!

    begin
      post "/_studio/google_setup_request"
      assert_redirected_to "/login"
      assert_equal 1, ActionMailer::Base.deliveries.size

      mail = ActionMailer::Base.deliveries.last
      assert_equal ["team@mcritchie.studio"], mail.to
      assert_includes mail.subject, Studio.app_name
      assert_includes mail.subject, "www.example.com"
      body = mail.text_part ? mail.text_part.body.to_s : mail.body.to_s
      assert_includes body, "https://www.example.com/auth/google_oauth2/callback"
      assert_includes body, "GOOGLE_CLIENT_ID"
      assert_includes flash[:notice], "asked the team"

      # The second request the same day is answered, and mails nobody.
      post "/_studio/google_setup_request"
      assert_redirected_to "/login"
      assert_equal 1, ActionMailer::Base.deliveries.size, "rate-limited: once per host per day"
      assert_includes flash[:notice], "already has a request"
    ensure
      Rails.logger = prior_logger
    end

    lines = log.string.lines.grep(/\[google-setup\] request/)
    assert_equal 2, lines.size, "every request is logged, the repeat included"
    assert_includes lines.first, "notified=true"
    assert_includes lines.last, "notified=false"
    assert_includes lines.first, "redirect_uri=https://www.example.com/auth/google_oauth2/callback"
  end

  test "the setup request answers JSON for a fetch" do
    post "/_studio/google_setup_request", headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal true, response.parsed_body["notified"]
  end

  private

  def page
    Nokogiri::HTML5(response.body)
  end

  def configure_google(client_id: "lab-client-id")
    ENV["GOOGLE_CLIENT_ID"] = client_id
    ENV["GOOGLE_CLIENT_SECRET"] = "lab-client-secret"
  end

  def mock_google(email:, uid:, name:)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: uid, info: { email: email, name: name }
    )
  end
end
