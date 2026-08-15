# frozen_string_literal: true

# The OAuth identity bound to an account — is Google linked, and is it safe to
# unlink it?
#
# Pure Ruby and duck-typed, like Studio::ProfileImage: it takes anything that
# answers `provider` / `uid` / `email`, so the rules are unit-testable without a
# users table, and a host whose model has none of those columns is simply
# reported as "not linked" rather than raising.
#
# THE ORPHAN GUARD IS THE REASON THIS FILE EXISTS. turf-monster's
# AccountsController#unlink_google is one line — `update!(provider: nil, uid: nil)`
# — with no check at all. For an account whose ONLY sign-in is Google (blank
# email, so no magic link; no wallet; no password) that button silently locks
# someone out of their own account, and the label just says "Unlink". It is safe
# in turf today only because turf's users happen to carry an email; that is a
# property of turf's data, not of the code, and the engine ships to apps whose
# data it has never seen.
#
# So the engine asks first: after this unlink, is there still a way back in?
module Studio
  module OauthIdentity
    # Both spellings appear across the ecosystem: `google_oauth2` is the OmniAuth
    # strategy name that lands in users.provider, and `google` is what
    # Studio.auth_methods calls the same thing. Matching both means a host that
    # stored either is read correctly rather than reported as unlinked.
    GOOGLE_PROVIDERS = %w[google google_oauth2].freeze

    module_function

    def google_linked?(user)
      return false unless user.respond_to?(:provider) && user.respond_to?(:uid)

      GOOGLE_PROVIDERS.include?(user.provider.to_s) && user.uid.present?
    end

    # Every way this account could sign in if Google were gone. Returns symbols
    # so a caller can name what is left in a message rather than just refusing.
    #
    # Gated on Studio.auth_methods, not just on the column: an app that has an
    # email column but does not offer magic-link sign-in cannot use it to get
    # back in, and counting it would be exactly the wrong answer.
    def remaining_sign_ins(user, auth_methods: Studio.auth_methods)
      methods = Array(auth_methods).map(&:to_sym)
      remaining = []

      remaining << :magic_link if methods.include?(:magic_link) && present?(user, :email)
      remaining << :wallet     if methods.include?(:wallet) && wallet_present?(user)
      # `Studio.password_login_available?` — NOT a bare password_digest check.
      # A digest can be a FOSSIL: turf-monster removed `has_secure_password` and
      # kept the column, so rows still carry digests no code can authenticate
      # against. Counting one as a way back in is a false positive in the
      # dangerous direction — it would permit an unlink that orphans the account.
      # The engine already ships the correct composite predicate
      # (auth_method?(:password) && the User answering `authenticate`).
      remaining << :password if methods.include?(:password) &&
                                Studio.password_login_available? &&
                                present?(user, :password_digest)

      remaining
    end

    # The question the controller actually asks before unlinking.
    def unlink_orphans_account?(user, auth_methods: Studio.auth_methods)
      remaining_sign_ins(user, auth_methods: auth_methods).empty?
    end

    def present?(user, attribute)
      user.respond_to?(attribute) && user.public_send(attribute).present?
    end

    # ONLY the explicitly configured wallet column — no fallback to a
    # conventional name, deliberately.
    #
    # A convention-guessed reader is a false positive waiting to happen, and
    # turf-monster is the live example: its `User#solana_address` returns
    # `web3_solana_address || web2_solana_address`, and only the WEB3 address can
    # actually sign in (SolanaSessionsController verifies a wallet signature; the
    # web2 address is a custodial account with no signer). Guessing that reader
    # would count a custodial address as a way back in and permit an unlink that
    # orphans the account.
    #
    # So an app that has not named its signing-wallet column is treated as having
    # no wallet sign-in. That errs toward REFUSING an unlink, which is the safe
    # direction: the cost is an occasional refusal the operator can resolve by
    # configuring `Studio.wallet_address_method`; the cost of the other direction
    # is someone locked out of their account.
    def wallet_present?(user)
      configured = Studio.wallet_address_method
      return false if configured.blank?

      present?(user, configured)
    end
  end
end
