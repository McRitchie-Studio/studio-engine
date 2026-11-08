# frozen_string_literal: true

module Studio
  # The friendly not-found page, drawn by Studio::ExceptionsApp for an HTML 404
  # (docs/NOT_FOUND_PAGE.md). It has no route: only the exceptions app calls it.
  #
  # It inherits the host's ApplicationController so the page sits inside the
  # app's own layout, navbar, footer and theme, as Studio::PublicUsersController
  # does. A signed-out visitor must see it, so it skips the engine's sign-in gate.
  # A host with its own wall lists it there (the hub's AdminWall names
  # "studio/not_found" => %w[show]). If the host still answers anything but a
  # 404 here, the exceptions app throws that answer away and serves the static
  # public/404.html, so a wall can cost the page its layout but never its status.
  class NotFoundController < ::ApplicationController
    skip_before_action :require_authentication, raise: false
    # The page runs as the exceptions app, after the request has left the
    # session and cookie middleware: nothing it writes to the session or a
    # cookie is ever saved. A callback that throttles through the session never
    # holds here, so it would pay its full cost on every 404 (docs/NOT_FOUND_PAGE.md).
    # Session tracking would add a Studio::UserSession row per signed-in 404.
    skip_after_action :track_user_session, raise: false
    # Geo detection (Studio::GeoDetection) would pay an IP lookup, up to 3s, per
    # 404. raise: false, so a host without the concern is unaffected.
    skip_before_action :detect_geo_state, raise: false
    # No forgery skip: Rails' ShowExceptions calls the exceptions app as a GET
    # (request_method = "GET"), which never needs the token, so the host's CSRF
    # allow-lists stay as they are.

    def show
      @studio_not_found = {
        app_name: Studio.app_name,
        logo: not_found_logo,
        home_path: not_found_home_path,
        back_path: not_found_back_path
      }
      render "studio/not_found/show", status: :not_found, formats: [:html], content_type: "text/html"
    end

    private

    def not_found_logo
      Studio.navbar_brand&.dig(:logo) || Studio.logo_for("Navbar Logo")
    end

    def not_found_home_path
      main_app.respond_to?(:root_path) ? main_app.root_path : "/"
    end

    # The page the visitor came from, when it is on this app: "Go back" returns
    # there. A link from elsewhere, or none, draws no second link.
    def not_found_back_path
      referer = URI.parse(request.referer.to_s)
      return nil unless referer.host == request.host && referer.path.present?
      # "//other.host/x" is a same-host path a browser reads as another site.
      return nil if referer.path.start_with?("//")
      return nil if referer.path == request.env["action_dispatch.original_path"]

      [referer.path, referer.query].compact.join("?")
    rescue URI::InvalidURIError
      nil
    end
  end
end
