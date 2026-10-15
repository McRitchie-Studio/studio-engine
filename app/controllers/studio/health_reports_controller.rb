# frozen_string_literal: true

module Studio
  # GET /_studio/health_report — the daily health report as JSON, for the
  # McRitchie Studio hub's one 07:00 America/Denver job, which pulls every app
  # and posts to Discord. Drawn in every environment, production included; the
  # report is the same Studio::HealthReport.build the email uses, so the two can
  # never disagree. docs/HEALTH_REPORT.md, "The hub endpoint".
  #
  # INERT BY DEFAULT. With no Studio.health_report_token (else
  # ENV["STUDIO_HEALTH_TOKEN"]) it answers a bare 404, the same as a route that
  # is not there. With one, a request without `Authorization: Bearer <token>`
  # gets 401; the compare is constant-time (Studio::HealthReport.authorized?).
  #
  # COUNTS ONLY. Studio::HealthReport.payload drops every section's `items`, so
  # no signup's or contact's name or email ever leaves the app.
  #
  # ActionController::API, NOT the host's ApplicationController: a server-to-
  # server fetch carries no session, and a host's before_actions (sign-in, geo,
  # allow_browser, onboarding) would answer it with a redirect or an HTML page.
  # This base runs none of them, keeps no session, sets no cookie and checks no
  # CSRF token, and every answer here is JSON or a bare status.
  class HealthReportsController < ActionController::API
    def show
      return head(:not_found) if Studio.health_report_token.blank?

      response.headers["Cache-Control"] = "no-store"
      unless Studio::HealthReport.authorized?(request.authorization)
        response.headers["WWW-Authenticate"] = 'Bearer realm="studio-health-report"'
        return render(json: { error: "unauthorized" }, status: :unauthorized)
      end

      window = begin
        Studio::HealthReport.window_for(params[:ending].presence)
      rescue ArgumentError
        return render(json: { error: "ending must be an ISO 8601 time" }, status: :bad_request)
      end

      render json: Studio::HealthReport.payload(Studio::HealthReport.build(window: window))
    rescue StandardError => e
      # build already turns a failing SOURCE into a section's `failure`; this is
      # anything else. Logged as an ErrorLog row, answered as JSON, never HTML.
      Studio::HealthReport.capture(e)
      render json: { error: "health report failed" }, status: :internal_server_error
    end
  end
end
