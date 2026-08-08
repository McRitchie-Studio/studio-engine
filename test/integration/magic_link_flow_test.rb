# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] The magic-link click, driven through the real stack — router →
# Studio::LinksController → Studio::LinkConsumption → session cookie. The
# decision table itself is unit-tested in test/lib/studio/link_resolution_test.rb;
# THIS suite proves the wiring behind it: that the token really burns, that the
# session cookie really survives (or really switches), and that a GET really is
# inert.
#
# It exists because the unit table can be perfectly right while the controller
# still signs the wrong person in — the two failures the operator actually hit
# were both wiring, not logic:
#
#   1. a ~350-character token in the URL
#   2. a second click dumping a signed-in visitor on the login page
#
# Both are asserted here against a real HTTP round trip.
ActionDispatch::IntegrationTest.app = Rails.application

# Engine tables. The engine ships the models; the host app owns the schema, so
# the dummy defines the columns these flows touch. `metadata` is jsonb in the
# reference migration and json here — SQLite has no jsonb, and the model only
# ever reads it as a Hash.
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

  # A stand-in for the real table, used only to prove the MissingTable guard
  # stands ASIDE for a statement failure that is not a missing table. It carries
  # every column the mint writes, plus one the database requires and the mint
  # never sets — so the INSERT reaches the adapter and fails there, with the
  # table very much existing. Declared here with the rest of the schema so no
  # test ever has to drop or alter a shared table to reach that branch.
  create_table :studio_links_probe, force: true do |t|
    t.string   :token, null: false
    t.string   :kind, null: false
    t.string   :linkable_type
    t.bigint   :linkable_id
    t.json     :metadata
    t.datetime :expires_at
    t.datetime :consumed_at
    t.string   :required_by_the_database, null: false
    t.timestamps
  end

  create_table :users, force: true do |t|
    t.string   :email, null: false
    t.string   :name
    t.string   :session_token
    t.datetime :email_verified_at
    # set_app_session reads provider/uid straight off the user for the shared
    # SSO awareness keys, so the host User contract carries them.
    t.string   :provider
    t.string   :uid
    t.timestamps
  end
  add_index :users, :email, unique: true

  # handle_unexpected_error logs before re-raising in test env; without this
  # table a genuine failure would surface as a confusing NoTable error instead.
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

# The host contract the engine's controllers inherit. A real consuming app looks
# exactly like this: ApplicationController includes Studio::ErrorHandling and
# wires the OPSEC-045 session-token check ahead of authentication.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  before_action :verify_session_token
end

class User < ApplicationRecord
  def display_name
    name.presence || email.split("@").first
  end
end

