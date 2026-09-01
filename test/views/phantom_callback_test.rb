# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [unit] The Phantom MOBILE callback — the half of that flow the engine KEEPS.
#
# WHAT THIS FILE USED TO BE. It was phantom_deeplink_test.rb and it covered both
# halves: studio/solana/_phantom_deeplink (the tab that opens Phantom) and
# solana_sessions/phantom_callback (the page Phantom returns to). The
# two-template split moved the deep link to solana-studio — BASE is
# studio-engine + mcritchie-studio, WEB3 ADD is solana-studio + turf-monster —
# and the engine kept the SESSION half: this callback view, SolanaSessionsController,
# Solana::SessionAuth, /auth/solana/nonce, and Studio.wallet_sign_in_statement.
#
# The dangerous property of this flow is that a stubbed wallet hides almost every
# way it can break: the two halves would agree with each other and disagree with
# nothing. So these tests pin the things a stub cannot — the statement this side
# signs, and the parts the SERVER verifies that must not become configurable.
class PhantomCallbackTest < ActiveSupport::TestCase
  def setup
    @previous_app_name = Studio.app_name
  end

  def teardown
    Studio.app_name = @previous_app_name
  end

  # --- the statement, which this engine OWNS ------------------------------

  def test_the_statement_reproduces_turf_monsters_literal_byte_for_byte
    Studio.app_name = "Turf Monster"

    assert_equal "Sign in to Turf Monster", Studio.wallet_sign_in_statement
  end

  def test_a_consumer_with_no_wallet_history_still_gets_a_sensible_statement
    Studio.app_name = "McRitchie Studio"

    assert_equal "Sign in to McRitchie Studio", Studio.wallet_sign_in_statement
  end

  # --- the no-drift contract, now pinned STRUCTURALLY on each side ---------

  # THE GUARD THAT USED TO LIVE HERE COMPARED TWO RENDERS. It rendered the deep
  # link and this callback and asserted both emitted the same string. That test
  # cannot exist any more: after the split no single repo can render both halves.
  #
  # Replacing it with a comparison against a hard-coded literal would be worse
  # than nothing — it would pass while the OTHER side drifted, which is the exact
  # failure the original caught. So the property is pinned STRUCTURALLY from both
  # ends instead: each side asserts that IT reads the one shared accessor, and
  # neither side is allowed to take the statement as a parameter.
  #
  #   this file                        · the callback reads Studio.wallet_sign_in_statement
  #   solana-studio test/web3_modals_test.rb · the deep link reads the same accessor
  #
  # Two files, one accessor, and the accessor is the single source
  # (lib/studio.rb). DO NOT parameterise either side to reunite them: a
  # caller-supplied statement would decouple the gem from this engine, read as an
  # improvement, and silently break the signature check the moment a caller
  # passed anything.
  def test_the_callback_rebuilds_the_message_from_the_engine_statement_accessor
    # Anchored on the ERB OUTPUT TAG with comments stripped, not on a substring:
    # the accessor is named in this file's own prose and in the view's comments,
    # so a document-wide match would find the sentence describing the rule rather
    # than the line obeying it.
    assert_match(/<%=\s*Studio\.wallet_sign_in_statement\b[^%]*%>/, callback_source_without_comments,
                 "the callback no longer emits Studio.wallet_sign_in_statement in an ERB output tag. " \
                 "solana-studio's phantom_deeplink signs the statement from that same accessor; any " \
                 "other source for this string breaks verification for every mobile sign-in.")
  end

  def test_the_callback_takes_no_statement_local
    # The other half of the rule, asserted from the opposite side so that adding
    # a local ALONGSIDE the accessor is caught too. Mirrors the gem's
    # test_the_deep_link_takes_no_statement_local exactly.
    refute_match(/local_assigns\s*\[\s*:statement\s*\]|local_assigns\.fetch\(\s*:statement/,
                 callback_source_without_comments,
                 "the signed statement became caller-supplied — it must come from " \
                 "Studio.wallet_sign_in_statement so it cannot drift from the deep link")
  end

  def test_the_rebuilt_message_still_emits_the_live_statement
    # The structural pins above read the SOURCE. This one reads the RENDER, so a
    # tag that compiles to nothing (an escaped or mis-nested ERB tag emits an
    # empty string without raising) still fails here.
    Studio.app_name = "Drift Probe"

    assert_includes render_callback, "Sign in to Drift Probe"
  end

  # --- what the SERVER verifies, and therefore must not be configurable ----

  def test_the_domain_still_comes_from_the_live_host
    # OPSEC-018: Solana::SessionAuth checks the signed domain against
    # request.host_with_port. An app-supplied domain breaks sign-in. Asserted on
    # the callback because it REBUILDS the message it posts for verification.
    assert_includes render_callback, "var domain = window.location.host;"
  end

  def test_the_user_id_binding_keeps_its_exact_shape
    # OPSEC-005 does a SUBSTRING match on "User-ID: #{id}". Reformatting or
    # translating this line silently disables the binding — the signature still
    # verifies, it just is not bound to the session any more.
    assert_includes render_callback, %q{'\nUser-ID: ' + storedUserId}
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

  CALLBACK_PATH = File.expand_path(
    "../../app/views/solana_sessions/phantom_callback.html.erb", __dir__
  ).freeze

  # The view's ERB SOURCE with its ERB comments and JS comments removed.
  # Comments EXPLAIN the hazards using the very tokens being asserted on, so
  # scanning them makes documenting a rule impossible — the same reasoning as
  # mcritchie-studio's markup_of and the gem's code_of.
  def callback_source_without_comments
    File.read(CALLBACK_PATH)
        .gsub(/<%#.*?%>/m, " ")
        .gsub(%r{/\*.*?\*/}m, " ")
        .gsub(%r{//[^\n]*}, " ")
  end

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end

  def render_callback = view.render(template: "solana_sessions/phantom_callback")
end
