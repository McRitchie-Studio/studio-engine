# frozen_string_literal: true

require "test_helper"
require "active_support/message_verifier"
require "studio/email_change_token"

# [unit] The email-change token — the auth boundary for the confirm link.
#
# The link is sent to the person's OLD inbox and may be opened on a different
# device than the logged-in session, so the session cannot be what proves the
# request. Everything that makes the token trustworthy is asserted here.
class EmailChangeTokenTest < Minitest::Test
  def verifier
    @verifier ||= ActiveSupport::MessageVerifier.new("a" * 64, digest: "SHA256", serializer: JSON)
  end

  def mint(user_id: 7, current_email: "old@example.com", new_email: "new@example.com", ttl: 1800)
    Studio::EmailChangeToken.generate(
      user_id: user_id, current_email: current_email, new_email: new_email,
      verifier: verifier, ttl: ttl
    )
  end

  def read(token)
    Studio::EmailChangeToken.verify(token, verifier: verifier)
  end

  # --- URL-safety: an INVARIANT, and honestly labelled ------------------------
  #
  # The token rides a PATH SEGMENT under `constraints: { token: %r{[^/]+} }`, so
  # a `/` in it would make url_for raise inside the mailer and the email would
  # never send.
  #
  # ⚠ THIS TEST DOES NOT BITE, AND THAT IS RECORDED ON PURPOSE. Swapping
  # `urlsafe_encode64` for plain `encode64` leaves it green: measured 2026-08-14,
  # MessageVerifier on this Rails already returns url-safe output, so standard
  # base64 over it produced `/` or `+` in ZERO of 120 payload lengths and none for
  # UTF-8 accented or CJK addresses. My original claim — that turf's unwrapped
  # token was the same bug that hit the magic link — was WRONG for this shape.
  #
  # So this asserts an invariant the code guarantees, not a regression it
  # prevents: it will catch a token format that stops being url-safe, whatever
  # the cause. Do not read it as proof the wrapper is load-bearing today, and do
  # not delete the wrapper on the grounds that this test still passes without it
  # — the wrapper is what makes the invariant ours instead of a dependency's.

  def test_a_token_uses_only_the_url_safe_alphabet
    token = mint(current_email: "#{"a" * 120}@really-quite-long-domain.example.com",
                 new_email: "#{"b" * 120}@another-long-domain.example.com")

    refute_includes token, "/", "a slash breaks the [^/]+ route constraint"
    refute_includes token, "+", "a plus is re-read as a space in a URL"
  end

  def test_the_alphabet_holds_for_non_ascii_addresses
    # Email addresses can be UTF-8. Encoded bytes for accented and CJK local
    # parts are the likeliest place for an alphabet surprise.
    %W[#{"é" * 60}@exämple.com #{"漢" * 40}@example.com].each do |address|
      refute_match(%r{[/+]}, mint(new_email: address), "non-ASCII address left the url-safe alphabet")
    end
  end

  def test_a_long_token_still_round_trips
    token = mint(new_email: "#{"x" * 200}@example.com")

    assert_equal "#{"x" * 200}@example.com", read(token)[:new_email]
  end

  def test_a_non_ascii_address_round_trips_intact
    token = mint(new_email: "pat.é@exämple.com")

    assert_equal "pat.é@exämple.com", read(token)[:new_email]
  end

  # --- the signature does its job ---------------------------------------------

  def test_a_token_round_trips_its_payload
    payload = read(mint)

    assert_equal 7, payload[:user_id]
    assert_equal "old@example.com", payload[:current_email]
    assert_equal "new@example.com", payload[:new_email]
    assert payload[:requested_at].is_a?(Integer)
  end

  def test_a_tampered_token_is_refused
    token = mint
    tampered = token.dup
    tampered[10] = (tampered[10] == "A" ? "B" : "A")

    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { read(tampered) }
  end

  # A malformed token raises the SAME error as a tampered one — one rescue, one
  # message, and nothing learned from the difference.
  def test_a_malformed_token_raises_the_same_error_as_a_tampered_one
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { read("not base64 at all!!") }
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { read("") }
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { read(nil) }
  end

  def test_a_token_signed_with_another_key_is_refused
    other = ActiveSupport::MessageVerifier.new("b" * 64, digest: "SHA256", serializer: JSON)
    token = Studio::EmailChangeToken.generate(
      user_id: 7, current_email: "old@example.com", new_email: "new@example.com", verifier: other
    )

    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { read(token) }
  end

  def test_an_expired_token_is_refused
    token = mint(ttl: -1)

    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { read(token) }
  end

  # --- freshness: the link is single-purpose ----------------------------------
  #
  # A signature only proves "someone once asked for this". Binding on the CURRENT
  # address is what stops a link being reusable after the account has moved on —
  # because this link was already used, or because a newer change landed first.

  Account = Struct.new(:email)

  def test_a_token_is_fresh_while_the_account_still_holds_the_old_address
    assert Studio::EmailChangeToken.fresh_for?(read(mint), Account.new("old@example.com"))
  end

  def test_a_token_goes_stale_once_the_address_has_moved
    refute Studio::EmailChangeToken.fresh_for?(read(mint), Account.new("new@example.com")),
      "a used link must not apply a second time"
    refute Studio::EmailChangeToken.fresh_for?(read(mint), Account.new("something-else@example.com")),
      "a newer change landing first makes this link stale"
  end

  def test_freshness_ignores_address_casing
    assert Studio::EmailChangeToken.fresh_for?(read(mint), Account.new("OLD@Example.COM"))
  end

  def test_freshness_is_false_rather_than_raising_on_a_missing_account
    refute Studio::EmailChangeToken.fresh_for?(read(mint), nil)
    refute Studio::EmailChangeToken.fresh_for?(nil, Account.new("old@example.com"))
    refute Studio::EmailChangeToken.fresh_for?(read(mint), Struct.new(:name).new("Pat"))
  end
end