class MagicLinkFlowTest < ActionDispatch::IntegrationTest
  OWNER  = "owner@example.com"
  OTHER  = "other@example.com"
  UNSEEN = "brand-new@example.com"
  TARGET = "/dashboard"

  def setup
    Studio::Link.delete_all
    User.delete_all
    @owner = User.create!(email: OWNER, name: "Owner")
    @other = User.create!(email: OTHER, name: "Other")
  end

  # --- 1. the token is short ------------------------------------------------

  # The reported symptom, asserted on the URL a real request produces rather
  # than on the generator: the whole link must fit on one line.
  test "a minted link is a short /l/<token> URL, not a signed blob" do
    path = "/l/#{mint(OWNER).token}"

    assert_operator path.length, :<=, 24, "#{path} is too long to be a house magic link"
    assert_match %r{\A/l/[A-Za-z0-9_-]{16}\z}, path
  end

  # One token format deserves one door. Asserted on the route table rather than
  # by driving a request, because a missing route surfaces as whatever the
  # exception middleware decides to render.
  test "the retired /magic_link/:token door is gone, and /l is the only one" do
    specs = Rails.application.routes.routes.map { |r| r.path.spec.to_s }

    refute_includes specs, "/magic_link/:token(.:format)",
                    "the legacy token door must not be drawn alongside /l/:token"
    assert_includes specs, "/l/:token(.:format)"
    assert_equal "/magic_link", Rails.application.routes.url_helpers.magic_link_request_path,
                 "requesting a link is still a POST to /magic_link"
  end

  # The single-use burn lives behind POST and nothing else. The GET beside it
  # renders a form that posts here — that asymmetry is what makes an email
  # scanner's prefetch harmless.
  test "the burn is POST-only and the interstitial posts to it" do
    consume = Rails.application.routes.routes.find { |r| r.name == "link_consume" }
    refute_nil consume
    assert_equal "POST", consume.verb

    get "/l/#{mint(OWNER).token}"
    assert_match(/<form[^>]+method="post"/, response.body)
    assert_match %r{action="/l/[A-Za-z0-9_-]{16}"}, response.body
  end

  # --- 2. the ordinary sign-in still works ----------------------------------

  test "a live link signs in an existing user and lands on return_to" do
    link = mint(OWNER, return_to: TARGET)

    get "/l/#{link.token}"
    assert_response :success, "the GET renders the confirm interstitial"
    assert_nil session[:user_id], "the GET must not sign anyone in"
    assert_nil link.reload.consumed_at, "the GET must not burn the token"

    post "/l/#{link.token}"
    assert_redirected_to TARGET
    assert_equal @owner.id, session[:user_id]
    refute_nil link.reload.consumed_at, "the POST burns the token"
  end

  test "a live link creates the account when the email has none" do
    link = mint(UNSEEN)

    post "/l/#{link.token}"

    user = User.find_by(email: UNSEEN)
    refute_nil user, "create-or-login must create the account on first click"
    assert_equal user.id, session[:user_id]
    refute_nil user.email_verified_at, "clicking the link proves ownership"
  end

  # An email scanner prefetching the URL must not spend the token before the
  # human arrives. Two GETs, then the real POST.
  test "a scanner prefetch leaves the link usable" do
    link = mint(OWNER)

    get "/l/#{link.token}"
    get "/l/#{link.token}"
    assert_nil link.reload.consumed_at

    post "/l/#{link.token}"
    assert_equal @owner.id, session[:user_id]
  end

  # --- 3. the second click, same user: "just treat it as a redirect" --------

  # THE reported bug, end to end. Sign in with the link, click it again, and
  # the visitor must be exactly where a plain link would have put them — signed
  # in, on the destination, with nothing shouted at them.
  test "clicking your own link a second time is an ordinary redirect" do
    link = mint(OWNER, return_to: TARGET)

    post "/l/#{link.token}"
    assert_equal @owner.id, session[:user_id]
    follow_redirect! # land on the page, which sweeps the sign-in flash

    post "/l/#{link.token}"

    assert_redirected_to TARGET, "a spent link of your own lands where it always pointed"
    assert_equal @owner.id, session[:user_id], "the session must survive the second click"

    follow_redirect!
    assert_equal "dashboard", response.body,
                 "the landing page must show the visitor nothing — no alert, no notice, " \
                 "no sign that anything happened at all"
  end

  test "the second click never routes a signed-in visitor to the login page" do
    link = mint(OWNER)
    post "/l/#{link.token}"

    post "/l/#{link.token}"

    refute_equal "/login", redirect_path,
                 "landing on /login while holding a valid session is the whole reported bug"
  end

  # The GET half of the same story: a dead link settles immediately instead of
  # rendering a spinner that only POSTs to learn it is dead.
  test "GET on your own spent link redirects instead of rendering the spinner" do
    link = mint(OWNER, return_to: TARGET)
    post "/l/#{link.token}"

    get "/l/#{link.token}"

    assert_redirected_to TARGET
    assert_equal @owner.id, session[:user_id]
  end

  # A live link the viewer already holds a session for still burns — otherwise a
  # forwarded email would stay usable by whoever received it.
  test "a re-click on your own LIVE link still burns the token" do
    sign_in_as(@owner)
    link = mint(OWNER)

    post "/l/#{link.token}"

    assert_equal @owner.id, session[:user_id]
    refute_nil link.reload.consumed_at, "the token must not survive a same-user click"
  end

  # --- 4. a dead link never touches the session -----------------------------

  test "someone else's expired link leaves your session alone and explains why" do
    sign_in_as(@owner)
    link = mint(OTHER, return_to: TARGET, expires_at: 1.hour.ago)

    post "/l/#{link.token}"

    assert_equal @owner.id, session[:user_id], "an expired link must not log anyone out"
    assert_redirected_to "/", "another user's destination is not ours to follow"
    assert_includes flash[:notice], OTHER
    assert_includes flash[:notice], "has expired"
    assert_includes flash[:notice], OWNER, "reassure them their own session survived"
  end

  test "someone else's already-used link leaves your session alone" do
    used = mint(OTHER)
    post "/l/#{used.token}"           # the other user consumes it
    reset!

    sign_in_as(@owner)
    post "/l/#{used.token}"

    assert_equal @owner.id, session[:user_id]
    assert_includes flash[:notice], "was already used"
  end

  test "your own expired link is a silent redirect, not a logout" do
    sign_in_as(@owner)
    link = mint(OWNER, return_to: TARGET, expires_at: 1.hour.ago)

    post "/l/#{link.token}"

    assert_redirected_to TARGET
    assert_equal @owner.id, session[:user_id]

    follow_redirect!
    assert_equal "dashboard", response.body, "an expired link of your own is still just a redirect"
  end

  test "an unrecognized token leaves a held session alone" do
    sign_in_as(@owner)

    post "/l/this-token-is-fake"

    assert_equal @owner.id, session[:user_id]
    assert_redirected_to "/"
    assert_includes flash[:notice], "is no longer valid"
  end

  # A referral token is reusable and is handled entirely on GET, so POSTing one
  # at the consume door must read as an unrecognized token — not as a magic link.
  test "a referral token posted to the consume door signs nobody in" do
    sign_in_as(@owner)
    referral = Studio::Link.referral_for(@other, target: TARGET)

    post "/l/#{referral.token}"

    assert_equal @owner.id, session[:user_id]
    assert_nil referral.reload.consumed_at, "a referral link is reusable — it must not burn"
  end

  # --- 5. a signed-out visitor still gets the sign-in page ------------------

  test "a dead link sends a visitor with no session to login, with the reason" do
    link = mint(OWNER)
    post "/l/#{link.token}"
    reset!

    post "/l/#{link.token}"

    assert_redirected_to "/login"
    assert_includes flash[:alert], "was already used"
    assert_nil session[:user_id]
  end

  # --- 6. a different user's LIVE link takes over ---------------------------

  test "a live link for another user overwrites the session" do
    sign_in_as(@owner)
    link = mint(OTHER, return_to: TARGET)

    post "/l/#{link.token}"

    assert_equal @other.id, session[:user_id], "a live link is proof of ownership"
    assert_redirected_to TARGET
    assert_equal @other.reload.session_token, session[:session_token],
                 "the OPSEC-045 binding must follow the new identity, or the next request bounces"

    # And the switch has to SURVIVE — verify_session_token runs on every
    # subsequent request and would bounce a session whose binding went stale.
    follow_redirect!
    assert_response :success
  end

  # --- 7. no open redirect rides in on a link -------------------------------

  test "an off-origin return_to is dropped, not followed" do
    link = mint(OWNER, return_to: "https://evil.test/steal")

    post "/l/#{link.token}"

    assert_redirected_to "/", "an absolute URL must collapse to the safe default"
  end

  test "a protocol-relative return_to is dropped on the dead path too" do
    sign_in_as(@owner)
    link = mint(OWNER, return_to: "//evil.test/steal", expires_at: 1.hour.ago)

    post "/l/#{link.token}"

    assert_redirected_to "/"
  end

  private

  def mint(email, return_to: nil, expires_at: nil)
    link = Studio::Link.create_magic_link(email: email, return_to: return_to)
    link.update!(expires_at: expires_at) if expires_at
    link
  end

  # Establish a session the way the app does, through a real consume, so the
  # cookie under test is the genuine article rather than a hand-written one.
  def sign_in_as(user)
    post "/l/#{Studio::Link.create_magic_link(email: user.email).token}"
    assert_equal user.id, session[:user_id], "test setup: expected #{user.email} to be signed in"
    # Land on the page so the sign-in flash is swept. Without this, every later
    # assertion about "did the click say anything" reads a stale notice from the
    # setup and passes (or fails) for the wrong reason.
    follow_redirect!
  end

  def redirect_path
    URI.parse(response.location.to_s).path
  end
