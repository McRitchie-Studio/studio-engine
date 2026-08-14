# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] /profile's writes, DISPATCHED — real requests through the full
# router → controller → database stack.
#
# WHY THIS FILE EXISTS. The guards on /profile were originally proven by
# regex-scanning the controller's SOURCE, because the engine dummy was believed
# to have no users table. That harness has two failure modes and both showed up:
# it passes if a guard regresses to always-true, and it FAILS on a harmless
# reformat — which happened on PR #129 the moment a guard legitimately checked
# two columns while naming one row. Carl raised it as F2 on #127.
#
# The dummy does have a database (test/dummy/config/database.yml + sqlite3), and
# test/integration/local_review_endpoint_test.rb already proved the pattern: set
# the integration app, declare the schema this file needs inline, and supply the
# host constants the engine's controllers inherit. bin/release-check runs each
# test FILE in its own process, so these top-level constants collide with
# nothing.
#
# What is deliberately NOT here: the avatar ATTACHMENT path, which needs
# ActiveStorage tables — a heavier setup for a row whose markup the view suite
# already covers. The avatar row's guard is unit-tested through
# Studio::ProfileSections.served_by?.
ActionDispatch::IntegrationTest.app = Rails.application

# Studio::ErrorHandling#require_authentication answers format.turbo_stream (the
# OPSEC-046 fix: an AJAX request must get a clean 401 rather than a 406 from a
# blind redirect to the HTML login page). `turbo_stream` is a MIME type
# turbo-rails registers, and this dummy carries no turbo-rails — so without this
# line every authenticated request in the suite dies inside the guard with
# "register it as a MIME type first", which reads like a bug in the code under
# test and is not one. Every real consumer is a Rails app with turbo.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  # The host owns this table in production. The columns here are exactly the ones
  # /profile reads: the standard profile columns plus the OAuth pair.
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :first_name
    t.string :role
    t.string :provider
    t.string :uid
    t.timestamps
  end

  # Studio::ErrorHandling#rescue_and_log writes here on any unexpected exception,
  # so a controller that raised would fail with "Could not find table" instead of
  # reporting the actual bug. Same declaration the magic-link suites carry.
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

# The engine's controllers inherit the HOST's ApplicationController. Studio::ErrorHandling
# is what supplies current_user / logged_in? / require_authentication / rescue_and_log —
# every consumer includes it, so a dummy that did not would be testing a host
# nobody ships.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
end

# A sign-in door for the suite. Deliberately a REAL controller writing the REAL
# session key the engine reads (Studio.session_key), rather than stubbing
# current_user: stubbing the thing under test is how a guard that never runs
# still looks guarded.
class TestSessionsController < ApplicationController
  # Studio::ErrorHandling's `included do` adds `before_action :require_authentication`
  # to every controller of a consuming app — so the sign-in door itself needs the
  # skip, exactly as a host's SessionsController does. Worth noting for what it
  # proves about the engine: authentication is ON by default for a host that
  # includes the concern, which is why Studio::ProfilesController's own explicit
  # `before_action :require_authentication` is a belt-and-braces guard against a
  # host that skipped it application-wide, not a redundancy.
  skip_before_action :require_authentication

  def create
    session[Studio.session_key] = params[:id]
    head :ok
  end
end

Rails.application.routes.append do
  post "test_sign_in/:id", to: "test_sessions#create"
end
Rails.application.reload_routes!

