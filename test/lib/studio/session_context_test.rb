# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../../app/models/session_context"

# [unit] SessionContext — the engine's own coverage of it. Until this file the
# only test of the engine's SessionContext lived in turf-monster
# (test/models/session_context_test.rb), so a change here was graded by a
# consumer's suite or not at all.
#
# Two halves, asserted separately because they have different contracts:
#   * the session-state half (state, fingerprint, to_stamp) is new and generic;
#   * the legacy mode half (mode, to_h) is FROZEN — consumers hydrate their own
#     client store from to_h, so its keys and values are pinned exactly.
class SessionContextTest < Minitest::Test
  SECRET = "session-context-test-secret"

  Account = Struct.new(:id, :session_token, keyword_init: true)

  class WalletAccount
    attr_reader :id, :session_token

    def initialize(id:, phantom:, solana_address:)
      @id = id
      @phantom = phantom
      @solana_address = solana_address
      @session_token = "tok"
    end

    def phantom_wallet? = @phantom
    def solana_address = @solana_address
  end

  def setup
    Studio.session_fingerprint_secret = SECRET
  end

  def teardown
    Studio.session_fingerprint_secret = nil
  end

  # ---- session state -------------------------------------------------------

  def test_states_list_the_whole_lifecycle_and_the_server_reports_two
    assert_equal %i[anonymous authenticated stale changed rehydrated signed_out], SessionContext::STATES
    assert_equal %i[anonymous authenticated], SessionContext::SERVER_STATES
    assert (SessionContext::SERVER_STATES - SessionContext::STATES).empty?
  end

  def test_anonymous_is_a_first_class_state
    context = SessionContext.new(user: nil)

    assert_equal :anonymous, context.state
    assert context.anonymous?
    refute context.authenticated?
    assert_equal "anonymous", context.fingerprint
  end

  def test_authenticated_state
    context = SessionContext.new(user: Account.new(id: 5, session_token: "t"))

    assert_equal :authenticated, context.state
    assert context.authenticated?
    refute context.anonymous?
    assert_equal Studio::SessionFingerprint.for(context.user), context.fingerprint
  end

  def test_onchain_session_is_optional
    assert_equal :web2, SessionContext.new(user: Account.new(id: 1, session_token: "t")).mode,
                 "a host with no second sign-in factor never has to name it"
  end

  def test_stamp_shape_for_an_anonymous_page
    issued = Time.at(1_700_000_000, 123, :millisecond)
    stamp = SessionContext.new(user: nil).to_stamp(issued_at: issued)

    assert_equal(
      { v: 1, state: "anonymous", fingerprint: "anonymous", issuedAt: 1_700_000_000_123,
        expiresAt: nil, rehydrateUrl: nil, identities: {} },
      stamp
    )
  end

  def test_stamp_shape_for_a_signed_in_page
    user = Account.new(id: 5, session_token: "t")
    issued = Time.at(1_700_000_000)
    stamp = SessionContext.new(user: user).to_stamp(
      rehydrate_url: "/session/state",
      expires_at: issued + 3600,
      identities: { acct: "id-1", empty: "", none: nil },
      issued_at: issued
    )

    assert_equal "authenticated", stamp[:state]
    assert_equal 1_700_000_000_000, stamp[:issuedAt]
    assert_equal 1_700_003_600_000, stamp[:expiresAt]
    assert_equal "/session/state", stamp[:rehydrateUrl]
    assert_equal({ "acct" => "id-1" }, stamp[:identities], "keys stringified, blank bindings dropped")
    assert_equal Studio::SessionFingerprint.for(user, identities: { "acct" => "id-1" }), stamp[:fingerprint],
                 "the stamp's fingerprint covers the identities it carries"
    refute_equal SessionContext.new(user: user).fingerprint, stamp[:fingerprint]
  end

  def test_a_blank_rehydrate_url_is_nil
    assert_nil SessionContext.new(user: nil).to_stamp(rehydrate_url: "")[:rehydrateUrl]
  end

  def test_stamp_round_trips_through_json_with_camel_case_keys
    parsed = JSON.parse(SessionContext.new(user: nil).to_stamp.to_json)
    assert_equal %w[v state fingerprint issuedAt expiresAt rehydrateUrl identities], parsed.keys
  end

  # ---- legacy mode (frozen) ------------------------------------------------

  def test_guest_payload_is_pinned
    context = SessionContext.new(user: nil, onchain_session: false)

    assert_equal :guest, context.mode
    assert context.guest?
    refute context.logged_in?
    assert_equal({ loggedIn: false, mode: :guest, phantomLinked: false, userId: nil, address: "" }, context.to_h)
    assert_equal context.to_h, context.as_json
  end

  def test_web2_payload_is_pinned
    user = WalletAccount.new(id: 3, phantom: true, solana_address: "addr-3")
    context = SessionContext.new(user: user, onchain_session: false)

    assert_equal :web2, context.mode
    assert context.web2?
    assert context.logged_in?
    assert_equal({ loggedIn: true, mode: :web2, phantomLinked: true, userId: 3, address: "addr-3" }, context.to_h)
  end

  def test_web3_payload_is_pinned
    user = WalletAccount.new(id: 4, phantom: false, solana_address: nil)
    context = SessionContext.new(user: user, onchain_session: true)

    assert_equal :web3, context.mode
    assert context.web3?
    assert_equal({ loggedIn: true, mode: :web3, phantomLinked: false, userId: 4, address: "" }, context.to_h)
  end

  def test_to_h_never_grows_the_session_state_keys
    keys = SessionContext.new(user: Account.new(id: 1, session_token: "t")).to_h.keys
    assert_equal %i[loggedIn mode phantomLinked userId address], keys,
                 "session-state vocabulary travels in to_stamp, never in the frozen host payload"
  end
end
