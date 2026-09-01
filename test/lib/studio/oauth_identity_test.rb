# frozen_string_literal: true

require "test_helper"

# [unit] Studio::OauthIdentity — is Google linked, and is it safe to unlink?
#
# THE ORPHAN GUARD IS THE POINT. turf-monster's unlink is an unconditional
# `update!(provider: nil, uid: nil)`. For an account whose only sign-in is Google
# that locks someone out of their own account behind a button labelled "Unlink" —
# and it is safe in turf today only because turf's users happen to carry an
# email, which is a property of that app's DATA, not of the code. The engine
# ships to apps whose data it has never seen, so it has to ask.
class OauthIdentityTest < Minitest::Test
  # RESTORE WHAT WE FOUND, never a literal. This teardown used to re-assign
  # `%i[magic_link google wallet]` — a copy of the engine default that went stale
  # the moment the web2/base split dropped :wallet from it (lib/studio.rb). The
  # damage was not one red test, it was TWO leaks at once:
  #
  #   * INTO the file — teardown runs AFTER each test, so the test Minitest
  #     happened to order FIRST saw the real default and every later test saw a
  #     :wallet the engine no longer ships. Any test here that leaned on the
  #     default passed or failed BY SEED.
  #   * OUT of the file — the last teardown left :wallet enabled process-wide for
  #     whatever ran next, so the suite lied to unrelated files about the fleet's
  #     shape.
  #
  # Capturing the live values in setup fixes both and cannot go stale again: the
  # next change to the default is restored correctly without touching this file.
  # Same idiom the engine already uses in AuthRouteGatingTest and
  # EngineLoginPasswordlessTest.
  #
  # This does NOT make the tests below default-agnostic on its own — a test whose
  # subject is an auth method has to STATE that premise itself. They now do.
  def setup
    @original_auth_methods = Studio.auth_methods
    @original_wallet_address_method = Studio.wallet_address_method
  end

  def teardown
    Studio.auth_methods = @original_auth_methods
    Studio.wallet_address_method = @original_wallet_address_method
  end

  def user(**attrs)
    defaults = { provider: nil, uid: nil, email: nil, password_digest: nil, solana_address: nil }
    Struct.new(*defaults.keys, keyword_init: true).new(**defaults.merge(attrs))
  end

  # --- is it linked? ----------------------------------------------------------

  # BOTH spellings occur: `google_oauth2` is the OmniAuth strategy name that
  # lands in users.provider; `google` is what Studio.auth_methods calls it.
  # Matching only one reports a genuinely linked account as unlinked, which
  # would offer "Link Google Account" to someone already linked.
  def test_both_google_provider_spellings_count_as_linked
    assert Studio::OauthIdentity.google_linked?(user(provider: "google_oauth2", uid: "123"))
    assert Studio::OauthIdentity.google_linked?(user(provider: "google", uid: "123"))
  end

  def test_a_provider_without_a_uid_is_not_linked
    refute Studio::OauthIdentity.google_linked?(user(provider: "google_oauth2", uid: nil))
    refute Studio::OauthIdentity.google_linked?(user(provider: "google_oauth2", uid: ""))
  end

  def test_another_provider_is_not_google
    refute Studio::OauthIdentity.google_linked?(user(provider: "github", uid: "123"))
  end

  def test_a_model_without_the_columns_is_not_linked_rather_than_raising
    # mcritchie-industries' users table has provider/uid, but a future consumer
    # may not. Reporting "not linked" beats a NoMethodError on every render.
    bare = Struct.new(:name).new("Pat")

    refute Studio::OauthIdentity.google_linked?(bare)
  end

  # --- would unlinking orphan the account? ------------------------------------

  # THE CASE THAT MATTERS. Google-only account: no email, no wallet, no password.
  def test_unlinking_a_google_only_account_orphans_it
    assert Studio::OauthIdentity.unlink_orphans_account?(user(provider: "google_oauth2", uid: "1"))
  end

  def test_an_email_keeps_the_account_reachable_when_magic_link_is_offered
    Studio.auth_methods = %i[magic_link google]
    subject = user(provider: "google_oauth2", uid: "1", email: "pat@example.com")

    refute Studio::OauthIdentity.unlink_orphans_account?(subject)
    assert_equal [:magic_link], Studio::OauthIdentity.remaining_sign_ins(subject)
  end

  # THE SUBTLE ONE, and the reason this gates on auth_methods rather than on the
  # column. An app can have an email column and NOT offer magic-link sign-in —
  # then the email is not a way back in, and counting it would be exactly the
  # wrong answer. mcritchie-industries offers only magic_link; an app offering
  # only :google is the shape this protects.
  def test_an_email_does_not_count_when_the_app_does_not_offer_magic_link
    Studio.auth_methods = %i[google]
    subject = user(provider: "google_oauth2", uid: "1", email: "pat@example.com")

    assert Studio::OauthIdentity.unlink_orphans_account?(subject),
      "an email is only a way back in if the app actually offers magic-link sign-in"
  end

  # STATES ITS OWN PREMISE — "when the app OFFERS wallet sign-in". :wallet is not
  # in the engine default (the base template is web2; a wallet app opts in, as
  # turf-monster does in config/initializers/studio.rb), so a test about wallets
  # has to turn wallets on. It previously inherited one from the stale teardown,
  # which made it pass or fail by seed.
  def test_a_wallet_keeps_the_account_reachable
    Studio.auth_methods = %i[magic_link google wallet]
    Studio.wallet_address_method = :solana_address
    subject = user(provider: "google_oauth2", uid: "1", solana_address: "7ZDJp7FU")

    refute Studio::OauthIdentity.unlink_orphans_account?(subject)
    assert_equal [:wallet], Studio::OauthIdentity.remaining_sign_ins(subject)
  end

  # NO CONVENTION FALLBACK, deliberately — and this test pins the safe direction.
  #
  # An earlier version guessed `:solana_address` when the host configured
  # nothing. turf-monster is the live counter-example: its `User#solana_address`
  # returns `web3 || web2`, and only the WEB3 address can sign in — the web2 one
  # is custodial, with no signer. Guessing that reader counts a custodial address
  # as a way back in and permits an unlink that ORPHANS the account.
  #
  # So an unconfigured app is treated as having no wallet sign-in. The cost is an
  # occasional refusal the operator fixes by configuring the column; the cost of
  # the other direction is someone locked out.
  #
  # THE PREMISE IS LOAD-BEARING FOR A REASON THE ASSERTION HIDES.
  # remaining_sign_ins short-circuits on `methods.include?(:wallet)` BEFORE it
  # ever calls wallet_present? (lib/studio/oauth_identity.rb:48), so with :wallet
  # absent this test passes WITHOUT EXECUTING the guard it exists to pin.
  # Verified by mutation: restoring the convention fallback
  # (`configured = :solana_address if configured.blank?`) left this test green
  # when it ran first, and killed it only once :wallet was offered. Offering
  # wallet sign-in is what makes the assertion bite.
  def test_an_unconfigured_wallet_column_is_not_guessed
    Studio.auth_methods = %i[magic_link google wallet]
    Studio.wallet_address_method = nil
    subject = user(provider: "google_oauth2", uid: "1", solana_address: "7ZDJp7FU")

    assert Studio::OauthIdentity.unlink_orphans_account?(subject),
      "guessing the wallet reader can count a non-signing address as a way back in"
  end

  def test_a_wallet_does_not_count_when_the_app_does_not_offer_wallet_sign_in
    Studio.auth_methods = %i[magic_link]
    Studio.wallet_address_method = :solana_address
    subject = user(provider: "google_oauth2", uid: "1", solana_address: "7ZDJp7FU")

    assert Studio::OauthIdentity.unlink_orphans_account?(subject)
  end

  # A DIGEST ALONE IS NOT A PASSWORD LOGIN, and this is the correction that
  # matters most. An earlier version counted any non-blank `password_digest`.
  # turf-monster REMOVED `has_secure_password` and kept the column, so its rows
  # carry fossil digests that no code can authenticate against — counting one is
  # a false positive in the dangerous direction, permitting an unlink that
  # orphans the account. The engine already ships the right composite predicate.
  def test_a_fossil_digest_is_not_a_way_back_in
    Studio.auth_methods = %i[google password]
    subject = user(provider: "google_oauth2", uid: "1", password_digest: "$2a$12$abc")

    # No ::User answering `authenticate` in this suite — exactly turf's shape
    # after it dropped has_secure_password.
    refute Studio.password_login_available?
    assert Studio::OauthIdentity.unlink_orphans_account?(subject),
      "a digest the app cannot authenticate against is not a sign-in"
  end

  def test_a_real_password_login_keeps_the_account_reachable
    Studio.auth_methods = %i[google password]
    subject = user(provider: "google_oauth2", uid: "1", password_digest: "$2a$12$abc")

    with_password_capable_user do
      refute Studio::OauthIdentity.unlink_orphans_account?(subject)
      assert_equal [:password], Studio::OauthIdentity.remaining_sign_ins(subject)
    end
  end

  def test_a_password_does_not_count_when_the_app_does_not_offer_it
    Studio.auth_methods = %i[google]
    subject = user(provider: "google_oauth2", uid: "1", password_digest: "$2a$12$abc")

    with_password_capable_user do
      assert Studio::OauthIdentity.unlink_orphans_account?(subject)
    end
  end

  # turf-monster's users.password_digest defaults to "" (not null), so a blank
  # digest must not read as "has a password" — that would defeat the guard for
  # every turf account that never set one.
  def test_a_blank_password_digest_is_not_a_password
    Studio.auth_methods = %i[google password]
    subject = user(provider: "google_oauth2", uid: "1", password_digest: "")

    with_password_capable_user do
      assert Studio::OauthIdentity.unlink_orphans_account?(subject)
    end
  end

  def test_every_remaining_method_is_reported_not_just_the_first
    Studio.auth_methods = %i[magic_link wallet password google]
    Studio.wallet_address_method = :solana_address
    subject = user(provider: "google_oauth2", uid: "1", email: "pat@example.com",
                   solana_address: "7ZDJ", password_digest: "$2a$12$abc")

    with_password_capable_user do
      assert_equal %i[magic_link wallet password], Studio::OauthIdentity.remaining_sign_ins(subject)
    end
  end

  # WAS INERT — defined below `private`, where Minitest#runnable_methods (which
  # reads PUBLIC instance methods) never saw it. The file reported 15 runnable
  # tests against 16 defined, and this one had never executed a single time.
  # A private `def test_*` does not error and does not skip; it is simply absent,
  # so the suite stays green whether the behaviour works or not.
  def test_a_bare_model_orphans_rather_than_raising
    assert Studio::OauthIdentity.unlink_orphans_account?(Struct.new(:name).new("Pat"))
  end

  private

  # Stands up the ::User constant Studio.user_supports_password? reads — a host
  # whose model still has has_secure_password. Removed afterwards so the default
  # state of this suite stays "no password login", which is the fleet's real
  # shape today.
  def with_password_capable_user
    Object.const_set(:User, Class.new { def authenticate(_) = false }) unless Object.const_defined?(:User)
    yield
  ensure
    Object.send(:remove_const, :User) if Object.const_defined?(:User)
  end
end