class ProfileRequestsTest < ActionDispatch::IntegrationTest
  def setup
    User.delete_all
  end

  def sign_in(user)
    post "/test_sign_in/#{user.id}"
    assert_response :ok
  end

  def create_user(**attrs)
    User.create!({ email: "pat@example.com", name: "Pat Studio", role: "viewer" }.merge(attrs))
  end

  # --- the page itself --------------------------------------------------------

  test "a signed-out visitor is sent to login, not shown the page" do
    get "/profile"

    assert_response :redirect
    assert_equal "/login", URI(response.location).path
  end

  test "a signed-in visitor gets the page" do
    sign_in create_user
    get "/profile"

    assert_response :success
    assert_includes response.body, "Your name"
    assert_includes response.body, "Google account"
  end

  # THE MODEL GATE, proven by a real render rather than by unit-testing the
  # predicate. This suite's User carries no `avatar` attachment (ActiveStorage is
  # deliberately out of scope here), so the avatar row must simply not be there —
  # the same way mcritchie-industries' page drops the first-name row until it
  # installs the standard profile columns. A page that raised, or that rendered
  # an empty "Profile photo" card, would both be failures.
  test "a row the model cannot serve is absent, not empty or broken" do
    sign_in create_user
    get "/profile"

    assert_response :success
    refute_includes response.body, "Profile photo"
    refute_includes response.body, 'data-profile-section="avatar"'
  end

  # --- PATCH /profile — the first-name write ----------------------------------

  test "patching a first name persists it" do
    user = create_user(first_name: nil)
    sign_in user

    patch "/profile", params: { profile: { first_name: "Alexander" } }

    assert_response :redirect
    assert_equal "Alexander", user.reload.first_name
  end

  test "a blank first name is refused and writes nothing" do
    user = create_user(first_name: "Original")
    sign_in user

    patch "/profile", params: { profile: { first_name: "   " } }

    assert_response :see_other
    assert_equal "Original", user.reload.first_name, "a refused write must not clobber"
  end

  test "a first name is trimmed, collapsed and capped" do
    user = create_user(first_name: nil)
    sign_in user

    patch "/profile", params: { profile: { first_name: "  Ada   Lovelace  " } }
    assert_equal "Ada Lovelace", user.reload.first_name

    patch "/profile", params: { profile: { first_name: "x" * 200 } }
    assert_equal Studio::FIRST_NAME_MAX_LENGTH, user.reload.first_name.length
  end

  test "a blank name is backfilled from the first name" do
    # So the display-name chain has something better than an email prefix.
    user = create_user(name: "", first_name: nil)
    sign_in user

    patch "/profile", params: { profile: { first_name: "Ada" } }

    assert_equal "Ada", user.reload.name
  end

  test "an existing name is not overwritten by a first-name save" do
    user = create_user(name: "Ada Lovelace", first_name: nil)
    sign_in user

    patch "/profile", params: { profile: { first_name: "Ada" } }

    assert_equal "Ada Lovelace", user.reload.name
  end

  # --- DELETE /profile/google — the orphan guard, behaviourally ----------------
  #
  # THE TEST THIS FILE WAS WRITTEN FOR. turf-monster's unlink is an
  # unconditional update!(provider: nil, uid: nil); for an account whose only
  # sign-in is Google that locks the person out behind a button labelled
  # "Unlink". The engine refuses — and this proves the refusal by REQUESTING it
  # and reading the database afterwards, not by reading the controller.

  test "unlinking google from an account with no other sign-in is refused" do
    user = create_user(email: nil, provider: "google_oauth2", uid: "123")
    sign_in user

    delete "/profile/google"

    assert_response :see_other
    user.reload
    assert_equal "google_oauth2", user.provider, "the identity must survive a refused unlink"
    assert_equal "123", user.uid
  end

  test "unlinking google succeeds when an email keeps the account reachable" do
    user = create_user(email: "pat@example.com", provider: "google_oauth2", uid: "123")
    sign_in user

    delete "/profile/google"

    assert_response :redirect
    user.reload
    assert_nil user.provider
    assert_nil user.uid
  end

  test "unlinking when nothing is linked is refused rather than pretending" do
    user = create_user(provider: nil, uid: nil)
    sign_in user

    delete "/profile/google"

    assert_response :see_other
  end

  test "a signed-out visitor cannot unlink anyone" do
    user = create_user(email: nil, provider: "google_oauth2", uid: "123")

    delete "/profile/google"

    assert_response :redirect
    assert_equal "google_oauth2", user.reload.provider
  end

  # --- the guard is the SERVER's, not the button's ----------------------------

  # The row renders the Unlink control disabled for a Google-only account. A
  # disabled button is a courtesy — anyone can send the DELETE. This asserts the
  # server refuses independently of what the page drew, which is the property
  # that actually protects the account.
  test "the refusal does not depend on the page having been rendered" do
    user = create_user(email: nil, provider: "google_oauth2", uid: "123")
    sign_in user

    # No GET /profile first — straight to the write.
    delete "/profile/google"

    assert_response :see_other
    assert_equal "google_oauth2", user.reload.provider
  end
end
