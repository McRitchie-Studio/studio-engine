# frozen_string_literal: true

require "test_helper"
require "json"

# [unit] Studio::SessionState — the session's state as a page is stamped with it
# (docs/SESSION_DRIFT.md). Every field the browser store reads is pinned here.
class SessionStateTest < Minitest::Test
  SECRET = "session-state-test-secret"

  Account = Struct.new(:id, :session_token, keyword_init: true)

  def setup
    Studio.session_fingerprint_secret = SECRET
  end

  def teardown
    Studio.session_fingerprint_secret = nil
  end

  def test_states_list_the_whole_lifecycle_and_the_server_reports_two
    assert_equal %i[anonymous authenticated stale changed rehydrated signed_out], Studio::SessionState::STATES
    assert_equal %i[anonymous authenticated], Studio::SessionState::SERVER_STATES
    assert (Studio::SessionState::SERVER_STATES - Studio::SessionState::STATES).empty?
  end

  def test_anonymous_is_a_first_class_state
    state = Studio::SessionState.new(nil)

    assert_equal :anonymous, state.state
    assert state.anonymous?
    refute state.authenticated?
    assert_equal "anonymous", state.fingerprint
  end

  def test_authenticated_state
    account = Account.new(id: 5, session_token: "t")
    state = Studio::SessionState.new(account)

    assert_equal :authenticated, state.state
    assert state.authenticated?
    refute state.anonymous?
    assert_equal Studio::SessionFingerprint.for(account), state.fingerprint
  end

  def test_stamp_shape_for_an_anonymous_page
    issued = Time.at(1_700_000_000, 123, :millisecond)
    stamp = Studio::SessionState.new(nil).to_stamp(issued_at: issued)

    assert_equal(
      { v: 1, state: "anonymous", fingerprint: "anonymous", issuedAt: 1_700_000_000_123,
        expiresAt: nil, rehydrateUrl: nil, identities: {} },
      stamp
    )
  end

  def test_stamp_shape_for_a_signed_in_page_with_a_bound_identity
    account = Account.new(id: 5, session_token: "t")
    issued = Time.at(1_700_000_000)
    stamp = Studio::SessionState.new(account).to_stamp(
      rehydrate_url: "/session/state",
      expires_at: issued + 3600,
      identities: { device: "d-1", empty: "", none: nil },
      issued_at: issued
    )

    assert_equal "authenticated", stamp[:state]
    assert_equal 1_700_000_000_000, stamp[:issuedAt]
    assert_equal 1_700_003_600_000, stamp[:expiresAt]
    assert_equal "/session/state", stamp[:rehydrateUrl]
    assert_equal({ "device" => "d-1" }, stamp[:identities], "keys stringified, blank bindings dropped")
    assert_equal Studio::SessionFingerprint.for(account, identities: { "device" => "d-1" }), stamp[:fingerprint],
                 "the stamp's fingerprint covers the identities it carries"
    refute_equal Studio::SessionState.new(account).fingerprint, stamp[:fingerprint]
  end

  def test_a_blank_rehydrate_url_is_nil
    assert_nil Studio::SessionState.new(nil).to_stamp(rehydrate_url: "")[:rehydrateUrl]
  end

  def test_stamp_round_trips_through_json_with_camel_case_keys
    parsed = JSON.parse(Studio::SessionState.new(nil).to_stamp.to_json)
    assert_equal %w[v state fingerprint issuedAt expiresAt rehydrateUrl identities], parsed.keys
  end
end
