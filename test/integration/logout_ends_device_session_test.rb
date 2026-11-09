# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

require_relative "../../db/migrate/20261103120000_create_studio_user_sessions"
require_relative "../../db/migrate/20261108120000_add_device_revocation_to_studio_user_sessions"

# [integration] A logout ends that device's session on the server
# (docs/DEVICE_SESSIONS.md), through the real stack: router, the host's
# controller with Studio::ErrorHandling, and the encrypted cookie store.
#
# The bug: the cookie store keeps the whole session in the browser, so a logout
# deleted only the browser's copy, and a copy of the pre-logout cookie still
# signed in (measured in Turf, task turf-e2e-retry-only-causes). Each test here
# captures the cookie, logs out, sends the captured cookie back, and expects a
# visitor.
ActionDispatch::IntegrationTest.app = Rails.application

ActiveRecord::Schema.verbose = false
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string   :email, null: false
    t.string   :name
    t.string   :session_token
    t.string   :provider
    t.string   :uid
    t.timestamps
  end

  create_table :error_logs, force: true do |t|
    t.string :slug
    t.text   :message
    t.text   :inspect
    t.text   :backtrace
    t.string :target_type
    t.bigint :target_id
    t.string :target_name
    t.string :parent_type
    t.bigint :parent_id
    t.string :parent_name
    t.timestamps
  end
end
ActiveRecord::Base.connection.drop_table(:studio_user_sessions, if_exists: true)
CreateStudioUserSessions.migrate(:up)
AddDeviceRevocationToStudioUserSessions.migrate(:up)
Studio::UserSession.reset_column_information

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def display_name = name.presence || email.split("@").first
  def admin? = false
end

# A host's pages: sign in, the two logouts hosts use (the engine's
# clear_app_session, and Turf's reset_session), a page that says who is signed
# in.
class DeviceSessionHostController < ApplicationController
  skip_before_action :require_authentication

  def sign_in
    set_app_session(User.find(params[:user_id]))
    render plain: "signed in"
  end

  def reset_out
    reset_session
    render plain: "reset"
  end

  def whoami
    render plain: current_user ? "user:#{current_user.id}" : "visitor"
  end
end

Rails.application.routes.append do
  post "device_session/sign_in", to: "device_session_host#sign_in"
  post "device_session/reset_out", to: "device_session_host#reset_out"
  get "device_session/whoami", to: "device_session_host#whoami"
end
Rails.application.reload_routes!

