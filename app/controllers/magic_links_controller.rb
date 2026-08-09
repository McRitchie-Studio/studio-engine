# Requesting a magic link — the passwordless email path's front door.
#
#   POST /magic_link — request a link (email [, return_to])
#
# That is the whole controller. The token-bearing half lives at /l/<token>
# (Studio::LinksController): one token format, one place it burns. Before
# 0.31.0 this class also owned a /magic_link/:token confirm+consume pair for
# the retired :signed store, which was a second door onto the same lock.
#
# create-or-login: clicking the emailed link IS proof of email ownership, so an
# email that collides with a Google/wallet-only account that was never
# email-verified is safely signed in at consume time and stamped
# email_verified_at (unlike from_omniauth, which refuses that collision
# precisely because it lacked this proof).
class MagicLinksController < ApplicationController
  include Studio::MagicLinkIssuing

  skip_before_action :require_authentication

  # Respond uniformly for any well-formed email. Under create-or-login every
  # address is "valid" (it logs in or signs up), so there is nothing to
  # enumerate. A malformed email gets the same response with no mail sent.
  def create
    email = params[:email].to_s.strip.downcase
    if email.match?(URI::MailTo::EMAIL_REGEXP)
      token = issue_magic_link(email, Studio::LinkToken.sanitize_path(params[:return_to]))
      Studio::Email.deliver(UserMailer, :magic_link, email, token, to: email)
    end
    respond_to do |format|
      format.json { render json: { success: true } }
      format.html { redirect_to login_path, notice: "Check your inbox — we just emailed you a sign-in link." }
    end
  end

  # issue_magic_link (mint a Studio::Link row) comes from
  # Studio::MagicLinkIssuing, shared with UserMailer — which builds the URL that
  # consumes it — so the mint and its landing URL cannot drift apart.
end