end

# [unit] Studio::Link's burn contract — the atomic half of the flow above. The
# click resolver trusts #burn to tell it the truth about who won the single-use
# race; a wrong answer here signs the wrong person in, or nobody.
class StudioLinkBurnTest < ActiveSupport::TestCase
  EMAIL = "burner@example.com"

  def setup
    Studio::Link.delete_all
  end

  test "the first burn wins and every later one loses" do
    link = Studio::Link.create_magic_link(email: EMAIL)

    assert link.burn, "the first click must win"
    refute link.burn, "a single-use token cannot burn twice"
    assert_equal :used, link.dead_status
  end

  # The real concurrency case: two requests each holding their own copy of the
  # row, both believing it live. Exactly one may win — that is what makes the
  # burn, and not a prior `live?` read, the proof a link was good.
  test "two concurrent clicks on the same row produce exactly one winner" do
    token = Studio::Link.create_magic_link(email: EMAIL).token
    first  = Studio::Link.find_by(token: token)
    second = Studio::Link.find_by(token: token)

    results = [first.burn, second.burn]

    assert_equal [true, false], results.sort_by { |r| r ? 0 : 1 },
                 "exactly one of two simultaneous clicks may burn the token"
    assert_equal :used, second.dead_status, "the loser must read as used, not as a mystery"
  end

  test "an expired link never burns and reports why" do
    link = Studio::Link.create_magic_link(email: EMAIL)
    link.update!(expires_at: 1.minute.ago)

    refute link.burn
    assert_nil link.reload.consumed_at, "a failed burn must not half-consume the row"
    assert_equal :expired, link.dead_status
  end

  # Both flags set: the reader is better served by "you already used it" than by
  # "it expired" — the first is the thing they did, the second is just the clock.
  test "a link that was used AND has since expired reads as used" do
    link = Studio::Link.create_magic_link(email: EMAIL)
    link.burn
    link.update!(expires_at: 1.minute.ago)

    assert_equal :used, link.dead_status
  end

  test "a referral link is reusable, so it burns every time" do
    owner = Studio::Link.create_magic_link(email: EMAIL) # any AR record works as an owner
    referral = Studio::Link.referral_for(owner)

    assert referral.burn
    assert referral.burn, "referral links are deliberately NOT single-use"
    assert_nil referral.reload.consumed_at
  end

  # An app that enabled :magic_link but never installed the table. Every
  # consumer pins the engine `~> 0.x`, which admits any release below 1.0, so
  # this is reachable by a plain `bundle update` with nobody having adopted
  # anything. Without the guard it surfaces as a bare adapter error on a real
  # person's sign-in; the point of the test is that the message names the fix.
  #
  # Both branches are probed through a THROWAWAY SUBCLASS pointed at a different
  # table, never by dropping or altering the real one. An earlier draft did drop
  # it and restore it in `ensure`, which corrupted whichever tests happened to
  # run afterwards — green on most seeds, five failures on 62338. Sharing a
  # schema across a process means a test that edits it is not isolated, however
  # carefully it tidies up.
  def probe_link_class(table)
    Class.new(Studio::Link) do
      self.table_name = table
      def self.name = "ProbeLink"
    end
  end

  test "minting without the table names the missing migration" do
    error = assert_raises(Studio::Link::MissingTable) do
      probe_link_class("studio_links_never_migrated").create_magic_link(email: EMAIL)
    end

    assert_includes error.message, "studio_links"
    assert_includes error.message, "db/migrate", "the message must point at the migration to copy"
  end

  # ...and never swallows a failure that is NOT a missing table. Probed against
  # studio_links_probe, which exists and carries a NOT NULL column the mint
  # never sets, so the insert fails at the adapter for a reason the guard has no
  # business claiming.
  test "an unrelated statement failure is re-raised untouched" do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      probe_link_class("studio_links_probe").create_magic_link(email: EMAIL)
    end

    refute_kind_of Studio::Link::MissingTable, error,
                   "the table exists, so the guard must stand aside"
    assert_match(/required_by_the_database/, error.message,
                 "the ORIGINAL failure must survive, not be reworded")
  end

  test "minting normalizes the email, sanitizes return_to, and sets the TTL" do
    link = Studio::Link.create_magic_link(email: "  Mixed@Case.COM ", return_to: "//evil.test")

    assert_equal "mixed@case.com", link.email
    assert_nil link.return_to, "an off-origin return_to must never reach the row's reader"
    assert_in_delta Studio.magic_link_ttl.from_now.to_f, link.expires_at.to_f, 5
    assert link.live?
  end
