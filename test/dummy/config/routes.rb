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

# Opt in to the session-drift rehydrate endpoint (GET /session/state), as a
# consuming app does. OFF by default — see Studio.draw_session_routes.
Studio.draw_session_routes = true

# Opt in to the survey pages and the admin results panel, as a consuming app
# does. OFF by default — see Studio.draw_survey_routes.
Studio.draw_survey_routes = true
Studio.draw_admin_survey_routes = true

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
  get "lab/engine_modules", to: "e2e_lab#engine_modules"
  get "lab/email_banner_frames", to: "e2e_lab#email_banner_frames"
  get "lab/email_banner_editor", to: "e2e_lab#email_banner_editor"
  get "lab/birthday_gate", to: "e2e_lab#birthday_gate"
  get "lab/modal_host", to: "e2e_lab#modal_host"
  get "lab/onboarding_first_name", to: "e2e_lab#onboarding_first_name"
  get "lab/js_attribute_locals", to: "e2e_lab#js_attribute_locals"
  get "lab/toast_over_banner", to: "e2e_lab#toast_over_banner"
  get "lab/toast_flash", to: "e2e_lab#toast_flash"
  get "lab/profile", to: "e2e_lab#profile"
  get "lab/profile_edit", to: "e2e_lab#profile_edit"
  get "lab/hold_button", to: "e2e_lab#hold_button"
  get "lab/hold_button_events", to: "e2e_lab#hold_button_events"
  get "lab/lazy_controller", to: "e2e_lab#lazy_controller"
  get "lab/geo_settings", to: "e2e_lab#geo_settings"
  get "lab/site_identity", to: "e2e_lab#site_identity"
  get "lab/style_modals", to: "e2e_lab#style_modals"
  get "lab/board", to: "e2e_lab#board"
  get "lab/session_drift", to: "e2e_lab#session_drift"
  get "lab/sidebar_panels", to: "e2e_lab#sidebar_panels"
  get "lab/sidebar_panels_turbo", to: "e2e_lab#sidebar_panels_turbo"
  # One route per page, spelled out: test/integration/e2e_lab_isolation_test.rb
  # visits every /lab route by its literal path, which an optional segment is not.
  get "lab/site_footer", to: "e2e_lab#site_footer"
  get "lab/site_footer/terms", to: "e2e_lab#site_footer", defaults: { variant: "terms" }
  get "lab/site_footer/home", to: "e2e_lab#site_footer", defaults: { variant: "home" }
  get "lab/site_footer/schedule", to: "e2e_lab#site_footer", defaults: { variant: "schedule" }
  get "lab/site_footer/plain", to: "e2e_lab#site_footer", defaults: { variant: "plain" }
  get "lab/site_footer/crops", to: "e2e_lab#site_footer", defaults: { variant: "crops" }
  get "lab/site_footer/columns/:n", to: "e2e_lab#site_footer", defaults: { variant: "columns" }

  # A host app's own pages, one open and one geo-LOCKED, for the geo suite.
  get "lab/geo", to: "geo_lab#open"
  get "lab/geo_locked", to: "geo_lab#locked"

  # A host app's pages for the link-preview suite: plain, overridden, and heavy.
  get "lab/link_preview", to: "link_preview_lab#plain"
  get "lab/link_preview/override", to: "link_preview_lab#override"
  get "lab/link_preview/heavy", to: "link_preview_lab#heavy"
  # The same pages behind `allow_browser versions: :modern`: one host relying on
  # the engine alone, one still carrying the app-side `unless:` patch.
  get "lab/link_preview_modern", to: "link_preview_modern_lab#plain"
  get "lab/link_preview_modern/heavy", to: "link_preview_modern_lab#heavy"
  post "lab/link_preview_modern", to: "link_preview_modern_lab#submit"
  get "lab/link_preview_patched", to: "link_preview_patched_lab#plain"
  post "lab/sign_in", to: "geo_lab_sessions#create"

  # A host app's ordinary page + sign-in/out, for the session-drift suite.
  # Host pages for test/integration/site_footer_test.rb, which defines the
  # controllers: a public page, a signed-in working surface, and a page that
  # calls the helpers directly.
  get "footer_host/landing", to: "footer_host_landing#show"
  get "footer_host/board", to: "footer_host_board#show"
  get "footer_host/helpers", to: "footer_host_landing#helpers"
  # The host's legal pages, drawn only when a test names them
  # (config.x.footer_host_legal = %i[privacy terms]): the default footer links
  # the `privacy` and `terms` routes a host HAS, so both states need a host.
  legal = Rails.application.config.x.footer_host_legal
  (legal.is_a?(Array) ? legal : []).each do |name|
    get "footer_host/#{name}", to: "footer_host_landing#show", as: name
  end
  # A route NAMED like a legal page that no visitor can open: the default footer
  # must not link it (config.x.footer_host_legal_post = true).
  post "footer_host/terms", to: "footer_host_landing#show", as: :terms if Rails.application.config.x.footer_host_legal_post == true
  # An app's OWN booking page (config.booking_path), not the engine's /schedule.
  get "footer_host/schedule", to: "footer_host_schedule#show"

  # The survey lane's admin sign-in (SurveyLabSessionsController). Outside /lab
  # on purpose: see that controller.
  get "survey_lab/sign_in", to: "survey_lab_sessions#create"

  get "lab/session", to: "session_lab#show"
  post "lab/session/sign_in", to: "session_lab#sign_in"
  post "lab/session/sign_out", to: "session_lab#sign_out"
end
