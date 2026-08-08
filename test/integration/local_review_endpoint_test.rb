# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# Drive the real dummy app through the full router → controller stack. (Not
# rails/test_help: that boots the fixture machinery this suite has no use for.
# The schema it does need is declared below, in the file that needs it.)
ActionDispatch::IntegrationTest.app = Rails.application

# The mint writes a real Studio::Link row, so the suite needs the table. The
# consuming apps own this schema in production (db/migrate/…_create_studio_links).
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
end

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
#      lands on the URL that consumes it — the mint/URL pairing that
#      Studio::MagicLinkIssuing exists to keep aligned.
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
    Studio::Link.delete_all
    # Force the route set to DRAW here, under the test env. Rails 8.1 draws
    # lazily, and the dev-only routes are drawn `unless Rails.env.production?` —
    # so a test that flips Rails.env before the first draw would strand the whole
    # process with those routes missing. CI caught exactly that (green locally on
    # one seed, 404s on another); this pins the draw before any env games.
    Rails.application.routes.url_helpers.login_path
  end

  # --- 1 + 2. a real token, on the matching URL, carrying the review page ----

  test "mints a real short token and lands on the URL that consumes it" do
    get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }

    assert_response :redirect
    path = URI.parse(response.location).path
    assert_match %r{\A/l/[A-Za-z0-9_-]{16}\z}, path,
      "a Studio::Link row is consumable at the short /l/<token>, and nowhere else"

    # Consume the row the endpoint actually wrote — proves the token is live,
    # not merely well shaped.
    link = Studio::Link.consume!(path.split("/").last)
    assert_equal OPERATOR, link.email
    assert_equal "/admin/style", link.return_to,
      "the page under review must survive as return_to, or the button lands on the wrong page"
  end

  # --- 3. no open redirect rides out on a sign-in link ------------------------

  test "an off-origin return_to is dropped, not carried" do
    get "/_studio/local_review", params: { email: OPERATOR, return_to: "http://evil.test/steal" }

    assert_nil minted_link.return_to,
      "an absolute URL must collapse to nil so the consume falls back to a safe local default"
  end

  test "a protocol-relative return_to is dropped too" do
    get "/_studio/local_review", params: { email: OPERATOR, return_to: "//evil.test/steal" }

    assert_nil minted_link.return_to
  end

  # --- a missing/garbled email mints nothing ---------------------------------

  test "a blank email mints nothing and sends the operator to login" do
    get "/_studio/local_review", params: { return_to: "/admin/style" }

    assert_equal "/login", URI.parse(response.location).path
    assert_equal 0, Studio::Link.count
  end

  test "a malformed email mints nothing" do
    get "/_studio/local_review", params: { email: "not-an-email", return_to: "/admin/style" }

    assert_equal "/login", URI.parse(response.location).path
    assert_equal 0, Studio::Link.count
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

  # The row the endpoint just wrote. setup empties the table, so there is
  # exactly one — assert that rather than assuming it.
  def minted_link
    assert_equal 1, Studio::Link.count, "expected the endpoint to mint exactly one link"
    Studio::Link.last
  end
end
