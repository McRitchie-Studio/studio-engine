# frozen_string_literal: true

require "test_helper"
require "studio/link_token"

class StudioLinkTokenTest < Minitest::Test
  def test_generate_is_url_safe_and_short
    token = Studio::LinkToken.generate
    assert_match(/\A[A-Za-z0-9_-]+\z/, token, "token must be URL-safe (no /, +, =)")
    # 12 bytes base64-encodes to 16 chars; urlsafe_base64 drops padding.
    assert_equal 16, token.length
  end

  def test_generate_is_unique_across_calls
    tokens = Array.new(200) { Studio::LinkToken.generate }
    assert_equal tokens.length, tokens.uniq.length, "tokens must not collide"
  end

  def test_token_bytes_is_96_bits
    assert_equal 12, Studio::LinkToken::TOKEN_BYTES
  end

  # The house standard the operator set: a magic-link token is 10-20 URL-safe
  # characters, so the whole link fits on one line. Asserted against real mints
  # (not just the constants) and over enough of them to catch a generator whose
  # width varies — the old MessageVerifier blob ran to ~350 characters and grew
  # with its payload, which is the failure this bound exists to forbid.
  def test_every_minted_token_sits_inside_the_house_length_bound
    lengths = Array.new(200) { Studio::LinkToken.generate }.map do |token|
      assert_match Studio::LinkToken::TOKEN_FORMAT, token, "token must be URL-safe"
      token.length
    end

    assert_equal [Studio::LinkToken::TOKEN_LENGTH], lengths.uniq,
                 "every token must be exactly #{Studio::LinkToken::TOKEN_LENGTH} characters — " \
                 "a varying width means the payload rides in the token again"
    assert_includes Studio::LinkToken::TOKEN_LENGTH_BOUNDS, Studio::LinkToken::TOKEN_LENGTH,
                    "the standard must stay inside the 10-20 character house bound"
  end

  def test_kinds
    assert_equal %w[magic_link referral], Studio::LinkToken::KINDS
    assert Studio::LinkToken.kind?("magic_link")
    assert Studio::LinkToken.kind?(:referral)
    refute Studio::LinkToken.kind?("nonsense")
    refute Studio::LinkToken.kind?(nil)
  end

  def test_single_use_only_for_magic_link
    assert Studio::LinkToken.single_use?("magic_link")
    assert Studio::LinkToken.single_use?(:magic_link)
    refute Studio::LinkToken.single_use?("referral")
    refute Studio::LinkToken.single_use?(nil)
  end

  def test_normalize_email_strips_and_downcases
    assert_equal "user@example.com", Studio::LinkToken.normalize_email("  USER@Example.com  ")
    assert_equal "", Studio::LinkToken.normalize_email(nil)
  end

  def test_sanitize_path_allows_same_origin_absolute_paths
    assert_equal "/contests/world-cup", Studio::LinkToken.sanitize_path("/contests/world-cup")
    assert_equal "/", Studio::LinkToken.sanitize_path("/")
  end

  def test_sanitize_path_rejects_offsite_and_relative
    assert_nil Studio::LinkToken.sanitize_path("//evil.example.com")
    assert_nil Studio::LinkToken.sanitize_path("https://evil.example.com")
    assert_nil Studio::LinkToken.sanitize_path("contests/world-cup")
    assert_nil Studio::LinkToken.sanitize_path("")
    assert_nil Studio::LinkToken.sanitize_path(nil)
  end
end
