# frozen_string_literal: true

module Studio
  # Minting a magic link, and building the URL that consumes it — the two halves
  # of one decision (Studio.magic_link_store), kept in one place so they can
  # never drift apart. A token minted in the :database store is only consumable
  # at /l/<token>; a :signed token only at /magic_link/<token>. Handing out the
  # wrong URL for the store yields an "invalid or expired link" on a link that
  # was valid — the failure mode this concern exists to prevent.
  #
  # Included by every issuer: MagicLinksController (the request-a-link flow),
  # UserMailer (the emailed link), and Studio::LocalReviewsController (the
  # dev-only local-review link). An app that overrides MagicLinksController
  # wholesale brings its own issuing and is unaffected.
  module MagicLinkIssuing
    extend ActiveSupport::Concern

    private

    # Mint a token in the configured store. Default :signed keeps the legacy
    # stateless MessageVerifier link; :database mints a Studio::Link row (the
    # short, unified scheme). `return_to` is sanitized by both stores.
    def issue_magic_link(email, return_to)
      if Studio.magic_link_store == :database
        Studio::Link.create_magic_link(email: email, return_to: return_to).token
      else
        MagicLink.generate(email: email, return_to: return_to)
      end
    end

    # The URL that CONSUMES the token this app mints: the short /l/<token> for
    # the :database scheme, the legacy /magic_link/<token> for :signed (and for
    # a :database app that keeps its own /magic_link route, e.g. turf-monster,
    # whose /l is already its landing-page namespace).
    def magic_link_url_for(token)
      Studio.magic_link_via_l_route? ? link_url(token: token) : magic_link_url(token: token)
    end
  end
end
