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

# Mail is asserted by what actually landed in ActionMailer::Base.deliveries, so
# the async hop has to resolve inside the request: Studio::Email.deliver calls
# deliver_later.
require "active_job"
ActiveJob::Base.queue_adapter = :inline
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
# The notification mail's banner and layout build absolute URLs, so the mailer
# needs a host — the same requirement the engine's existing magic-link mail
# carries, and one every real Rails app sets.
ActionMailer::Base.default_url_options = { host: "example.com" }
Rails.application.routes.default_url_options[:host] = "example.com"

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
    t.string :session_token
    # The newsletter pair. Declared here rather than left out because the row is
    # gated on `requires:` — a users table without them drops the row entirely,
    # and every newsletter assertion below would pass by never running.
    t.datetime :joined_email_list_at
    t.datetime :left_email_list_at
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
# A real consuming app looks exactly like this: ApplicationController includes
# Studio::ErrorHandling and wires the OPSEC-045 session-token check AHEAD of
# authentication (the shape magic_link_flow_test.rb has carried all along).
#
# WITHOUT verify_session_token THE SESSION TESTS BELOW CANNOT FAIL, which is how
# a broken re-establish shipped past them: rotating the token and then NOT
# putting the new one in the cookie left the suite green, because nothing in this
# dummy ever compared the two. Caught in review by mutation, not by the suite.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  before_action :verify_session_token
end

