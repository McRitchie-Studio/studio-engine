# frozen_string_literal: true

module Studio
  # POST /_studio/google_setup_request: "Request Google setup", from the modal
  # the Google button opens while the app has no OAuth client
  # (Studio::GoogleSignIn, studio/google_sign_in/_button).
  #
  # Unauthenticated, because the person asking cannot sign in yet, and CSRF-
  # checked like any form post. It mails the team at most ONCE PER HOST PER DAY
  # (Studio::GoogleSignIn.claim_daily_request, on Rails.cache), so the worst a
  # stranger can do is send one email a day the team wanted anyway. Every
  # request writes a log line, the repeats included, so the logs show demand.
  #
  # The email carries the app name, the host and the exact redirect URI to
  # register: https://<host>/auth/google_oauth2/callback.
  class GoogleSetupRequestsController < ::ApplicationController
    skip_before_action :require_authentication, raise: false

    def create
      host = request.host_with_port
      redirect_uri = Studio::GoogleSignIn.redirect_uri(host: host, scheme: callback_scheme)
      notified = Studio::GoogleSignIn.claim_daily_request(host)

      Rails.logger.info(
        "[google-setup] request app=#{Studio.app_name.inspect} host=#{host} " \
        "redirect_uri=#{redirect_uri} ready=#{Studio.google_ready?} notified=#{notified}"
      )
      deliver(host, redirect_uri) if notified

      notice = if notified
        "Thanks. We've asked the team to finish setting up Google sign-in. Use email for now."
      else
        "The team already has a request to set up Google sign-in today. Use email for now."
      end

      respond_to do |format|
        format.json { render json: { requested: true, notified: notified, message: notice } }
        format.any { redirect_back_or_to login_path, notice: notice, allow_other_host: false }
      end
    end

    private

    # https in production (the host terminates TLS at the router, so the request
    # itself may read http), and whatever the request came in on elsewhere, so a
    # local desk's email names the callback that desk would use.
    def callback_scheme
      request.ssl? || Rails.env.production? ? "https" : request.scheme
    end

    def deliver(host, redirect_uri)
      recipient = Studio.google_setup_request_to
      Studio::Email.deliver(Studio::GoogleSetupMailer, :setup_requested,
                            Studio.app_name.to_s, host, redirect_uri, recipient, to: recipient)
    rescue StandardError => e
      # The person asking still gets an answer; the failure goes where the team
      # looks for failures.
      Rails.logger.warn("[google-setup] the request email failed: #{e.class}: #{e.message.to_s[0, 200]}")
      ErrorLog.capture!(e) if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
    end
  end
end
