# frozen_string_literal: true

module Studio
  # GET /_studio/modals/:id: one on-demand modal's content partial, for
  # studio/modal_host to insert into the shared host the first time the modal
  # opens (Studio.modals, README "Modal host", "Modals on demand").
  #
  # THE ALLOWLIST IS THE REGISTRY. Only an id Studio.modals names renders; any
  # other id answers 404, so the endpoint can never be used to render an
  # arbitrary partial by name.
  #
  # AUTH. The host's require_authentication is skipped so an :any modal (the
  # sign-in card) serves a signed-out browser. A :user modal answers a bare
  # 401 to a signed-out request rather than the engine's HTML redirect to
  # /login: the caller is fetch(), and a followed redirect would hand it the
  # login PAGE to insert as a modal. Host filters that still run (a revoked
  # session token, an onboarding redirect) answer as they do for any request;
  # the X-Studio-Modal header below is how the browser tells a real fragment
  # from whatever such a filter sent instead.
  #
  # CACHING. The fragment can carry the viewer's data and a form's CSRF token,
  # so it is private: Rails' default for a dynamic GET (max-age=0, private,
  # must-revalidate, with an ETag) is kept, and Vary: Cookie is added so no
  # cache answers one session with another's fragment. The browser holds the
  # fragment for the page's lifetime anyway (studio/modal_host).
  class ModalsController < ::ApplicationController
    skip_before_action :require_authentication, raise: false

    def show
      entry = Studio.modals[params[:id]]
      return head(:not_found) unless entry
      return head(:unauthorized) if entry.user_only? && !studio_modal_viewer_signed_in?

      @studio_modal = entry
      response.headers["X-Studio-Modal"] = entry.id
      response.headers["Vary"] = [response.headers["Vary"], "Cookie"].compact.join(", ")
      render "studio/modals/remote", layout: false, formats: [:html]
    end

    private

    def studio_modal_viewer_signed_in?
      respond_to?(:logged_in?, true) && logged_in?
    end
  end
end
