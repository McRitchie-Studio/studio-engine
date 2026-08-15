# frozen_string_literal: true

require "base64"

module Studio
  # The signed, expiring token that authorizes an email change.
  #
  # It is the auth boundary for the confirm link: the link may be opened on a
  # different device than the logged-in session (it is sent to the person's
  # OLD inbox), so the session cannot be what proves the request. The token is.
  #
  # URL-SAFE BASE64 — as a GUARANTEE, not as a bug fix. Read this before
  # "simplifying" it away, and read it before repeating the claim I first made
  # about it.
  #
  # The confirm link carries the token in a PATH SEGMENT under
  # `constraints: { token: %r{[^/]+} }`. A token containing `/` would make
  # `url_for` raise `ActionController::UrlGenerationError` INSIDE THE MAILER,
  # which means the email is never sent at all — no broken link, no link.
  #
  # I lifted this wrapper from a real 2026-05-31 incident on the magic link and
  # asserted turf-monster's unwrapped email-change token was the same bug waiting
  # for a long enough address. **MEASURED 2026-08-14, THAT IS NOT TRUE HERE.**
  # `ActiveSupport::MessageVerifier#generate` on this Rails already returns
  # url-safe output, so standard-base64-wrapping it produced `/` or `+` in ZERO
  # of 120 payload lengths, and none for UTF-8 accented or CJK addresses either.
  # The wrapping is therefore NOT closing a reproducing bug in this shape.
  #
  # It stays because it converts an implementation detail of a dependency into a
  # property of this file. Without it the route constraint holds only for as long
  # as MessageVerifier keeps choosing a url-safe alphabet — a choice it is free to
  # revisit, in a failure mode that surfaces as "the email never arrived" rather
  # than as an exception anyone sees. One call each way is a cheap price for not
  # depending on that.
  #
  # What this does NOT buy is a test that bites: an encoding that is already safe
  # cannot be caught failing. The suite asserts the alphabet as an invariant and
  # says so plainly rather than pretending to guard a regression.
  #
  # The verifier is INJECTABLE so the rules can be unit-tested without booting
  # Rails; hosts never pass it.
  module EmailChangeToken
    PURPOSE = "studio_email_change_v1"

    # Half an hour. Long enough to walk to another device and open the mail,
    # short enough that a link left in an inbox stops being a key.
    TTL = 1800 # seconds

    module_function

    def generate(user_id:, current_email:, new_email:, verifier: default_verifier, ttl: TTL)
      payload = {
        user_id: user_id,
        current_email: current_email.to_s,
        new_email: new_email.to_s,
        requested_at: Time.now.to_i
      }

      Base64.urlsafe_encode64(verifier.generate(payload, expires_in: ttl))
    end

    # Returns the payload with symbol keys, or raises
    # ActiveSupport::MessageVerifier::InvalidSignature.
    #
    # A malformed token raises the SAME error as a tampered one, deliberately:
    # the caller has one rescue and one message, and an attacker learns nothing
    # from the difference between "not base64" and "bad signature".
    def verify(token, verifier: default_verifier)
      raw = Base64.urlsafe_decode64(token.to_s)
      symbolize(verifier.verify(raw))
    rescue ArgumentError
      raise ActiveSupport::MessageVerifier::InvalidSignature
    end

    # Is the token still describing reality? A signed token says what was true
    # when it was minted; this asks whether it is still true NOW.
    #
    # Binding on the CURRENT email is what makes the link single-purpose: once
    # the address has moved — because this link was already used, or because a
    # newer change landed first — the old link is stale and must not apply. A
    # token that only proved "someone once asked for this" would stay usable
    # after the account had moved on.
    def fresh_for?(payload, user)
      return false if payload.nil? || user.nil?
      return false unless user.respond_to?(:email)

      user.email.to_s.downcase == payload[:current_email].to_s.downcase
    end

    def default_verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def symbolize(hash)
      hash.to_h.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
    end
  end
end
