# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# The engine's default sessions/new must render from the app's configured auth_methods, NOT a
# hardcoded password field. A passwordless app (auth_methods = [magic_link, google], a User with
# no `authenticate`) previously 500'd on its only sign-in path (user.authenticate) because the
# view always rendered a password field. Assert the PROPERTY — a password field iff passwords are
# actually available — across permutations, not a spelling.
class EngineLoginPasswordlessTest < ActiveSupport::TestCase
  # Google configured, so the button is the POST form these tests look for; the
  # unconfigured button (the setup modal) is google_sign_in_ships_ready_test.rb's.
  GOOGLE_ENV = { "GOOGLE_CLIENT_ID" => "lab-client-id", "GOOGLE_CLIENT_SECRET" => "lab-client-secret" }.freeze

  def setup
    @orig_auth = Studio.auth_methods
    @orig_google_env = GOOGLE_ENV.keys.to_h { |key| [key, ENV[key]] }
    ENV.update(GOOGLE_ENV)
    remove_user_const
  end

  def teardown
    Studio.auth_methods = @orig_auth
    @orig_google_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    remove_user_const
  end

  # --- the PROPERTY (Studio.password_login_available?) -------------------------

  def test_no_password_login_when_passwords_are_not_enabled
    define_user(authenticate: true) # even a User WITH authenticate
    Studio.auth_methods = %i[magic_link google] # ...but :password not enabled
    refute Studio.password_login_available?
  end

  def test_no_password_login_when_the_user_lacks_authenticate
    define_user(authenticate: false) # has_secure_password ABSENT — the passwordless-app bug
    Studio.auth_methods = %i[password]
    refute Studio.password_login_available?
    refute Studio.user_supports_password?
  end

  def test_no_password_login_and_no_raise_when_no_user_model_is_defined
    remove_user_const
    Studio.auth_methods = %i[password]
    refute Studio.password_login_available?
  end

  def test_password_login_when_enabled_and_the_user_authenticates
    define_user(authenticate: true)
    Studio.auth_methods = %i[password google]
    assert Studio.password_login_available?
  end

  # --- the VIEW renders the right form from auth_methods ----------------------

  def test_passwordless_login_renders_a_magic_link_form_and_NO_password_field
    remove_user_const # a passwordless app: no User#authenticate
    Studio.auth_methods = %i[magic_link google]

    html = render_login

    refute_includes html, 'type="password"', "a passwordless app must render NO password field"
    assert_includes html, "/magic_link", "the sign-in form requests a magic link"
    assert_includes html, "Send sign-in link"
    assert_includes html, "google_oauth2", "the Google button renders when :google is enabled"
  end

  def test_password_login_renders_the_password_field_when_available
    define_user(authenticate: true)
    Studio.auth_methods = %i[password]

    html = render_login

    assert_includes html, 'type="password"', "a password field renders when password login is available"
    assert_includes html, "Log In"
    refute_includes html, "Send sign-in link", "no magic-link form when password login is the primary method"
  end

  def test_google_is_gated_on_the_google_auth_method
    remove_user_const
    Studio.auth_methods = %i[magic_link] # no :google
    refute_includes render_login, "google_oauth2", "the Google button is gated on :google"
  end

  private

  # Render sessions/new.html.erb through ActionView with the app's real Studio + stubbed
  # request-scoped helpers (the same pattern as user_nav_test), so the branch on auth_methods is
  # exercised without booting the full HTTP stack.
  def render_login
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.define_singleton_method(:sso_user_available?) { false }
    view.define_singleton_method(:login_path) { "/login" }
    view.define_singleton_method(:magic_link_request_path) { "/magic_link" }
    view.define_singleton_method(:signup_path) { "/signup" }
    view.define_singleton_method(:params) { {} }
    view.define_singleton_method(:protect_against_forgery?) { false }
    view.render(template: "sessions/new")
  end

  def define_user(authenticate:)
    remove_user_const
    klass = Class.new
    klass.define_method(:authenticate) { |_password| true } if authenticate
    Object.const_set(:User, klass)
  end

  def remove_user_const
    Object.send(:remove_const, :User) if Object.const_defined?(:User, false)
  end
end
