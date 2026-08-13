module Studio
  # The "you're on the list" email.
  #
  # NAMESPACED, unlike the engine's UserMailer, and that is the whole point. A
  # host that defines its own top-level `UserMailer` (McRitchie Studio does)
  # SHADOWS the engine's outright — Zeitwerk resolves the constant to the host's
  # file and the engine's actions simply do not exist there. Putting this under
  # Studio:: means every app inherits a sendable newsletter email on day one,
  # and a host that wants different copy overrides the VIEW rather than losing
  # the action.
  class NewsletterMailer < ApplicationMailer
    # Branded shell — banner + card. The layout renders @banner layered (artwork
    # with live text on top) and falls back to the flat @banner_url <img>.
    layout "branded_mailer"

    # `email` is a raw string: someone can join a mailing list without ever
    # holding an account, so this must not require a User.
    #
    # unsubscribe_url is OPTIONAL and the line renders only when it is given.
    # A newsletter needs a way out, but a hard-coded dead link is worse than an
    # honest omission — a host wires its real one and the line appears.
    def subscribed(email, name: nil, unsubscribe_url: nil)
      @app_name        = Studio.app_name
      @email           = email
      @name            = name.presence
      @unsubscribe_url = unsubscribe_url.presence

      # The mailer passes WHO, not WHAT THE BANNER SAYS. The wording — including
      # whether it greets by name at all — is the operator's, editable on
      # /admin/emails. Handing over a finished header here would make that field
      # accept edits and change nothing.
      @banner = Studio::Banner.for(:newsletter_subscribed, name: @name)
      @banner_alt = "#{@banner&.header} — #{@app_name}"
      # The floor, exactly as UserMailer does it: if no layered artwork is
      # registered the layout renders the flat <img> instead of nothing.
      @banner_url = Studio::EmailCatalog.resolved_url(:newsletter_subscribed)

      subject = Studio::EmailCatalog.subject_for(:newsletter_subscribed, name: @name) ||
                "You're subscribed to #{@app_name}"
      mail(to: email, subject: subject)
    end
  end
end
