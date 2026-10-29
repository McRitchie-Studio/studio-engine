# frozen_string_literal: true

module Studio
  # "Request Google setup", sent to the team when someone presses it in the
  # Google modal of an app whose OAuth client is not configured yet
  # (Studio::GoogleSetupRequestsController, Studio::GoogleSignIn). Namespaced so
  # a host's own mailers cannot shadow it; plain strings in, so an outbox row
  # stores nothing but text.
  class GoogleSetupMailer < ApplicationMailer
    layout false

    # The shared production OAuth client every app's callback is added to, and
    # who adds it. Facts for the reader of the email, not configuration.
    OAUTH_PROJECT = "enduring-maxim-491202-t6"

    # host and redirect_uri come from the app's CONFIGURED canonical host
    # (Studio::GoogleSignIn.canonical_host), never from the request, and are
    # blank when the app names none: the email then says to set one.
    def setup_requested(app_name, host, redirect_uri, to)
      @app_name = app_name
      @host = host.to_s.strip.presence
      @redirect_uri = redirect_uri.to_s.strip.presence
      @oauth_project = OAUTH_PROJECT
      subject = "Google sign-in setup requested: #{app_name}"
      subject += " (#{@host})" if @host
      mail(to: to, subject: subject)
    end
  end
end
