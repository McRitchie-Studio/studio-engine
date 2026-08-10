# Opt in to the shared /admin/emails page, exactly as a consuming app does from
# config/initializers/studio.rb. It is OFF by default because turf-monster
# already owns that path and both of its helper names — see the note in
# Studio.routes. Set here, before the draw, so the dummy exercises the page.
Studio.draw_admin_emails_routes = true

Rails.application.routes.draw do
  # Draw the engine's shared route table the same way every consuming app does
  # (Studio.routes(self), not `mount`). The boot test asserts the named path
  # helpers generate, proving the engine's route DSL is valid under the host
  # Rails version's router. Controllers load lazily on dispatch, so drawing
  # these does not pull in the host-only auth controllers.
  Studio.routes(self)

  # Studio.routes deliberately draws no root — every consuming app owns its own.
  # The magic-link flow redirects to root_path and to a return_to page, so the
  # dummy stands up two landing pages for the link suite to arrive on. See
  # PagesController for why they are controllers and not Rack lambdas.
  root to: "pages#show", defaults: { page: "root" }
  get "dashboard", to: "pages#show", defaults: { page: "dashboard" }
end
