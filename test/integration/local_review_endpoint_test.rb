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

  # The endpoint PROVISIONS the reviewer before minting, so the suite needs the
  # host's users table. `role` is the column require_admin reads; a host that
  # has none is covered by the respond_to? branch, asserted separately.
  create_table :users, force: true do |t|
    t.string :email, null: false
    t.string :name
    t.string :role
    t.timestamps
  end
  add_index :users, :email, unique: true
end

# The dummy app carries no controllers of its own; the engine's controllers
# inherit the HOST's ApplicationController, so define the minimal base a host
# provides. Nothing else in the dummy claims this constant.
class ApplicationController < ActionController::Base
end

# The host contract the engine reads: an account with a role, and `admin?`
# spelled the way Studio::ErrorHandling#require_admin spells it.
class User < ApplicationRecord
  def admin? = role == "admin"
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
#   4. It PROVISIONS the reviewer at Studio.local_review_role before minting, so
#      the consume signs in an EXISTING admin instead of creating a viewer the
#      page under review will bounce. Landing signed-in on "/" instead of on the
#      page is the whole failure this endpoint exists to prevent, and the role
#      is the half that was missing.
#   5. With NO `?email=` it answers "who is sitting at this desk?" itself —
#      Studio.local_review_email, else the first admin by id. The board's CTA is
#      a public, sign-in-free redirect, so it sends no email; publishing the
#      operator's address on a public page is the thing being avoided.
#   6. It is a developer-desk tool: the route is not drawn in production, and a
#      non-loopback request 404s before it provisions or mints anything. It
#      hands out sign-in material AND now grants a role, so those two gates are
#      the only thing standing in front of it — they are asserted, not assumed.
class LocalReviewEndpointTest < ActionDispatch::IntegrationTest
  OPERATOR = "amcritchie@gmail.com"

  def setup
    Studio::Link.delete_all
    User.delete_all
    @original_role = Studio.local_review_role
    @original_email = Studio.local_review_email
    Studio.local_review_role = "admin"
    Studio.local_review_email = nil
    # Force the route set to DRAW here, under the test env. Rails 8.1 draws
    # lazily, and the dev-only routes are drawn `unless Rails.env.production?` —
    # so a test that flips Rails.env before the first draw would strand the whole
    # process with those routes missing. CI caught exactly that (green locally on
    # one seed, 404s on another); this pins the draw before any env games.
    Rails.application.routes.url_helpers.login_path
  end

  def teardown
    Studio.local_review_role = @original_role
    Studio.local_review_email = @original_email
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

  # No email named AND nobody to derive one from (setup empties `users`), so
  # there is no operator at this desk. The endpoint says so instead of guessing.
  # When the desk DOES have an operator, section 5 covers who gets picked.
  test "a blank email on an operator-less desk mints nothing and sends you to login" do
    assert_equal 0, User.count, "precondition: nobody to derive a reviewer from"

    get "/_studio/local_review", params: { return_to: "/admin/style" }

    assert_equal "/login", URI.parse(response.location).path
    assert_equal 0, Studio::Link.count
  end

  test "a malformed email mints nothing" do
    get "/_studio/local_review", params: { email: "not-an-email", return_to: "/admin/style" }

    assert_equal "/login", URI.parse(response.location).path
    assert_equal 0, Studio::Link.count
  end

  # --- 4. the reviewer can actually SEE the page -----------------------------

  # The bug, stated as a test. Before this, an unseen email reached the page
  # under review as a freshly-created "viewer" and require_admin sent it to "/".
  test "an email the database has never seen is provisioned as an admin" do
    assert_nil User.find_by(email: OPERATOR), "precondition: a virgin database"

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }

    user = User.find_by(email: OPERATOR)
    refute_nil user, "the reviewer must exist BEFORE the link is consumed"
    assert user.admin?, "a reviewer who is not an admin gets bounced off the page under review"
  end

  # Provisioning must PRECEDE the mint, not merely accompany it: a link consumed
  # before the account exists takes sign_up_new and lands at the default role.
  # Asserted causally — by asking, at the moment of the mint, whether the account
  # is already there — rather than by comparing two timestamps that can tie.
  test "the account already exists at the moment the token is minted" do
    existed_at_mint = :never_minted
    original = Studio::Link.method(:create_magic_link)
    Studio::Link.define_singleton_method(:create_magic_link) do |**kwargs|
      existed_at_mint = User.exists?(email: kwargs[:email])
      original.call(**kwargs)
    end

    begin
      get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }
    ensure
      Studio::Link.define_singleton_method(:create_magic_link, original)
    end

    assert_equal true, existed_at_mint,
      "provision before minting, or the consume takes sign_up_new and creates a viewer"
    refute_nil minted_link, "and the mint still happened"
  end

  test "an existing non-admin is promoted rather than left to bounce" do
    User.create!(email: OPERATOR, role: "viewer")

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }

    assert_equal "admin", User.find_by(email: OPERATOR).role
    assert_equal 1, User.where(email: OPERATOR).count, "promote the account, never duplicate it"
  end

  test "an existing admin is left exactly as it stands" do
    user = User.create!(email: OPERATOR, name: "Mr. McRitchie", role: "admin")
    before = user.updated_at

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }

    user.reload
    assert_equal "admin", user.role
    assert_equal "Mr. McRitchie", user.name
    assert_equal before, user.updated_at, "an already-correct account must not be rewritten"
  end

  # [unit] The role is a knob, not a hardcoded literal — an app whose review
  # pages are not admin-gated can point it somewhere else.
  test "the provisioned role follows Studio.local_review_role" do
    Studio.local_review_role = "editor"

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }

    assert_equal "editor", User.find_by(email: OPERATOR).role
  end

  # [unit] ...and can be switched OFF entirely, which still provisions the
  # account (so the consume signs in rather than signs up) but leaves the role
  # to the host's own configure_new_user.
  test "a blank Studio.local_review_role provisions the account without a role" do
    Studio.local_review_role = nil

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }

    user = User.find_by(email: OPERATOR)
    refute_nil user, "the account is still created — that is what avoids sign_up_new"
    assert_nil user.role
  end

  # [unit] The shipped default. Asserted against lib/studio.rb so a later edit
  # that drops the default reddens here rather than in a worktree at 2am.
  test "Studio.local_review_role defaults to admin" do
    Studio.local_review_role = @original_role
    assert_equal "admin", Studio.local_review_role
  end

  # Provisioning is an upgrade to the mint, not a precondition of it. A host
  # with an extra User validation must still get a working sign-in link.
  test "a provisioning failure still mints a usable link" do
    original = User.method(:find_by)
    User.define_singleton_method(:find_by) { |*| raise ActiveRecord::StatementInvalid, "boom" }

    begin
      get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }
    ensure
      User.define_singleton_method(:find_by, original)
    end

    assert_response :redirect
    assert_match %r{\A/l/[A-Za-z0-9_-]{16}\z}, URI.parse(response.location).path,
      "the button must degrade to its old behavior, never to a 500"
  end

  test "a malformed email provisions nobody" do
    get "/_studio/local_review", params: { email: "not-an-email", return_to: "/admin/style" }

    assert_equal 0, User.count
  end

  # --- 5. no email named: the LOCAL desk answers "who is sitting here?" ------

  # The board's CTA is a public, sign-in-free redirect, so it sends no email —
  # publishing the operator's address on a public page is the thing being
  # avoided. The mint must still land someone signed in.
  test "with no email at all, the first admin in this database is signed in" do
    User.create!(email: "viewer@example.com", role: "viewer")
    User.create!(email: "first-admin@example.com", role: "admin")
    User.create!(email: "second-admin@example.com", role: "admin")

    get "/_studio/local_review", params: { return_to: "/admin/style" }

    assert_response :redirect
    assert_equal "first-admin@example.com", minted_link.email,
      "the desk's own operator signs in when the caller names nobody"
  end

  test "Studio.local_review_email outranks the derived admin" do
    User.create!(email: "first-admin@example.com", role: "admin")
    Studio.local_review_email = "named-operator@example.com"

    get "/_studio/local_review", params: { return_to: "/admin/style" }

    assert_equal "named-operator@example.com", minted_link.email
    assert User.find_by(email: "named-operator@example.com").admin?,
      "and the named operator is provisioned like any other reviewer"
  end

  test "an explicit ?email= still outranks everything" do
    User.create!(email: "first-admin@example.com", role: "admin")
    Studio.local_review_email = "named-operator@example.com"

    get "/_studio/local_review", params: { email: OPERATOR, return_to: "/admin/style" }

    assert_equal OPERATOR, minted_link.email
  end

  # The ordering is by id, not by whoever was touched last, so a re-seeded desk
  # resolves to the same person on every click.
  test "the derived admin is the FIRST by id, not the most recently updated" do
    first = User.create!(email: "first-admin@example.com", role: "admin")
    second = User.create!(email: "second-admin@example.com", role: "admin")
    second.update!(name: "touched last")
    first.update!(name: "touched first")

    get "/_studio/local_review", params: { return_to: "/admin/style" }

    assert_equal "first-admin@example.com", minted_link.email
  end

  # A desk with users but no ADMIN among them still has no operator — the
  # non-admin must not be promoted into one by accident.
  test "a desk whose only user is a viewer mints nothing rather than promoting them" do
    User.create!(email: "viewer@example.com", role: "viewer")

    get "/_studio/local_review", params: { return_to: "/admin/style" }

    assert_equal "/login", URI.parse(response.location).path
    assert_equal 0, Studio::Link.count, "a desk with no operator mints nothing rather than guessing"
    assert_equal "viewer", User.find_by(email: "viewer@example.com").role
  end

  # --- 6. the developer-desk floor -------------------------------------------

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

  # The gate has to close IN FRONT of the side effects, not beside them. Now
  # that the endpoint grants a role, a 404 that still provisioned an admin would
  # be a remote stranger minting himself an account — the 404 body would hide it.
  test "a non-loopback request provisions nobody and mints nothing" do
    get "/_studio/local_review",
        params: { email: OPERATOR, return_to: "/admin/style" },
        env: { "REMOTE_ADDR" => "203.0.113.7" }

    assert_response :not_found
    assert_equal 0, User.count, "the before_action must run BEFORE provisioning"
    assert_equal 0, Studio::Link.count
  end

  # Production is not asserted by driving a REQUEST under a flipped Rails.env:
  # such a request would be testing route absence while pretending to test the
  # controller, and flipping the env under a live app is what poisoned the
  # lazily-drawn route set for every later test in the process. Both halves of
  # the floor still get asserted directly — the gate refuses production (above),
  # and the route is never drawn there (below, into a THROWAWAY route set, so
  # the app's own routes are never touched).

  # The route itself is drawn only outside production — the outer gate. Assert
  # the mapping so a rename of the controller/action reddens here.
  test "Studio.routes draws /_studio/local_review -> studio/local_reviews#show" do
    assert_equal "/_studio/local_review", Rails.application.routes.url_helpers.studio_local_review_path

    route = Rails.application.routes.routes.find { |r| r.name == "studio_local_review" }
    refute_nil route, "expected a named studio_local_review route"
    assert_equal "studio/local_reviews", route.defaults[:controller]
    assert_equal "show", route.defaults[:action]
  end

  # The outer gate, asserted rather than assumed. An endpoint that provisions an
  # ADMIN for any email it is handed must be unreachable in production even if
  # the controller's own check were somehow bypassed — so prove the door is not
  # cut into the wall, not merely that it is locked.
  test "the developer-desk routes are NOT drawn in production" do
    dev_names  = drawn_route_names("development")
    prod_names = drawn_route_names("production")

    assert_includes dev_names, "studio_local_review",
      "sanity: the route must exist outside production, or this test proves nothing"
    refute_includes prod_names, "studio_local_review",
      "the local-review mint must not be routable in production"
    refute_includes prod_names, "studio_local_emails",
      "the whole developer-desk block travels together"
    assert_includes prod_names, "login",
      "sanity: the rest of the route set must still draw in production"
  end

  private

  # Draw Studio.routes into a fresh RouteSet under the given env and return the
  # named routes. Deliberately NOT the application's route set: drawing there
  # under a flipped env is what strands the process (see the note above).
  def drawn_route_names(env)
    original = Rails.env
    Rails.env = env
    set = ActionDispatch::Routing::RouteSet.new
    set.draw { Studio.routes(self) }
    set.routes.map(&:name).compact
  ensure
    Rails.env = original
  end

  # The row the endpoint just wrote. setup empties the table, so there is
  # exactly one — assert that rather than assuming it.
  def minted_link
    assert_equal 1, Studio::Link.count, "expected the endpoint to mint exactly one link"
    Studio::Link.last
  end
end
