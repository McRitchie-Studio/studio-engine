# frozen_string_literal: true

module Studio
  # Minting a magic link, and building the URL that consumes it — the two halves
  # of one decision, kept in one place so they can never drift apart. Handing
  # out the wrong URL for a token yields an "invalid or expired link" on a link
  # that was perfectly valid: the failure mode this concern exists to prevent.
  #
  # Since 0.31.0 there is one store (a Studio::Link row) and one token format
  # (Studio::LinkToken.generate — 16 URL-safe characters), so the only remaining
  # question is the PATH: the standard /l/<token>, or an app's own token route
  # (turf-monster keeps /magic_link/<token> because /l is already its
  # landing-page namespace).
  #
  # Included by every issuer: MagicLinksController (the request-a-link flow),
  # RegistrationsController (the passwordless signup POST), UserMailer (the
  # emailed link), and Studio::LocalReviewsController (the dev-only local-review
  # link). An app that overrides those wholesale brings its own issuing.
  module MagicLinkIssuing
    extend ActiveSupport::Concern

    private

    # Mint a token. `return_to` is sanitized to a same-origin path by the store.
    def issue_magic_link(email, return_to)
      Studio::Link.create_magic_link(email: email, return_to: return_to).token
    end

    # The URL that CONSUMES the token this app mints.
    def magic_link_url_for(token)
      Studio.magic_link_via_l_route? ? link_url(token: token) : magic_link_url(token: token)
    end
  end
end