end

# [unit] The retired :signed store. Asserted against the SHIPPED lib/studio.rb
# (not the pure suite's hand-written mirror), because the point is that a real
# app's initializer cannot quietly select a store that no longer exists.
class MagicLinkStoreRetirementTest < ActiveSupport::TestCase
  test "selecting the retired :signed store fails loudly at boot" do
    error = assert_raises(ArgumentError) { Studio.magic_link_store = :signed }

    assert_includes error.message, "retired"
    assert_includes error.message, "studio_links",
                    "the error must name the migration the app is missing, not just refuse"
    assert_equal :database, Studio.magic_link_store, "the refusal must not leave a half-set value"
  end

  # Why loudly and not silently: an app whose initializer still said :signed
  # would otherwise boot, mint Studio::Link rows against a table it never
  # migrated, and 500 on a real person's sign-in instead of on the deploy.
  test "the only accepted value is the one true store" do
    Studio.magic_link_store = :database
    assert_equal :database, Studio.magic_link_store

    Studio.magic_link_store = "database" # a string spelling is the same choice
    assert_equal :database, Studio.magic_link_store

    assert_raises(ArgumentError) { Studio.magic_link_store = "signed" }
    assert_raises(ArgumentError) { Studio.magic_link_store = :redis }
  end

  test "the /l route is the standard, and an app can still own its own path" do
    original = Studio.draw_link_routes
    begin
      Studio.draw_link_routes = true
      assert Studio.magic_link_via_l_route?

      Studio.draw_link_routes = false
      refute Studio.magic_link_via_l_route?,
             "an app drawing its own token route (turf-monster) must not be handed /l URLs"
    ensure
      Studio.draw_link_routes = original
    end
  end
end
