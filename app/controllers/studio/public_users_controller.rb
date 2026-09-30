# frozen_string_literal: true

module Studio
  # /u/:username — the public page a username links to in every Studio app.
  #
  # It shows the avatar and the username, and nothing else: no name, no email,
  # no wallet. Its link preview is the avatar when one is set, else the site
  # identity's image (Studio::LinkPreviewHelper#link_preview does the fallback).
  #
  # Public by design, so it skips the host's sign-in gate (mcritchie-industries
  # and cyvasse gate every controller through Studio::ErrorHandling). It inherits
  # the host's ApplicationController for the same reason ProfilesController
  # does: the page renders inside the app's own layout, navbar and theme, and a
  # host that includes Studio::LinkPreviewBots serves unfurlers the slim page.
  #
  # An unknown username gets a friendly page with a real 404 status. Every miss
  # looks the same (unknown, hidden, or an app with no username column), and the
  # lookup never touches the email, so the page cannot be used to learn whether
  # an account exists behind an address. Drawn only when the host opts in:
  # Studio.draw_public_user_routes.
  class PublicUsersController < ::ApplicationController
    skip_before_action :require_authentication, raise: false

    def show
      @public_user = Studio::PublicUser.find(params[:username])
      return if @public_user

      @requested_username = params[:username].to_s
      render :not_found, status: :not_found
    end
  end
end
