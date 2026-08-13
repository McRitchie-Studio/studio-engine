class UserMailer < ApplicationMailer
  # magic_link_url_for — the URL that consumes the token. Shared with the
  # issuers that MINT it (MagicLinksController, RegistrationsController,
  # Studio::LocalReviewsController) so the two halves cannot drift apart.
  include Studio::MagicLinkIssuing

  # Branded shell (banner + card) for engine-sent UserMailer emails. An app with
  # its own UserMailer + branded_mailer layout (e.g. turf-monster) overrides both.
  layout "branded_mailer"

  # Passwordless sign-in link. `email` is a raw string (the recipient may not
  # have an account yet). The token is a Studio::Link row's short token — 16
  # URL-safe characters, single-use, expiring — and the email + return_to it
  # stands for stay in the row, off the wire. Clicking the link logs the
  # recipient in or creates their account. App-name-aware so the same template
  # serves every Studio app.
  #
  # Engine GENERIC base. An app needing richer copy (e.g. turf-monster's
  # contest-aware variant) defines its own UserMailer, which wins.
  def magic_link(email, token)
    @app_name   = Studio.app_name
    @email      = email
    @magic_url  = magic_link_url_for(token)
    # ONE lookup, two consumers. recipient_name queries the host's users table,
    # and the banner and the subject want the same answer — asking twice on a
    # delivery path buys nothing and risks the two disagreeing.
    name        = recipient_name(email)
    # THE LAYERED BANNER, when this app has layered artwork for the email.
    #
    # The mailer supplies only WHO the recipient is. What the banner SAYS about
    # them — the greeting, the sub-text, whether the name is used at all — is
    # the operator's, editable on /admin/emails. Handing over a finished header
    # here would leave those fields accepting edits no inbox ever sees.
    #
    # Why this assignment exists at all: /admin/emails draws its preview from
    # this same Studio::Banner.for call, so a mailer that set only @banner_url
    # made the manager show a layered banner with live text for an email that
    # shipped flat baked-in artwork. Preview and send now resolve through one
    # expression and cannot disagree.
    #
    # nil when the app registers no background (or owns the artwork itself), and
    # the layout falls through to the flat <img> below.
    @banner     = Studio::Banner.for(:magic_link, name: name)
    # resolved_url, not url: this app's own upload if it has one, otherwise the
    # engine's default banner — which is what makes a brand-new app's sign-in
    # email branded on day one. nil renders bannerless.
    #
    # KEPT AS THE FLOOR. @banner above wins when it is present; this is what an
    # app with no layered artwork registered still sends, exactly as before.
    # Layered is opt-in, never a migration.
    @banner_url = Studio::EmailCatalog.resolved_url(:magic_link)
    @banner_alt = "Your #{@app_name} sign-in link"
    # THE COPY BELOW THE BANNER is the operator's too, on the same terms as the
    # banner's words: the registry carries what this file used to hard-code, so
    # an app that never opens /admin/emails sends exactly what it sent before.
    @body      = Studio::EmailCatalog.body(:magic_link, name: name)
    @cta_text  = Studio::EmailCatalog.cta_text(:magic_link, name: name) if Studio::EmailCatalog.cta_enabled?(:magic_link)
    @cta_color = Studio::EmailCatalog.cta_color(:magic_link)

    # The operator's subject when they have set one, the hard-coded line
    # otherwise — so an app that never visits /admin/emails is unchanged.
    subject = Studio::EmailCatalog.subject_for(:magic_link, name: name) ||
              "Your #{@app_name} sign-in link"
    mail(to: email, subject: subject)
  end

  private

  # The recipient's name when this app holds an account for them. Defensive about
  # the whole chain — a host may have no User model, no display_name, or no row —
  # because a subject line must never be the reason a send raises.
  def recipient_name(email)
    model = "User".safe_constantize
    return nil unless model.respond_to?(:find_by)

    record = model.find_by(email: email.to_s.strip.downcase)
    %i[display_name name full_name].each do |method|
      value = record.try(method)
      return value if value.present?
    end
    nil
  rescue StandardError
    nil
  end
end
