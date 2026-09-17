# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "json"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# Drive the real dummy app through the full router -> controller stack.
ActionDispatch::IntegrationTest.app = Rails.application

# Studio::ErrorHandling#require_authentication and #verify_session_token answer
# several formats; a respond_to block raises on any unregistered mime. Every real
# host has turbo-rails; the dummy registers the type itself (as geo_gate_test does).
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

# The engine's controllers inherit the HOST's ApplicationController. This one is
# shaped like turf-monster's: it includes Studio::ErrorHandling and wires the
# OPSEC-045 session-token check, which is the host filter that REVOKES a session.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  before_action :verify_session_token

  private

  # The identity hook, overridden the way a host overrides it.
  def studio_session_identities
    { acct: session[:lab_acct] }
  end
end

class User < ApplicationRecord
  def admin? = role == "admin"
end

# [integration] The session-drift primitive's server half, end to end
# (docs/SESSION_DRIFT.md):
#
#   1. every page a Studio::ErrorHandling controller renders carries the stamp
#      (meta name="studio-session") and loads the browser store;
#   2. the stamp's fingerprint follows the session: anonymous, signed in, a
#      different account, a rotated session token, a re-bound identity;
#   3. GET /session/state answers with the SAME stamp a page carries, plus the
#      host payload and a fresh CSRF token, for anonymous and signed-in browsers;
#   4. a host filter that revokes the session answers the endpoint with a 401;
#   5. the route and the stamp's rehydrateUrl exist only when the host opts in.
class SessionDriftTest < ActionDispatch::IntegrationTest
  def self.ensure_schema!
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      # The rescue path writes here; without it a controller failure would be
      # masked by "no such table: error_logs".
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

      create_table :users, force: true do |t|
        t.string :email, null: false
        t.string :name
        t.string :role
        t.string :provider
        t.string :uid
        t.string :session_token
        t.timestamps
      end
    end
  end

  def setup
    self.class.ensure_schema!
    User.delete_all
    @alice = User.create!(email: "alice@example.com", name: "Alice", session_token: "alice-token-1")
    @bob = User.create!(email: "bob@example.com", name: "Bob", session_token: "bob-token-1")
    # Rails 8.1 draws routes lazily; pin the draw before anything else runs.
    Rails.application.routes.url_helpers.login_path
  end

  def teardown
    Studio.draw_session_routes = true
  end

  # ---- helpers ---------------------------------------------------------------

  def page_stamp
    get "/lab/session"
    assert_response :success
    metas = css_select('meta[name="studio-session"]')
    assert_equal 1, metas.size, "exactly one stamp per page"
    JSON.parse(metas.first["content"])
  end

  def sign_in(user, acct: nil)
    post "/lab/session/sign_in", params: { user_id: user.id, acct: acct }.compact
    assert_response :success
  end

  def state_json
    get "/session/state", headers: { "Accept" => "application/json" }
    response.parsed_body
  end

  # ---- 1. the stamp is on the page ---------------------------------------------

  def test_an_anonymous_page_carries_the_stamp_and_the_store
    before = (Time.now.to_r * 1000).to_i
    stamp = page_stamp
    after = (Time.now.to_r * 1000).to_i

    assert_equal 1, stamp["v"]
    assert_equal "anonymous", stamp["state"]
    assert_equal "anonymous", stamp["fingerprint"]
    assert_equal({}, stamp["identities"])
    assert_nil stamp["expiresAt"], "a browser-session cookie has no expiry to announce"
    assert_equal "/session/state", stamp["rehydrateUrl"]
    assert_operator stamp["issuedAt"], :>=, before
    assert_operator stamp["issuedAt"], :<=, after

    scripts = css_select("script[src]").map { |s| s["src"] }
    assert scripts.any? { |src| src.include?("studio/session") }, "the page loads the store, got #{scripts.inspect}"
    script = css_select("script[src]").find { |s| s["src"].include?("studio/session") }
    assert_nil script["defer"], "the store must run before deferred Alpine to hear alpine:init"
  end

  # ---- 2. the fingerprint follows the session -----------------------------------

  def test_a_signed_in_page_carries_a_stable_per_account_fingerprint
    sign_in(@alice)
    first = page_stamp
    second = page_stamp

    assert_equal "authenticated", first["state"]
    assert_match(/\A[0-9a-f]{32}\z/, first["fingerprint"])
    assert_equal first["fingerprint"], second["fingerprint"], "the same session, the same fingerprint"
    refute_includes response.body, "alice-token-1", "the session token never reaches the page"

    post "/lab/session/sign_out"
    assert_equal "anonymous", page_stamp["fingerprint"], "signing out returns to the shared anonymous fingerprint"

    sign_in(@bob)
    refute_equal first["fingerprint"], page_stamp["fingerprint"], "another account, another fingerprint"
  end

  def test_rotating_the_session_token_changes_the_fingerprint
    sign_in(@alice)
    before = page_stamp["fingerprint"]

    @alice.update_column(:session_token, "alice-token-2")

    refute_equal before, page_stamp["fingerprint"], "a log-out-everywhere rotation is visible to the page"
  end

  def test_a_host_bound_identity_is_carried_and_fingerprinted
    sign_in(@alice)
    plain = page_stamp

    sign_in(@alice, acct: "id-1")
    bound = page_stamp

    assert_equal({ "acct" => "id-1" }, bound["identities"])
    refute_equal plain["fingerprint"], bound["fingerprint"], "re-binding the session changes its fingerprint"
  end

  # ---- 3. the rehydrate endpoint -------------------------------------------------

  def test_the_endpoint_answers_an_anonymous_browser
    body = state_json

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_includes response.headers["Cache-Control"].to_s, "no-store"
    assert_equal "anonymous", body.dig("session", "state")
    assert_equal "anonymous", body.dig("session", "fingerprint")
    assert_kind_of Hash, body["context"], "the host payload rides along"
    assert_equal false, body.dig("context", "loggedIn")
    assert_nil body.dig("context", "userId")
    assert body["csrf"].is_a?(String) && !body["csrf"].empty?, "a fresh CSRF token"
  end

  def test_the_endpoint_returns_the_same_stamp_a_page_carries
    sign_in(@alice, acct: "id-7")
    page = page_stamp
    body = state_json

    assert_response :success
    assert_equal page["fingerprint"], body.dig("session", "fingerprint"), "like compared with like"
    assert_equal "authenticated", body.dig("session", "state")
    assert_equal({ "acct" => "id-7" }, body.dig("session", "identities"))
    assert_equal @alice.id, body.dig("context", "userId")
    assert_equal page.keys.sort, body["session"].keys.sort
  end

  def test_a_revoking_host_filter_answers_the_endpoint_with_401
    sign_in(@alice)
    assert_equal "authenticated", state_json.dig("session", "state")

    @alice.update_column(:session_token, "rotated-elsewhere")
    get "/session/state", headers: { "Accept" => "application/json" }

    assert_response :unauthorized, "the store reads this 401 as revoked"
  end

  # ---- 4. opt-in ---------------------------------------------------------------------

  def test_the_route_is_opt_in
    fresh = lambda do |flag|
      Studio.draw_session_routes = flag
      set = ActionDispatch::Routing::RouteSet.new
      set.draw { Studio.routes(self) }
      set
    end

    off = fresh.call(false)
    assert_raises(ActionController::RoutingError) { off.recognize_path("/session/state") }

    on = fresh.call(true)
    assert_equal({ controller: "studio/session_states", action: "show", format: :json },
                 on.recognize_path("/session/state"))
  end

  def test_the_default_is_off
    source = File.read(File.expand_path("../../lib/studio.rb", __dir__))
    assert_match(/mattr_accessor :draw_session_routes, default: false/, source)
  end

  def test_without_the_route_the_stamp_names_no_rehydrate_url
    Studio.draw_session_routes = false
    assert_nil page_stamp["rehydrateUrl"], "the store must never guess a URL the host did not draw"
  end

  # ---- 5. the page stamp never breaks a page in production ---------------------------

  def test_a_failing_stamp_is_logged_and_omitted_in_production_and_raises_in_test
    controller = SessionLabController.new
    controller.define_singleton_method(:studio_session_stamp) { raise ArgumentError, "stamp exploded" }

    assert_raises(ArgumentError, "test re-raises so a consumer's suite sees it") do
      controller.send(:studio_session_page_stamp)
    end

    original_env = Rails.env
    begin
      Rails.env = "production"
      assert_nil controller.send(:studio_session_page_stamp), "production renders the page without a stamp"
    ensure
      Rails.env = original_env
    end

    assert_equal 1, ErrorLog.where("message LIKE ?", "%stamp exploded%").count, "the failure reached ErrorLog"
  ensure
    ErrorLog.delete_all
  end

  def test_expiry_comes_from_the_session_store_expire_after
    controller = SessionLabController.new
    request = ActionDispatch::TestRequest.create
    controller.set_request!(request)

    assert_nil controller.send(:studio_session_expires_at)

    request.session_options = { expire_after: 2.hours }
    expires = controller.send(:studio_session_expires_at)
    assert_in_delta Time.now + 7200, expires, 5
  end
end