class User < ApplicationRecord
  def admin? = role == "admin"

  # The engine's avatar contract, which components/_avatar has required since
  # long before /profile existed — every real consumer defines these (that is
  # what Studio::UserProfile exists to supply). A double without them is thinner
  # than any app the engine actually ships to.
  def display_name = name.presence || email.to_s.split("@").first.presence || "anon"
  def avatar_initials = display_name.to_s[0].to_s.upcase
  def avatar_color = "#6366f1"

  # The OPSEC-045 seam. The engine calls this if the host answers it, so a host
  # that has it must have its rotation actually exercised — the whole point of
  # the call is that a hijacker's live session dies when the owner confirms.
  def regenerate_session_token!
    update_column(:session_token, SecureRandom.hex(8))
  end
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
    user = User.find(params[:id])
    user.regenerate_session_token! if user.session_token.blank?
    session[Studio.session_key] = user.id
    session[:session_token] = user.session_token
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

  # Mirrors what a host's real sign-in does — the session key AND the rotating
  # token that verify_session_token checks on every later request.
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

  # /profile is now the READ page: identity at a glance, plus the read-level rows.
  # The fields moved to /profile/edit.
  test "a signed-in visitor gets the read page" do
    user = create_user(name: "Pat Studio")
    sign_in user
    get "/profile"

    assert_response :success
    assert_includes response.body, "Pat Studio", "the identity header is the point of this page"
    assert_includes response.body, "Google account"
    refute_includes response.body, 'name="profile[first_name]"', "fields live on /profile/edit"
  end

  test "the edit page carries the fields" do
    sign_in create_user
    get "/profile/edit"

    assert_response :success
    assert_includes response.body, 'name="profile[first_name]"'
    assert_includes response.body, 'name="profile[email]"'
    refute_includes response.body, "Google account", "Google is read-level, on /profile"
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

  # --- the email field — a DIRECT change from any session ----------------------
  #
  # The out-of-band confirmation was removed on 2026-08-14: the session is the
  # authority now. What is asserted here is the behaviour that REPLACED it, plus
  # the two protections kept precisely because the old address lost its veto.

  def mails
    ActionMailer::Base.deliveries
  end

  test "changing the email applies immediately" do
    user = create_user(email: "old@example.com")
    sign_in user

    patch "/profile", params: { profile: { email: "new@example.com" } }

    assert_response :redirect
    assert_equal "new@example.com", user.reload.email
  end

  # OPSEC-046, and it carries more weight now than it did behind a confirm step:
  # with no veto, this mail is the only way a change nobody made becomes visible
  # to the person losing the account.
  test "the OLD address is told the change happened" do
    user = create_user(email: "old@example.com")
    sign_in user
    mails.clear

    patch "/profile", params: { profile: { email: "new@example.com" } }

    assert_equal 1, mails.size
    assert_equal ["old@example.com"], mails.last.to,
      "the heads-up goes where the person losing the account can see it"
  end

  # OPSEC-045. A hijacker holding a second cookie loses it the moment the address
  # moves — which is the other half of what replaced the confirmation step.
  # OPSEC-045, asserted as ACCESS rather than as a column value. Checking only
  # that session_token changed proves the write happened, not that anybody was
  # actually locked out — and with verify_session_token now wired into this
  # dummy, the second half is finally testable.
  test "changing the email locks out a session holding the old cookie" do
    user = create_user(email: "old@example.com")
    sign_in user

    # A SECOND session for the same account — the hijacker's, in the shape this
    # protects against. It captures the token that is live right now.
    hijacker = ActionDispatch::Integration::Session.new(Rails.application)
    hijacker.post "/test_sign_in/#{user.id}"
    hijacker.get "/profile"
    assert_equal 200, hijacker.response.status, "the second session starts out working"

    patch "/profile", params: { profile: { email: "new@example.com" } }

    hijacker.get "/profile"
    assert_equal 302, hijacker.response.status,
      "a session holding the pre-change cookie must lose ACCESS, not merely hold a stale string"
  end

  # ...but NOT the session that made the change. Rotating without re-establishing
  # would sign out the very person who just did it — correct when the actor
  # arrived from a confirmation link, wrong now that the actor is the session.
  # THE ORDER of the two side effects, which is invisible on the happy path: mail
  # first or rotate first, a successful change looks identical either way. It
  # stops looking identical the moment the mailer throws — SMTP down, a bad
  # template, an outbox adapter refusing the write. Mailing first means that
  # throw lands BETWEEN the address changing and the sessions closing, leaving
  # the account moved with the hijacker's cookie still live: precisely the window
  # OPSEC-045 exists to shut. So the rotation goes first, and this is the test
  # that notices if someone reorders them back.
  test "a mail failure still leaves the other sessions locked out" do
    user = create_user(email: "old@example.com")
    sign_in user

    hijacker = ActionDispatch::Integration::Session.new(Rails.application)
    hijacker.post "/test_sign_in/#{user.id}"
    hijacker.get "/profile"
    assert_equal 200, hijacker.response.status, "the second session starts out working"

    # Hand-rolled rather than Minitest's `stub`: minitest/mock is not in this
    # gem's bundle, and one singleton swap is cheaper than a new dependency.
    Studio::Email.singleton_class.send(:alias_method, :deliver_without_failure, :deliver)
    Studio::Email.define_singleton_method(:deliver) { |*, **| raise "SMTP is down" }
    begin
      # rescue_and_log re-raises outside production, so the failure surfaces here
      # rather than being swallowed — which is the honest shape of the incident.
      assert_raises(RuntimeError) do
        patch "/profile", params: { profile: { email: "new@example.com" } }
      end
    ensure
      Studio::Email.singleton_class.send(:alias_method, :deliver, :deliver_without_failure)
      Studio::Email.singleton_class.send(:remove_method, :deliver_without_failure)
    end

    assert_equal "new@example.com", user.reload.email, "the change itself still landed"
    hijacker.get "/profile"
    assert_equal 302, hijacker.response.status,
      "the rotation must land BEFORE anything that can throw — a mailer failure " \
      "must not leave the address moved with other sessions still holding access"
  end

  test "the session that made the change survives it" do
    user = create_user(email: "old@example.com")
    sign_in user
    patch "/profile", params: { profile: { email: "new@example.com" } }

    get "/profile"

    assert_response :success, "the person who changed their email must not be logged out"
  end

  # --- the Google exception ---------------------------------------------------
  #
  # Google is the authoritative source for a linked account's address. Letting
  # the two drift means the next OAuth sign-in either re-links to a stranger's
  # row or cannot find its own.

  test "an account linked to Google cannot change its email" do
    user = create_user(email: "old@example.com", provider: "google_oauth2", uid: "123")
    sign_in user

    patch "/profile", params: { profile: { email: "new@example.com" } }

    assert_response :see_other
    assert_equal "old@example.com", user.reload.email
  end

  # The row disables the field and explains why. A disabled input is a courtesy —
  # anyone can POST — so the endpoint refuses on its own.
  test "the google refusal does not depend on the page having been rendered" do
    user = create_user(email: "old@example.com", provider: "google_oauth2", uid: "123")
    sign_in user

    patch "/profile", params: { profile: { email: "new@example.com" } }

    assert_equal "old@example.com", user.reload.email
  end

  test "unlinking google frees the email to be changed" do
    user = create_user(email: "old@example.com", provider: "google_oauth2", uid: "123")
    sign_in user

    delete "/profile/google"
    patch "/profile", params: { profile: { email: "new@example.com" } }

    assert_equal "new@example.com", user.reload.email
  end

  # --- the ordinary refusals --------------------------------------------------

  test "a first email applies with no prior address to notify" do
    user = create_user(email: nil)
    sign_in user
    mails.clear

    patch "/profile", params: { profile: { email: "first@example.com" } }

    assert_equal "first@example.com", user.reload.email
    assert_empty mails, "there is no old address to warn"
  end

  test "resubmitting the address you already have is a no-op" do
    user = create_user(email: "old@example.com")
    sign_in user
    mails.clear

    patch "/profile", params: { profile: { email: "OLD@example.com", first_name: "Ada" } }

    assert_equal "old@example.com", user.reload.email
    assert_empty mails, "no mail for a no-op — and no session churn either"
  end

  # In a BULK form a blank field means "I did not change this", not "clear it" —
  # so a blank email contributes nothing rather than refusing the whole save.
  test "a blank address contributes nothing and leaves the old one" do
    user = create_user(email: "old@example.com")
    sign_in user

    patch "/profile", params: { profile: { email: "  ", first_name: "Ada" } }

    assert_equal "old@example.com", user.reload.email
    assert_equal "Ada", user.first_name, "the rest of the form still saves"
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

