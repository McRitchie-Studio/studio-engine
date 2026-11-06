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
  #
  # A mint or mail failure is logged once (rescue_and_log) and answered the same
  # way for every address, as the passwordless signup does: the login page with
  # one alert, or a 503 with a fixed JSON body. 503, not 4xx: the visitor's
  # input was fine and a retry may work; a 4xx would tell a client to change the
  # request. The body never carries the internal message, and this action never
  # looks an account up, so the reply cannot say whether the email is known.
  def create
    email = params[:email].to_s.strip.downcase
    if email.match?(URI::MailTo::EMAIL_REGEXP)
      begin
        rescue_and_log do
          token = issue_magic_link(email, Studio::LinkToken.sanitize_path(params[:return_to]))
          Studio::Email.deliver(UserMailer, :magic_link, email, token, to: email)
        end
      rescue StandardError
        return delivery_failed
      end
    end
    respond_to do |format|
      format.json { render json: { success: true } }
      format.html { redirect_to login_path, notice: "Check your inbox — we just emailed you a #{Studio::AuthLabels.link_noun(Studio.sign_in_label)}." }
    end
  end

  private

  def delivery_failed
    message = Studio::MagicLinkIssuing::DELIVERY_FAILED
    respond_to do |format|
      format.json { render json: { success: false, error: "delivery_failed", message: message }, status: :service_unavailable }
      format.html { redirect_to login_path, alert: message }
    end
  end

  # issue_magic_link (mint a Studio::Link row) comes from
  # Studio::MagicLinkIssuing, shared with UserMailer — which builds the URL that
  # consumes it — so the mint and its landing URL cannot drift apart.
end
