# frozen_string_literal: true

require "json"
require "openssl"

module Studio
  # The session fingerprint: a short, opaque answer to "which signed-in session
  # rendered this page?" It is stamped on every page (SessionContext#to_stamp)
  # and returned by the rehydrate endpoint, so two tabs, or one tab before and
  # after it went to the background, can tell whether they still describe the
  # same session WITHOUT exposing anything that identifies it.
  #
  # WHAT FEEDS IT, and why each part is there:
  #
  #   * the user's id — a different account is a different session;
  #   * the user's session_token, when the host has that column
  #     (docs/USER_CONTRACT.md). Studio::ErrorHandling binds it into the cookie
  #     and a host rotates it to log a user out everywhere, so a rotation changes
  #     the fingerprint and a page rendered before it can see it was revoked;
  #   * the identities the host has bound the session to (SessionContext#to_stamp's
  #     `identities:`). A host can re-bind a session to a different identity
  #     without the account or its token changing. Folding the bindings in means
  #     that re-bind changes the fingerprint too, so every other tab learns about
  #     it the same way it learns about a sign-out.
  #
  # All of it is keyed through an HMAC, so the fingerprint never carries the token
  # (a bearer secret bound into the cookie) or the id in a readable form, and it
  # cannot be recomputed by anyone without the app's secret.
  #
  # "anonymous" is deliberately a plain constant, not a digest. There is no
  # identity to protect, and every signed-out tab SHOULD agree with every other
  # signed-out tab: anonymous is a first-class state, not a missing value.
  #
  # Pure Ruby (no ActiveRecord), so it unit-tests without a database.
  module SessionFingerprint
    ANONYMOUS = "anonymous"

    # 32 hex characters = 128 bits of the HMAC: two sessions never collide by
    # accident, and it is still short enough to read in a log line.
    LENGTH = 32

    # The key_generator purpose. Changing it changes every fingerprint in the
    # fleet at once, which reads to every open tab as "your session changed".
    KEY_PURPOSE = "studio/session-fingerprint"

    class MissingSecret < StandardError; end

    module_function

    # The fingerprint for a user (or nil) and the identities bound to the
    # session. `secret:` exists for unit tests; everything else resolves it.
    def for(user, identities: {}, secret: nil)
      bindings = bindings(identities)
      return ANONYMOUS if user.nil? && bindings.empty?

      digest(material(user, bindings), secret: secret || resolve_secret)
    end

    def digest(material, secret:)
      raise MissingSecret, "a session fingerprint needs a secret" if secret.nil? || secret.to_s.empty?

      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, material.to_s)[0, LENGTH]
    end

    # JSON, not a joined string: a host's identity names and values are
    # arbitrary text, and no separator is safe against arbitrary text. A host
    # with no session_token column still gets a per-account fingerprint; it simply
    # cannot express "revoked" through it.
    #
    # Every part is a String (or nil) before it is encoded. Handing JSON an
    # arbitrary object would route it through ActiveSupport's as_json, which walks
    # instance variables — a test double or a decorated user could recurse there.
    def material(user, bindings = [])
      id = user.respond_to?(:id) ? user.id : user
      token = user.respond_to?(:session_token) ? user.session_token : nil
      JSON.generate(["studio-session", id&.to_s, token&.to_s, bindings])
    end

    # Sorted pairs, so the same bindings produce the same fingerprint whatever
    # order the host built its hash in. A blank value is not a binding.
    def bindings(identities)
      (identities || {})
        .map { |name, value| [name.to_s, value.to_s] }
        .reject { |_, value| value.empty? }
        .sort
    end

    # The explicit Studio.session_fingerprint_secret, else a key derived from the
    # host app's secret_key_base. Every process of one app derives the SAME key,
    # which is the property that matters: a fingerprint that differed per dyno
    # would report drift on every request that landed on another one.
    #
    # `::Rails.respond_to?(:application)`, not `defined?(Rails)`: a gem can define
    # a bare Rails namespace without an application behind it.
    def resolve_secret
      explicit = Studio.respond_to?(:session_fingerprint_secret) ? Studio.session_fingerprint_secret : nil
      return explicit unless explicit.nil? || explicit.to_s.empty?

      if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application &&
         ::Rails.application.respond_to?(:key_generator)
        return ::Rails.application.key_generator.generate_key(KEY_PURPOSE, 32)
      end

      raise MissingSecret,
            "Studio::SessionFingerprint has no secret: set Studio.session_fingerprint_secret, " \
            "or boot inside a Rails application (it derives one from secret_key_base)."
    end
  end
end
