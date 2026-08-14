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
      # Not in auth_methods — a password is a property of the record, and an app
      # with password_digest set can always sign in with it.
      remaining << :password   if present?(user, :password_digest)

      remaining
    end

    # The question the controller actually asks before unlinking.
    def unlink_orphans_account?(user, auth_methods: Studio.auth_methods)
      remaining_sign_ins(user, auth_methods: auth_methods).empty?
    end

    def present?(user, attribute)
      user.respond_to?(attribute) && user.public_send(attribute).present?
    end

    # The host names its own wallet column (Studio.wallet_address_method) —
    # turf-monster has two (web2/web3) and resolves between them, mcritchie-studio
    # has one. Fall back to the conventional name so an app that never configured
    # it is still read correctly.
    def wallet_present?(user)
      configured = Studio.wallet_address_method
      return present?(user, configured) if configured.present?

      present?(user, :solana_address)
    end
  end
end
