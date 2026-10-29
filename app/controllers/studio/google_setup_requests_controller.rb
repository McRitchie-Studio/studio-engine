# frozen_string_literal: true

module Studio
  # POST /_studio/google_setup_request: "Request Google setup", from the modal
  # the Google button opens while the app has no OAuth client
  # (Studio::GoogleSignIn, studio/google_sign_in/_button).
  #
  # Unauthenticated, because the person asking cannot sign in yet, and CSRF-
  # checked like any form post. Three rules keep a stranger from turning it
  # into a mail cannon or a way to plant a callback (Carl and Steffon,
  # 2026-10-29):
  #
  #   * NOTHING IN IT COMES FROM THE REQUEST'S HOST. The daily claim is keyed on
  #     the app (Studio::GoogleSignIn.app_key), so a forged Host header, port or
  #     X-Forwarded-Host cannot mint a fresh day; and the redirect URI in the
  #     email is built from the app's configured canonical host
  #     (Studio::GoogleSignIn.canonical_redirect_uri), so ops is never asked to
  #     register a host an attacker chose.
  #   * ONCE PER APP PER DAY (Studio::GoogleSignIn.claim_daily_request).
  #   * ONLY WHILE THE BUTTON SHOWS THE MODAL. An app whose button already
  #     posts to Google (client configured, or its own provider) answers 404.
  #
  # Every accepted request writes a log line, the repeats included, so the logs
  # show demand.
  class GoogleSetupRequestsController < ::ApplicationController
    skip_before_action :require_authentication, raise: false

    def create
      return head(:not_found) if Studio::GoogleSignIn.button_posts?

      redirect_uri = Studio::GoogleSignIn.canonical_redirect_uri
      notified = Studio::GoogleSignIn.claim_daily_request

      Rails.logger.info(
        "[google-setup] request app=#{Studio.app_name.inspect} " \
        "redirect_uri=#{redirect_uri || 'unconfigured'} notified=#{notified}"
      )
      deliver(redirect_uri) if notified

      notice = if notified
        "Thanks. We've asked the team to finish setting up Google sign-in. Use email for now."
      else
        "The team already has a request to set up Google sign-in today. Use email for now."
      end

      respond_to do |format|
        format.json { render json: { requested: true, notified: notified, message: notice } }
        format.any { redirect_to login_path, notice: notice }
      end
    end

    private

    def deliver(redirect_uri)
      recipient = Studio.google_setup_request_to
      Studio::Email.deliver(Studio::GoogleSetupMailer, :setup_requested,
                            Studio.app_name.to_s, Studio::GoogleSignIn.canonical_host.to_s,
                            redirect_uri.to_s, recipient, to: recipient)
    rescue StandardError => e
      # The person asking still gets an answer; the failure goes where the team
      # looks for failures.
      Rails.logger.warn("[google-setup] the request email failed: #{e.class}: #{e.message.to_s[0, 200]}")
      ErrorLog.capture!(e) if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
    end
  end
end
