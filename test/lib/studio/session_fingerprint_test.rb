# frozen_string_literal: true

require "test_helper"

# [unit] Studio::SessionFingerprint — the opaque name a page carries for the
# session that rendered it (docs/SESSION_DRIFT.md).
#
# Every property the browser store relies on is asserted here, because the store
# only ever compares two fingerprints for equality: if one of these breaks, the
# store does not error, it silently reports the wrong drift.
class SessionFingerprintTest < Minitest::Test
  SECRET = "a-test-secret-that-is-not-real"

  Account = Struct.new(:id, :session_token)
  TokenlessAccount = Struct.new(:id)

  def teardown
    Studio.session_fingerprint_secret = nil
  end

  def fingerprint(user, identities: {}, secret: SECRET)
    Studio::SessionFingerprint.for(user, identities: identities, secret: secret)
  end

  def test_anonymous_is_a_readable_constant_that_every_signed_out_tab_shares
    assert_equal "anonymous", Studio::SessionFingerprint::ANONYMOUS
    assert_equal "anonymous", fingerprint(nil)
    assert_equal "anonymous", fingerprint(nil, secret: nil), "anonymous needs no secret at all"
    assert_equal "anonymous", fingerprint(nil, identities: { "acct" => "" }), "a blank binding is no binding"
  end

  def test_a_signed_in_fingerprint_is_short_hex_and_stable
    user = Account.new(42, "tok-1")
    value = fingerprint(user)

    assert_match(/\A[0-9a-f]{32}\z/, value)
    assert_equal value, fingerprint(Account.new(42, "tok-1")), "the same session always yields the same fingerprint"
  end

  def test_different_accounts_differ
    refute_equal fingerprint(Account.new(1, "tok")), fingerprint(Account.new(2, "tok"))
  end

  def test_rotating_the_session_token_changes_it_so_revocation_is_visible
    refute_equal fingerprint(Account.new(42, "tok-1")), fingerprint(Account.new(42, "tok-2"))
  end

  def test_a_host_without_a_session_token_still_gets_a_per_account_fingerprint
    value = fingerprint(TokenlessAccount.new(7))
    assert_match(/\A[0-9a-f]{32}\z/, value)
    refute_equal value, fingerprint(TokenlessAccount.new(8))
  end

  def test_it_never_carries_the_id_or_the_token_readably
    value = fingerprint(Account.new(9_876_543, "super-secret-token"))
    refute_includes value, "9876543"
    refute_includes value, "super-secret-token"
  end

  def test_the_secret_keys_it
    user = Account.new(42, "tok-1")
    refute_equal fingerprint(user, secret: "one"), fingerprint(user, secret: "two"),
                 "without the app's secret nobody can recompute a fingerprint"
  end

  def test_bound_identities_are_part_of_it_in_any_order
    user = Account.new(42, "tok-1")
    plain = fingerprint(user)
    bound = fingerprint(user, identities: { "acct" => "id-1", "device" => "d-1" })

    refute_equal plain, bound, "binding an identity changes the fingerprint"
    refute_equal bound, fingerprint(user, identities: { "acct" => "id-2", "device" => "d-1" }),
                 "re-binding to another identity changes it again"
    assert_equal bound, fingerprint(user, identities: { device: "d-1", acct: "id-1" }),
                 "key order and symbol-vs-string keys do not matter"
    assert_equal plain, fingerprint(user, identities: { "acct" => nil }), "nil is not a binding"
  end

  def test_an_anonymous_session_with_a_binding_is_not_the_anonymous_constant
    value = fingerprint(nil, identities: { "acct" => "id-1" })
    refute_equal "anonymous", value
    assert_match(/\A[0-9a-f]{32}\z/, value)
  end

  def test_material_is_unambiguous_for_arbitrary_identity_text
    user = Account.new(1, "t")
    refute_equal fingerprint(user, identities: { "a" => "b=c" }), fingerprint(user, identities: { "a=b" => "c" }),
                 "no separator trick lets two different bindings share a fingerprint"
  end

  def test_the_id_and_token_are_encoded_as_strings_never_as_objects
    # A decorated or double user can hand back objects whose JSON encoding walks
    # (and can recurse through) their internals. The material must never ask.
    hostile = Object.new
    def hostile.to_json(*) = raise("encoded an object instead of its string")
    def hostile.to_s = "42"

    assert_equal fingerprint(Account.new(42, "tok")), fingerprint(Account.new(hostile, "tok"))
  end

  def test_the_explicit_secret_setting_is_used_when_no_secret_is_passed
    user = Account.new(42, "tok-1")
    Studio.session_fingerprint_secret = SECRET

    assert_equal fingerprint(user), Studio::SessionFingerprint.for(user)
  end

  def test_a_missing_secret_fails_loudly_rather_than_inventing_one
    # Outside a Rails application there is no secret_key_base to derive from.
    # A random per-process key would make every dyno disagree, so it raises.
    rails_app_present = defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
    refute rails_app_present, "this unit suite must run without a Rails application"

    error = assert_raises(Studio::SessionFingerprint::MissingSecret) do
      Studio::SessionFingerprint.for(Account.new(1, "t"))
    end
    assert_match(/session_fingerprint_secret/, error.message)
  end

  def test_digest_refuses_a_blank_secret
    assert_raises(Studio::SessionFingerprint::MissingSecret) { Studio::SessionFingerprint.digest("x", secret: "") }
  end
end
