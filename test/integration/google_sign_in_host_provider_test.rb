# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"

# [integration] A host that wires Google itself keeps its own registration, and
# the engine registers no second strategy.
#
# This is the shape of hub, turf-monster, moms-app, cyvasse and
# acquisition-studio: config/initializers/omniauth.rb runs
# `config.middleware.use OmniAuth::Builder { provider :google_oauth2, ... }`.
# The dummy does the same here, from an initializer at the point a host's
# config/initializers run. bin/release-check runs each test file in its own
# process, so this host shape touches no other file's app.
require_relative "../dummy/config/application"

# An application initializer at the host's config/initializers point, so the
# host's Builder lands on the stack AFTER the engine's middleware, as it does in
# a real app (engine initializers run first). Registering it before initialize!
# instead would put the host's strategy outermost and prove nothing.
Dummy::Application.initializer "host.omniauth", after: :load_config_initializers do |app|
  app.config.middleware.use OmniAuth::Builder do
    provider :google_oauth2, "host-own-client", "host-own-secret", scope: "email,profile", prompt: "select_account"
  end
end

require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "nokogiri"

ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :session_token
    t.string :provider
    t.string :uid
    t.timestamps
  end
end

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  before_action :verify_session_token
end

# The host's own from_omniauth, which must win over the engine's default.
class User < ApplicationRecord
  HOST_CALLS = []

  def self.from_omniauth(auth, email_verified: false)
    HOST_CALLS << auth["uid"]
    find_or_create_by!(provider: auth["provider"], uid: auth["uid"]) { |user| user.email = "host-made@example.com" }
  end

  def display_name
    email
  end

  def admin?
    false
  end
end

class GoogleSignInHostProviderTest < ActionDispatch::IntegrationTest
  GOOGLE_KEYS = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].freeze

  def setup
    @prior_auth = Studio.auth_methods
    @prior_env = GOOGLE_KEYS.to_h { |key| [key, ENV[key]] }
    Studio.auth_methods = %i[magic_link google]
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    Studio::GoogleSignIn.reset!
    User::HOST_CALLS.clear
    User.delete_all
  end

  def teardown
    Studio.auth_methods = @prior_auth
    @prior_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  test "the engine sees the host's registration and stands aside" do
    get "/login" # builds the stack, as the first request always does

    assert Studio::GoogleSignIn.host_registered?
    assert_equal :host, Studio::GoogleSignIn.registration
  end

  test "with the engine's credentials set too, the host's strategy is the one that answers" do
    ENV["GOOGLE_CLIENT_ID"] = "engine-would-use-this"
    ENV["GOOGLE_CLIENT_SECRET"] = "engine-secret"

    post "/auth/google_oauth2"

    assert_response :redirect
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal "host-own-client", query["client_id"], "the host's provider answered, not a second engine one"
  end

  test "exactly one google_oauth2 registration is on the built stack, and it is the host's" do
    get "/login"

    stack = Rails.application.config.middleware.middlewares
    builders = stack.select { |entry| entry.klass == OmniAuth::Builder }
    assert_equal 1, builders.size
    assert Studio::GoogleSignIn.builder_registers_google?(builders.first.block)
    engine = stack.index { |entry| entry.klass == Studio::GoogleSignIn::Middleware }
    host = stack.index { |entry| entry.klass == OmniAuth::Builder }
    refute_nil engine, "the engine's middleware is present, as a pass-through"
    assert_operator engine, :<, host, "the engine's middleware sits outside the host's, as in a real app"
    refute Studio::GoogleSignIn.engine_registers?(env: { "GOOGLE_CLIENT_ID" => "x", "GOOGLE_CLIENT_SECRET" => "y" })
  end

  test "a host that wires its own provider keeps its POST button with no credentials in the env" do
    GOOGLE_KEYS.each { |key| ENV.delete(key) }

    get "/login"

    assert_response :success
    page = Nokogiri::HTML5(response.body)
    refute_nil page.at_css("form[action='/auth/google_oauth2'][method='post']"),
               "the host owns its readiness; its button posts exactly as it did before the engine shipped one"
    assert_nil page.at_css("[data-google-sign-in=setup]")
  end

  test "the host's own from_omniauth wins over the engine default" do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "g-host", info: { email: "someone@example.com", name: "Someone" }
    )

    post "/auth/google_oauth2"
    follow_redirect!

    assert_equal ["g-host"], User::HOST_CALLS
    assert_equal "host-made@example.com", User.find_by!(uid: "g-host").email
  end
end
