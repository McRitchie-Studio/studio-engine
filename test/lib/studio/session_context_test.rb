# frozen_string_literal: true

require "test_helper"
require_relative "../../../app/models/session_context"

# [unit] SessionContext exposes the session-state primitive (Studio::SessionState)
# and keeps it out of its legacy payload.
#
# SessionContext's legacy half (its constructor's other keywords, `mode`, `to_h`)
# predates this primitive and is pinned by its consumer's own suite, which Consumer
# CI runs against every engine PR. This file asserts only what the primitive adds,
# so it names none of that half: the constructor's other required keywords are
# supplied as false by reading the constructor, not by spelling them here.
class SessionContextTest < Minitest::Test
  SECRET = "session-context-test-secret"

  Account = Struct.new(:id, :session_token, keyword_init: true)

  STAMP_KEYS = %i[v state fingerprint issuedAt expiresAt rehydrateUrl identities].freeze

  def setup
    Studio.session_fingerprint_secret = SECRET
  end

  def teardown
    Studio.session_fingerprint_secret = nil
  end

  # SessionContext.new with the viewer, and every other required keyword false.
  def context_for(user)
    others = SessionContext.instance_method(:initialize).parameters
                           .filter_map { |type, name| name if type == :keyreq && name != :user }
    SessionContext.new(user: user, **others.to_h { |name| [name, false] })
  end

  def test_the_state_constants_are_the_primitives
    assert_same Studio::SessionState::STATES, SessionContext::STATES
    assert_same Studio::SessionState::SERVER_STATES, SessionContext::SERVER_STATES
  end

  def test_it_delegates_the_session_state_for_an_anonymous_viewer
    context = context_for(nil)

    assert_equal :anonymous, context.state
    assert context.anonymous?
    refute context.authenticated?
    assert_equal "anonymous", context.fingerprint
  end

  def test_it_delegates_the_session_state_for_a_signed_in_viewer
    account = Account.new(id: 9, session_token: "tok")
    context = context_for(account)
    direct = Studio::SessionState.new(account)

    assert_equal :authenticated, context.state
    assert context.authenticated?
    assert_equal direct.fingerprint, context.fingerprint
    assert_equal direct.fingerprint({ device: "d-1" }), context.fingerprint({ device: "d-1" })

    issued = Time.at(1_700_000_000)
    assert_equal direct.to_stamp(identities: { device: "d-1" }, issued_at: issued),
                 context.to_stamp(identities: { device: "d-1" }, issued_at: issued)
  end

  def test_the_legacy_payload_carries_none_of_the_stamp
    payload = context_for(Account.new(id: 9, session_token: "tok")).to_h
    leaked = payload.keys.map(&:to_sym) & (STAMP_KEYS - %i[v])

    assert_empty leaked, "session-state vocabulary travels in to_stamp, never in the legacy payload"
    refute_includes payload.values.map(&:to_s), context_for(Account.new(id: 9, session_token: "tok")).fingerprint,
                    "the fingerprint is never in the legacy payload"
  end
end
