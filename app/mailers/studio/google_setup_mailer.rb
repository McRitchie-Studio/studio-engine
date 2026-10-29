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

    def setup_requested(app_name, host, redirect_uri, to)
      @app_name = app_name
      @host = host
      @redirect_uri = redirect_uri
      @oauth_project = OAUTH_PROJECT
      mail(to: to, subject: "Google sign-in setup requested: #{app_name} (#{host})")
    end
  end
end
