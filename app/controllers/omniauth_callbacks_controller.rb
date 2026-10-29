# Google OAuth callback (the web2 social path).
#
# Defense-in-depth: omniauth-google-oauth2 already verifies the id_token's JWT
# signature against Google's JWKS, but we additionally re-validate it server-side
# via Google's tokeninfo endpoint (GoogleOauthValidator) to assert audience +
# email_verified + expiry before trusting the identity. Only a Google-confirmed
# verified email is allowed to find-or-create an account.
#
# The strategy itself is registered by the engine (Studio::GoogleSignIn) unless
# the host registered its own.
#
# Engine GENERIC base. turf-monster OVERRIDES this controller for popup-mode,
# account merge, wallet-collision stashing, and funnel attribution.
class OmniauthCallbacksController < ApplicationController
  skip_before_action :require_authentication

  def create
    auth = request.env["omniauth.auth"]
    result = GoogleOauthValidator.new(id_token: id_token_from(auth)).validate!
    unless result.ok?
      Rails.logger.warn("[omniauth] google id_token rejected: #{result.reason}")
      return redirect_to login_path, alert: "Google sign-in could not be verified. Please try again."
    end

    # The host's own User.from_omniauth when it defines one, else the engine's
    # default (Studio::OmniauthUser), so a new app signs people in with Google
    # before it writes any User code of its own.
    user = Studio::OmniauthUser.resolve(User, auth, email_verified: result.email_verified)
    unless user.is_a?(User)
      return redirect_to login_path, alert: "Google sign-in couldn't be completed. Please try another method."
    end

    rescue_and_log(target: user) do
      set_app_session(user)
      redirect_to root_path, notice: "Signed in with Google!"
    end
  rescue StandardError
    redirect_to login_path, alert: "Google sign-in failed. Please try again."
  end

  def failure
    redirect_to login_path, alert: "Google sign-in failed. Please try again."
  end

  private

  # The id_token lives at auth.extra.id_token (OmniAuth AuthHash) — read it
  # tolerantly so a missing extras hash (test mock) doesn't raise.
  def id_token_from(auth)
    auth&.dig("extra", "id_token") || (auth.respond_to?(:extra) ? auth.extra&.id_token : nil)
  end
end
