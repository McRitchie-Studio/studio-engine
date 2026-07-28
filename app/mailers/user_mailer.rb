class UserMailer < ApplicationMailer
  # magic_link_url_for — the URL that consumes the token, matched to
  # Studio.magic_link_store. Shared with the issuers that MINT the token
  # (MagicLinksController, Studio::LocalReviewsController) so the two halves
  # cannot drift apart.
  include Studio::MagicLinkIssuing

  # Branded shell (banner + card) for engine-sent UserMailer emails. An app with
  # its own UserMailer + branded_mailer layout (e.g. turf-monster) overrides both.
  layout "branded_mailer"

  # Passwordless sign-in link. `email` is a raw string (the recipient may not
  # have an account yet). Token is a signed MagicLink payload (email + return_to
  # + jti, single-use). Clicking the link logs the recipient in or creates their
  # account. App-name-aware so the same template serves every Studio app.
  #
  # Engine GENERIC base. An app needing richer copy (e.g. turf-monster's
  # contest-aware variant) defines its own UserMailer, which wins.
  def magic_link(email, token)
    @app_name   = Studio.app_name
    @email      = email
    @magic_url  = magic_link_url_for(token)
    @banner_url = Studio::EmailImage.url(:magic_link) # admin-managed; nil renders bannerless
    @banner_alt = "Your #{@app_name} sign-in link"
    mail(to: email, subject: "Your #{@app_name} sign-in link")
  end
end
