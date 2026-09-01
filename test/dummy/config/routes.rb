# Opt in to the shared /admin/emails page, exactly as a consuming app does from
# config/initializers/studio.rb. It is OFF by default because turf-monster
# already owns that path and both of its helper names — see the note in
# Studio.routes. Set here, before the draw, so the dummy exercises the page.
Studio.draw_admin_emails_routes = true

# Opt in to the shared first-name onboarding endpoints, likewise. OFF by default
# because turf-monster owns onboarding_first_name_path and
# onboarding_skip_first_name_path until its adoption task deletes the local pair.
Studio.draw_onboarding_routes = true

# Opt in to the shared geo manager (/admin/geo) + probe (/geo/check), as a
# consuming app does. OFF by default because turf-monster owns all four helper
# names until its adoption lands — see Studio.draw_geo_routes.
Studio.draw_geo_routes = true

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

  # THE BROWSER LAB (e2e/). Drawn unconditionally rather than behind an env check:
  # a route that exists only when a flag is set is a route that can silently stop
  # existing, and the lane would then 404 its way to a green run. These pages are
  # part of the dummy TEST app, which ships in no gem — spec.files in
  # studio-engine.gemspec has never included test/ — so there is nothing to gate.
  #
  # Path prefixes are deliberately disjoint: /e2e/* is served as STATIC files from
  # test/dummy/public (the compiled Tailwind and Alpine), /lab/* is routed. Sharing
  # one prefix means the static file server shadows a route the day someone adds a
  # file whose name collides.
  get "up", to: "e2e_lab#up"
  get "lab/bar_stack", to: "e2e_lab#bar_stack"
  get "lab/at_time", to: "e2e_lab#at_time"
  get "lab/email_banner_frames", to: "e2e_lab#email_banner_frames"
  get "lab/email_banner_editor", to: "e2e_lab#email_banner_editor"
  get "lab/birthday_gate", to: "e2e_lab#birthday_gate"
  get "lab/modal_host", to: "e2e_lab#modal_host"
  get "lab/toast_over_banner", to: "e2e_lab#toast_over_banner"
  get "lab/profile", to: "e2e_lab#profile"
  get "lab/profile_edit", to: "e2e_lab#profile_edit"
  get "lab/hold_button", to: "e2e_lab#hold_button"
  get "lab/geo_settings", to: "e2e_lab#geo_settings"

  # A host app's own pages, one open and one geo-LOCKED, for the geo suite.
  get "lab/geo", to: "geo_lab#open"
  get "lab/geo_locked", to: "geo_lab#locked"
  post "lab/sign_in", to: "geo_lab_sessions#create"
end