# --- the newsletter row's writes, DISPATCHED ----------------------------------
#
# The card's states are asserted in the view suite; these are the two WRITES, put
# through the real router and the real database. The interesting properties are
# both about what the columns end up holding, which no markup test can see.
class ProfileNewsletterRequestsTest < ProfileRequestsTest
  test "subscribing puts the account on the list" do
    user = create_user
    sign_in user

    post "/profile/newsletter"

    assert_response :redirect
    assert Studio::Newsletter.subscribed?(user.reload)
  end

  # The leave date is CLEARED on a rejoin. `subscribed?` compares the two dates,
  # so a stale leave date sitting after the new join would read as unsubscribed
  # the moment the clock disagreed.
  test "rejoining clears the old leave date" do
    user = create_user(joined_email_list_at: 3.days.ago, left_email_list_at: 2.days.ago)
    sign_in user
    refute Studio::Newsletter.subscribed?(user)

    post "/profile/newsletter"

    user.reload
    assert_nil user.left_email_list_at, "a stale leave date would fight the new join"
    assert Studio::Newsletter.subscribed?(user)
  end

  # THE ONE THAT MATTERS FOR A CONSUMER PAYING A ONCE-EVER BONUS. Leaving stamps
  # a date; it must never clear the join, or cycling would let someone re-earn a
  # welcome bonus turf-monster guards on-chain precisely to pay once.
  test "unsubscribing keeps the fact that they ever joined" do
    joined = 3.days.ago.change(usec: 0)
    user = create_user(joined_email_list_at: joined)
    sign_in user

    delete "/profile/newsletter"

    user.reload
    refute Studio::Newsletter.subscribed?(user)
    assert Studio::Newsletter.ever_joined?(user)
    assert_equal joined, user.joined_email_list_at, "the join date must survive the leave"
  end

  test "unsubscribing when not subscribed is refused rather than stamped" do
    user = create_user
    sign_in user

    delete "/profile/newsletter"

    assert_response :redirect
    assert_nil user.reload.left_email_list_at,
               "stamping a leave date for someone who never joined invents history"
  end

  # An account with no address supplies one in the same request. It is written as
  # the account email but must NOT be treated as verified — this proves someone
  # can type an address, not that they hold it.
  test "an account with no email supplies one while subscribing" do
    user = create_user(email: nil)
    sign_in user

    post "/profile/newsletter", params: { profile: { email: "new@example.com" } }

    user.reload
    assert_equal "new@example.com", user.email
    assert Studio::Newsletter.subscribed?(user)
  end

  test "a junk address is refused rather than saved" do
    user = create_user(email: nil)
    sign_in user

    post "/profile/newsletter", params: { profile: { email: "not-an-email" } }

    user.reload
    assert_nil user.email
    refute Studio::Newsletter.subscribed?(user), "no address, no subscription"
  end
