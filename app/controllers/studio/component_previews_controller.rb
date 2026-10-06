# frozen_string_literal: true

module Studio
  # ViewComponent's preview controller, behind the admin wall. ViewComponent
  # draws its own preview pages at Studio::ComponentGallery::PREVIEWS_ROUTE
  # wherever previews are on (development and test), and Lookbook renders every
  # preview in the gallery through this same controller. Anyone but a signed-in
  # admin gets 404, so neither path shows a component to a visitor even if a
  # route is drawn that the gallery's router constraint does not cover.
  #
  # It inherits ViewComponent's controller (Rails::ApplicationController), not
  # the host's ApplicationController, so the host's own before_actions do not
  # run inside a preview render.
  class ComponentPreviewsController < ::ViewComponentsController
    prepend_before_action :require_gallery_admin

    private

    def require_gallery_admin
      head :not_found unless Studio::ComponentGallery.admin_request?(request)
    end
  end
end
