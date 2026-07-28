# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# Drive the real dummy app through the full router → controller stack. (Not
# rails/test_help: that boots the fixture/schema machinery, and this dummy app
# carries no schema — this suite deliberately proves the endpoint with no
# database in reach.)
ActionDispatch::IntegrationTest.app = Rails.application

# The dummy app carries no controllers of its own; the engine's controllers
# inherit the HOST's ApplicationController, so define the minimal base a host
# provides. Nothing else in the dummy claims this constant.
class ApplicationController < ActionController::Base
end

# [integration] GET /_studio/local_review — the LOCAL half of the board's
# WAITING APPROVAL button. Exercised through the full stack (router →
# controller → redirect), not by naming the pieces.
#
# The properties that carry the feature, each asserted by CONSUMING what the
# endpoint mints rather than by matching a URL shape:
#
#   1. It mints a REAL, consumable sign-in token for the supplied email and
#      lands on the URL that consumes it in THIS app's store — the store/URL
#      pairing that Studio::MagicLinkIssuing exists to keep aligned.
#   2. The review page rides along as return_to, so the consume lands the
#      operator ON the page under review — the whole point of the button.
#   3. An off-origin return_to is dropped, not followed (no open redirect out
#      of a sign-in link).
#   4. It is a developer-desk tool: 404 in production, 404 for any request that
#      is not loopback. It hands out sign-in material without authenticating,
#      so those two gates are the only thing standing in front of it.
class LocalReviewEndpointTest < ActionDispatch::IntegrationTest
  OPERATOR = "amcritchie@gmail.com"

  def setup
    @orig_store = Studio.magic_link_store
    MagicLink.cache = ActiveSupport::Cache::MemoryStore.new # real single-use tracking
    # Force the route set to DRAW here, under the test env. Rails 8.1 draws
    # lazily, and the dev-only routes are drawn `unless Rails.env.production?` —
    # so a test that flips Rails.env before the first draw would strand the whole
    # process with those routes missing. CI caught exactly that (green locally on
    # one seed, 404s on another); this pins the draw before any env games.
    Rails.application.routes.url_helpers.login_path
  end

  def teardown
    Studio.magic_link_store = @orig_store
    MagicLink.cache = nil
  end

  # --- 1 + 2. a real token, on the matching URL, carrying the review page ----

  test "mints a consumable signed token and lands on the URL that consumes it" do
    Studio.magic_link_store = :signed

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }

    assert_response :redirect
    path = URI.parse(response.location).path
    assert_match %r{\A/magic_link/}, path,
      "a :signed token is only consumable at /magic_link/<token>, so that is where it must land"

    token = path.split("/").last
    result = MagicLink.consume(token) # the real service — proves the token is valid, not just shaped
    assert_equal OPERATOR, result.email
    assert_equal "/admin/style", result.return_to,
      "the page under review must survive as return_to, or the button lands on the wrong page"
  end

  test "a :database app lands on the short /l/<token> its store consumes" do
    Studio.magic_link_store = :database
    seen = {}

    # No stub library here (minitest 6 dropped minitest/mock) and no database
    # behind the dummy app — so stand a double in front of the mint and put it
    # back afterwards.
    with_link_mint(->(**kwargs) { seen = kwargs; Struct.new(:token).new("db-token-xyz") }) do
      get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }
    end

    assert_equal OPERATOR, seen[:email]
    assert_equal "/admin/style", seen[:return_to]
    assert_equal "/l/db-token-xyz", URI.parse(response.location).path,
      "a Studio::Link row is consumable at /l/<token>, never at /magic_link/<token>"
  end

  # --- 3. no open redirect rides out on a sign-in link ------------------------

  test "an off-origin return_to is dropped, not carried" do
    Studio.magic_link_store = :signed

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "http://evil.test/steal" }

    token = URI.parse(response.location).path.split("/").last
    assert_nil MagicLink.consume(token).return_to,
      "an absolute URL must collapse to nil so the consume falls back to a safe local default"
  end

  test "a protocol-relative return_to is dropped too" do
    Studio.magic_link_store = :signed

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "//evil.test/steal" }

    token = URI.parse(response.location).path.split("/").last
    assert_nil MagicLink.consume(token).return_to
  end

  # --- a missing/garbled email mints nothing ---------------------------------

  test "a blank email mints nothing and sends the operator to login" do
    Studio.magic_link_store = :signed

    get "/_studio/local_review", params: { return_to: "/admin/style" }

    assert_equal "/login", URI.parse(response.location).path
  end

  test "a malformed email mints nothing" do
    Studio.magic_link_store = :signed

    get "/_studio/local_review", params: { email: "not-an-email", return_to: "/admin/style" }

    assert_equal "/login", URI.parse(response.location).path
  end

  # --- 4. the developer-desk floor -------------------------------------------

  # [unit] The gate itself, against the SHIPPED lib/studio.rb. It lives here and
  # not in the pure-Ruby unit suite because that suite runs without Rails and so
  # exercises test_helper.rb's hand-written mirror of the Studio module — a gate
  # asserted against the mirror would stay green while the real one broke.
  test "the local-tool gate admits loopback and refuses everything else" do
    assert Studio.local_tool_enabled?(request_local: true)
    refute Studio.local_tool_enabled?(request_local: false)
    refute Studio.local_tool_enabled?(request_local: nil),
      "an unknown origin must fail closed, not be treated as loopback"
  end

  test "the local-tool gate is closed in production regardless of origin" do
    original = Rails.env
    begin
      Rails.env = "production"
      refute Studio.local_tool_enabled?(request_local: true)
    ensure
      Rails.env = original
    end
  end

  test "a non-loopback request gets nothing" do
    get "/_studio/local_review",
        params: { email: OPERATOR, return_to: "/admin/style" },
        env: { "REMOTE_ADDR" => "203.0.113.7" }

    assert_response :not_found
  end

  # Production is asserted at the GATE (above), not by driving a request under a
  # flipped Rails.env: in production the route is never drawn in the first place
  # (lib/studio.rb draws the developer-desk block `unless Rails.env.production?`),
  # so such a request would be testing route absence while pretending to test the
  # controller — and flipping the env under a live app is what poisoned the
  # lazily-drawn route set for every later test in the process. The composition
  # that matters is proven either side of the seam: the before_action calls the
  # gate (the non-loopback 404 above), and the gate refuses production.


  # The route itself is drawn only outside production — the outer gate. Assert
  # the mapping so a rename of the controller/action reddens here.
  test "Studio.routes draws /_studio/local_review -> studio/local_reviews#show" do
    assert_equal "/_studio/local_review", Rails.application.routes.url_helpers.studio_local_review_path

    route = Rails.application.routes.routes.find { |r| r.name == "studio_local_review" }
    refute_nil route, "expected a named studio_local_review route"
    assert_equal "studio/local_reviews", route.defaults[:controller]
    assert_equal "show", route.defaults[:action]
  end

  private

  # No stub library (minitest 6 dropped minitest/mock) — stand a double in front
  # of the mint and put the original back.
  def with_link_mint(callable)
    singleton = Studio::Link.singleton_class
    original = singleton.instance_method(:create_magic_link)
    singleton.send(:define_method, :create_magic_link) { |**kwargs| callable.call(**kwargs) }
    yield
  ensure
    singleton.send(:define_method, :create_magic_link, original)
  end
end
