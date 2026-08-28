# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [unit] The Phantom MOBILE deep link, promoted out of turf-monster.
#
# The dangerous property of this flow is that a stubbed wallet hides almost
# every way it can break: the two halves would agree with each other and
# disagree with nothing. So these tests pin the things a stub cannot — that the
# signed statement is identical on both sides, that the parts the SERVER
# verifies were not made configurable, and that the partial carries its own
# dependencies.
class PhantomDeeplinkTest < ActiveSupport::TestCase
  def setup
    @previous_app_name = Studio.app_name
  end

  def teardown
    Studio.app_name = @previous_app_name
  end

  # --- the statement ------------------------------------------------------

  def test_the_statement_reproduces_turf_monsters_literal_byte_for_byte
    # THE WHOLE PROMOTION RESTS ON THIS. turf-monster signed the literal
    # 'Sign in to Turf Monster' before this moved into the engine. If deriving
    # it from app_name changes even one byte, every mobile sign-in on that app
    # signs a different message than it used to.
    Studio.app_name = "Turf Monster"

    assert_equal "Sign in to Turf Monster", Studio.wallet_sign_in_statement
  end

  def test_a_consumer_with_no_wallet_history_still_gets_a_sensible_statement
    Studio.app_name = "McRitchie Studio"

    assert_equal "Sign in to McRitchie Studio", Studio.wallet_sign_in_statement
  end

  def test_the_deeplink_and_the_callback_emit_the_SAME_statement
    # They cannot be allowed to drift. The callback REBUILDS the signed message
    # to post for verification, so a mismatch fails every mobile sign-in — and
    # fails it server-side, long after the user left for Phantom and came back.
    # Asserted by extracting both emitted strings, not by trusting that both
    # files reference the same helper.
    Studio.app_name = "Drift Probe"

    assert_equal statement_in(render_deeplink), statement_in(render_callback),
                 "the deep link and its callback must sign the same statement"
    assert_equal "Sign in to Drift Probe", statement_in(render_deeplink)
  end

  # --- what the SERVER verifies, and therefore must not be configurable ----

  def test_the_domain_still_comes_from_the_live_host
    # OPSEC-018: Solana::SessionAuth checks the signed domain against
    # request.host_with_port. An app-supplied domain breaks sign-in.
    assert_includes render_deeplink, "domain: window.location.host"
  end

  def test_the_user_id_binding_keeps_its_exact_shape
    # OPSEC-005 does a SUBSTRING match on "User-ID: #{id}". Reformatting or
    # translating this line silently disables the binding — the signature still
    # verifies, it just is not bound to the session any more.
    assert_includes render_deeplink, %q{'\nUser-ID: ' + currentUserId}
  end

  def test_the_nonce_is_fetched_not_generated_client_side
    assert_includes render_deeplink, "fetch('/auth/solana/nonce')"
  end

  # --- dependencies -------------------------------------------------------

  def test_the_partial_carries_its_own_base58
    # turf-monster took encodeBase58 from a SEPARATE app/javascript/base58.js
    # that assigned a global. Promoting only the deep link would leave it
    # undefined in any consumer without that file, and it throws on the first
    # keypair encode — at the moment the user taps Connect.
    html = render_deeplink

    assert_includes html, "function encodeBase58"
    assert_includes html, "window.startPhantomDeepLink = startPhantomDeepLink"
  end

  def test_the_assets_partial_does_not_clobber_an_existing_nacl
    # turf-monster already loads tweetnacl from its own layout. Loading a second
    # copy there would be a silent duplicate; the guard is what makes this
    # partial safe to render in both apps.
    assert_includes render_assets, "typeof window.nacl === 'undefined'"
  end

  # --- the debug sink, which leaks a signing key -------------------------

  def test_the_debug_sink_is_off_by_default
    # It printed the dapp x25519 SECRET KEY to the page and the console on every
    # mobile sign-in. Defaulting it on and switching it off per environment is
    # how it reaches production once. Fail closed.
    refute Studio.wallet_debug_sink?
    # The DIV, not the id: the script always references the id (that reference
    # IS the off switch — an absent element makes DEBUG_SINK false). Asserting
    # the bare id would fail with the sink correctly off.
    refute_includes render_callback, %(id="phantom-log")
  end

  def test_an_app_can_opt_the_sink_back_on
    previous = Studio.wallet_debug_sink
    Studio.wallet_debug_sink = -> { true }

    assert_includes render_callback, %(id="phantom-log")
  ensure
    Studio.wallet_debug_sink = previous
  end

  def test_the_callback_is_null_safe_when_the_sink_is_absent
    # The script treats a missing sink as "debug off". If dbg() touched the
    # element unguarded, turning the sink off would throw and break sign-in
    # outright — the failure would land only in real production.
    assert_includes render_callback, "DEBUG_SINK"
  end

  private

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end

  def render_deeplink = view.render(partial: "studio/solana/phantom_deeplink")
  def render_assets   = view.render(partial: "studio/solana/deeplink_assets")
  def render_callback = view.render(template: "solana_sessions/phantom_callback")

  # The emitted string, from the rendered output — not the ERB source.
  def statement_in(html)
    html[/statement(?:Line)?\s*=\s*"([^"]*)"/, 1] ||
      html[/STATEMENT\s*=\s*"([^"]*)"/, 1]
  end
end