end

# --- the host callback -------------------------------------------------------
#
# The seam that lets a consumer react to a newsletter change without the engine
# knowing what it does. It exists because turf-monster pays a once-ever welcome
# bonus gated on `joined_email_list_at.nil?`, and before this the engine set that
# column and told nobody — so a subscribe from /profile granted nothing AND made
# the bonus unclaimable forever.
class ProfileNewsletterCallbackTest < ProfileRequestsTest
  def with_callback
    calls = []
    Studio.after_newsletter_change = lambda do |user, subscribed:, first_join:|
      calls << { id: user.id, subscribed: subscribed, first_join: first_join }
    end
    yield calls
  ensure
    Studio.after_newsletter_change = ->(_user, subscribed:, first_join:) {}
  end

  test "a first-ever join reports first_join" do
    user = create_user
    sign_in user

    with_callback do |calls|
      post "/profile/newsletter"

      assert_equal 1, calls.length
      assert_equal user.id, calls.first[:id]
      assert calls.first[:subscribed]
      assert calls.first[:first_join], "the first join is what a once-ever bonus pays on"
    end
  end

  # THE ORDERING THAT MAKES first_join MEAN ANYTHING. It is computed BEFORE the
  # write, because the write is what sets the column — asked afterwards it would
  # always be false and no host could ever pay a welcome bonus.
  test "a REJOIN does not report first_join" do
    user = create_user(joined_email_list_at: 3.days.ago, left_email_list_at: 2.days.ago)
    sign_in user

    with_callback do |calls|
      post "/profile/newsletter"

      assert calls.first[:subscribed]
      refute calls.first[:first_join],
             "this account has joined before — paying again is the bug the on-chain guard exists to stop"
    end
  end

  test "leaving reports subscribed false" do
    user = create_user(joined_email_list_at: 2.days.ago)
    sign_in user

    with_callback do |calls|
      delete "/profile/newsletter"

      assert_equal 1, calls.length
      refute calls.first[:subscribed]
    end
  end

  # THE SUBSCRIPTION IS THE DURABLE FACT, the reaction is not. turf's callback
  # grants seeds on-chain over RPC to a node that is sometimes unreachable; a
  # failed bonus must not cost someone their place on the mailing list, and must
  # not roll the write back inside rescue_and_log.
  test "a raising callback cannot undo the subscription" do
    user = create_user
    sign_in user

    Studio.after_newsletter_change = ->(_user, subscribed:, first_join:) { raise "chain unreachable" }

    post "/profile/newsletter"

    assert_response :redirect
    assert Studio::Newsletter.subscribed?(user.reload),
           "the callback blew up and took the subscription with it"
  ensure
    Studio.after_newsletter_change = ->(_user, subscribed:, first_join:) {}
  end

  # A host that never configures one must not pay for the seam existing.
  test "the default callback is inert" do
    user = create_user
    sign_in user

    post "/profile/newsletter"

    assert_response :redirect
    assert Studio::Newsletter.subscribed?(user.reload)
  end
end