class LogoutEndsDeviceSessionTest < ActionDispatch::IntegrationTest
  COOKIE = Rails.application.config.session_options[:key]

  setup do
    Studio::UserSession.record_in_test = true
    Studio::UserSession.delete_all
    ErrorLog.delete_all
    User.delete_all
    @user = User.create!(email: "player@example.org", name: "Player")
  end

  teardown { Studio::UserSession.record_in_test = false }

  def sign_in_on(session)
    session.post "/device_session/sign_in", params: { user_id: @user.id }
    session.get "/device_session/whoami"
    assert_equal "user:#{@user.id}", session.response.body
    session.cookies[COOKIE]
  end

  def replay(cookie)
    other = open_session
    other.cookies[COOKIE] = cookie
    other.get "/device_session/whoami"
    other
  end

  test "the engine's logout: a replayed pre-logout cookie does not sign in" do
    captured = sign_in_on(self)

    get "/logout"
    assert_redirected_to "/login"

    assert_equal "visitor", replay(captured).response.body
  end

  test "the control: before the logout the same replay signs in" do
    captured = sign_in_on(self)

    assert_equal "user:#{@user.id}", replay(captured).response.body
  end

  test "a host logout by reset_session (Turf's) ends the device session too" do
    captured = sign_in_on(self)

    post "/device_session/reset_out"
    assert_equal "visitor", replay(captured).response.body
  end

  test "the user's other devices stay signed in" do
    phone = open_session
    laptop = open_session
    phone_cookie = sign_in_on(phone)
    sign_in_on(laptop)

    phone.get "/logout"

    laptop.get "/device_session/whoami"
    assert_equal "user:#{@user.id}", laptop.response.body
    assert_equal "visitor", replay(phone_cookie).response.body
  end

  test "a late response that sets the old cookie back does not restore the session" do
    sign_in_on(self)
    stale = cookies[COOKIE]
    get "/logout"

    # The race Turf measured: a request in flight at the logout answers with the
    # live cookie, and the browser stores it after the logout's reset.
    cookies[COOKIE] = stale
    get "/device_session/whoami"
    assert_equal "visitor", response.body
  end

  test "a cookie from before this change still signs in, and gets a sid" do
    # A pre-deploy cookie: signed in while the app had no sid columns.
    set_revocation_columns(false)
    pre = open_session
    pre.post "/device_session/sign_in", params: { user_id: @user.id }
    pre.get "/device_session/whoami"
    set_revocation_columns(true)
    assert_empty Studio::UserSession.where.not(sid: nil)

    pre.get "/device_session/whoami"
    assert_equal "user:#{@user.id}", pre.response.body, "the deploy signs nobody out"
    assert_equal 1, Studio::UserSession.where.not(sid: nil).count, "its first request gave it a sid"

    captured = pre.cookies[COOKIE]
    pre.get "/logout"
    assert_equal "visitor", replay(captured).response.body, "and from then on its logout ends it"
  ensure
    set_revocation_columns(true)
  end

  test "a signed-in request reads one session row and no more" do
    sign_in_on(self)
    reads = []
    counter = lambda do |*, payload|
      reads << payload[:sql] if payload[:sql].include?("studio_user_sessions") && payload[:sql].start_with?("SELECT")
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/device_session/whoami" }

    assert_equal 1, reads.size, reads.join("\n")
  end

  test "a failed revoke is logged and the logout still goes on" do
    sign_in_on(self)
    Studio::UserSession.singleton_class.alias_method(:revoke_before_fault!, :revoke!)
    Studio::UserSession.define_singleton_method(:revoke!) { |*| raise ActiveRecord::StatementInvalid, "db down" }

    get "/logout"
    assert_redirected_to "/login"
    assert_equal 1, ErrorLog.count
    get "/device_session/whoami"
    assert_equal "visitor", response.body
  ensure
    Studio::UserSession.singleton_class.alias_method(:revoke!, :revoke_before_fault!)
    Studio::UserSession.singleton_class.remove_method(:revoke_before_fault!)
  end

  test "a failed check signs nobody out and writes one ErrorLog row per window, not one per request" do
    sign_in_on(self)
    Studio::UserSession.check_failure_logged_at = nil
    Studio::UserSession.define_singleton_method(:where) { |*| raise ActiveRecord::StatementInvalid, "db down" }

    3.times do
      get "/device_session/whoami"
      assert_equal "user:#{@user.id}", response.body
    end
    assert_equal 1, ErrorLog.count
    assert_match(/db down/, ErrorLog.last.message)
  ensure
    Studio::UserSession.singleton_class.remove_method(:where)
    Studio::UserSession.check_failure_logged_at = nil
  end

  # A speculative fetch never signs anyone out (docs/DEVICE_SESSIONS.md, "Prefetch").
  # Turbo 8 prefetches a link the pointer rests on for 100ms, with X-Sec-Purpose:
  # prefetch; the browser's own prefetch sends Sec-Purpose. A prefetch of /logout
  # ran the sign-out and its Set-Cookie signed the browser out while the page still
  # drew the user (hub task build-funnel-held-message-cause).
  {
    "X-Sec-Purpose" => "prefetch",
    "Sec-Purpose" => "prefetch;prerender",
    "Purpose" => "prefetch"
  }.each do |header, value|
    test "a GET /logout prefetch (#{header}: #{value}) answers 204 and signs nobody out" do
      captured = sign_in_on(self)

      get "/logout", headers: { header => value }

      assert_response :no_content
      assert_nil response.headers["Set-Cookie"], "a prefetch writes no cookie"
      assert_equal "no-store", response.headers["Cache-Control"]
      get "/device_session/whoami"
      assert_equal "user:#{@user.id}", response.body, "this browser is still signed in"
      assert_nil Studio::UserSession.where.not(sid: nil).pick(:revoked_at), "the device session is not revoked"
      assert_equal "user:#{@user.id}", replay(captured).response.body
    end
  end

  test "a prefetch of another page is answered as before" do
    sign_in_on(self)

    get "/device_session/whoami", headers: { "X-Sec-Purpose" => "prefetch" }

    assert_response :ok
    assert_equal "user:#{@user.id}", response.body
  end

  test "DELETE /logout signs out and ends the device session, as GET does" do
    captured = sign_in_on(self)

    delete "/logout"
    assert_redirected_to "/login"

    get "/device_session/whoami"
    assert_equal "visitor", response.body
    assert_equal "visitor", replay(captured).response.body
  end

  test "a sign-in on a logged-out device's copied cookie starts a new sid, and the copy stays ended" do
    captured = sign_in_on(self)
    old_sid = Studio::UserSession.where.not(sid: nil).pick(:sid)
    get "/logout"

    again = replay(captured)
    again.post "/device_session/sign_in", params: { user_id: @user.id }
    again.get "/device_session/whoami"
    assert_equal "user:#{@user.id}", again.response.body
    assert_equal 2, Studio::UserSession.distinct.count(:sid)
    refute_nil Studio::UserSession.where(sid: old_sid).pick(:revoked_at)
    assert_equal "visitor", replay(captured).response.body
  end

  private

  def set_revocation_columns(on)
    return if Studio::UserSession.revocable? == on

    AddDeviceRevocationToStudioUserSessions.migrate(on ? :up : :down)
    Studio::UserSession.reset_column_information
    ActiveRecord::Base.connection.schema_cache.clear!
  end
end
