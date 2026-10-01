# Minimal Rails 8.1 host application used to boot studio-engine against a real
# Rails app in the test suite. It loads only the frameworks the engine's
# self-contained surfaces (ActiveRecord models, the Railtie, the route DSL)
# need — deliberately NOT the omniauth / solana controllers, which require
# host-app gems that live in the consuming apps, not in this engine.
require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"
# Active Storage backs the link-preview DEFAULT image (Studio::SiteIdentity
# has_one_attached :image). Every consumer loads it; the dummy loads it so the
# /admin/link_preview upload is exercised against the real attachment path.
require "active_storage/engine"

# The engine under test. Requiring it defines Studio::Engine < Rails::Engine,
# which auto-registers the engine's app/* paths as a railtie of this app.
require "studio"

# THE WEB3 HALF, WHICH THIS ENGINE NO LONGER SHIPS. wallet_connect and
# web3_step_up used to live in app/views/studio/modals; the two-template split
# moved them to solana-studio (BASE is studio-engine + mcritchie-studio, WEB3
# ADD is solana-studio + turf-monster) because, as the call was made, "the real
# op sec vector is managing sessions safely. Anything wallet based should be in
# the app."
#
# It is required HERE, and only here, so the style guide can render the REAL
# shipped cards instead of a fork of them — SolanaStudio::Engine registers the
# gem's app/views, which is what makes `render "solana_studio/modals/..."`
# resolve. Development and test only (see the Gemfile); it is NOT a gemspec
# runtime dependency, because four of the five apps mounting this engine
# (mcritchie-studio, acquisition-studio, mcritchie-industries, moms-app) bundle
# no solana-studio and must never be made to — turf-monster is the only one that
# does. The style guide self-gates on the partial resolving for exactly that
# reason.
#
# Requiring it after `require "rails"` above is load-bearing: lib/solana_studio.rb
# only pulls in its Rails half when Rails::Engine is already defined.
require "solana_studio"

module Dummy
  class Application < Rails::Application
    # Pin the app root to test/dummy. Without a config.ru marker, Rails' root
    # auto-detection falls back to Dir.pwd (the gem root), which would look for
    # config/database.yml in the wrong place.
    config.root = File.expand_path("..", __dir__)

    config.load_defaults 8.1

    # Autoload (don't eager-load): the engine ships controllers/concerns that
    # reference host-app-only gems (omniauth, solana-studio). Eager loading
    # would pull those in; lazy autoloading lets the boot test exercise just the
    # self-contained ErrorLog / ThemeSetting / Sluggable / route surfaces.
    config.eager_load = false
    config.consider_all_requests_local = true
    config.secret_key_base = "studio-engine-rails81-dummy-secret-key-base-not-a-real-secret"

    # Quiet the boot.
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.log_level = :fatal

    # What a real app puts in config/environments/test.rb. The dummy has no
    # environments directory, so it goes here. Forgery protection stays ON in
    # every other environment — the consume POST is CSRF-protected in the
    # apps; what the suites below prove is that the token-burning door is
    # POST-only and the GET beside it is inert.
    config.action_controller.allow_forgery_protection = false if Rails.env.test?

    # Let an unhandled exception reach the test instead of being rendered as a
    # 500 debug page. Without this, a real bug reads as "expected 3XX, got 500"
    # with the cause nowhere in the output.
    config.action_dispatch.show_exceptions = :none if Rails.env.test?

    # The engine's `studio.assets` initializer does
    # `app.config.assets.precompile += [...]`. This dummy has no asset-pipeline
    # gem (sprockets / propshaft), so seed a config.assets shim with an Array
    # precompile list the initializer can append to without raising.
    assets = ActiveSupport::OrderedOptions.new
    assets.precompile = []
    config.assets = assets

    # Disk services under tmp/, one private (the default) and one PUBLIC, so the
    # link-preview suite can prove both URL shapes: the proxy path for a private
    # service and the service's own URL for a public one.
    storage_root = File.expand_path("../tmp/storage", __dir__)
    config.active_storage.service_configurations = {
      "test" => { "service" => "Disk", "root" => storage_root },
      "test_public" => { "service" => "Disk", "root" => "#{storage_root}-public", "public" => true }
    }
    config.active_storage.service = :test
  end
end

# ---- THE DUMMY HOST'S LINK-SIDEBAR DECLARATION -------------------------------
#
# What a consuming app puts in config/initializers/studio.rb, in the CALLABLE
# form docs/NEW_APP_SETUP.md and lib/studio.rb both show for dynamic sections.
# The dummy has no initializers directory, so its host-wide Studio config lives
# here.
#
# ONE ASSIGNMENT, AT BOOT — and that is the whole point of the shape.
# `Studio.sidebar_sections` is a `mattr_accessor`: one slot for the entire
# process. E2eLabController#bar_stack used to assign it PER REQUEST from
# `?sidebar=1`, which made a process global the home of per-request state. One
# visit to /lab/bar_stack?sidebar=1 then armed the link sidebar for every request
# served afterwards; measured on the browser lane at a73edfe,
# /lab/toast_over_banner rendered 2 trigger buttons and --nav-h 145px after that
# visit against 0 and 125px before it, and no spec went red — Playwright's
# file-name ordering happened to put a page that cleared the slot in between.
# test/integration/e2e_lab_isolation_test.rb holds that seam now.
#
# The callable reads the sidebar the CURRENT request declared
# (E2eLabController#lab_sidebar_sections, set by a before_action on every lab
# action) and resolves through the engine's real
# Studio::SidebarSections.resolve, so the lab still drives the host seam a
# consumer drives — it just reads this request rather than the last one's
# leftovers. Nothing writes the global after boot, so lab pages are independent
# of both spec ORDER and, should `workers` ever rise above 1, of concurrent
# requests landing in one Puma process.
#
# HERE AND NOT IN e2e/boot.rb, unlike `Studio.app_name` and
# `Studio.theme_logos`. Those two are LANE-ONLY on purpose: several minitest
# suites interpolate the app name into expected strings, so the lane's host
# identity must not reach them. This one is the opposite — the minitest suite is
# exactly where the leak is guarded, so the declaration has to load for the
# dummy too. It changes nothing for any other controller: anything that does not
# answer `lab_sidebar_sections` resolves to [], which is the engine's documented
# default, and the suites that pin a specific sidebar
# (test/integration/sidebar_navbar_render_test.rb) assign the accessor
# themselves.
Studio.sidebar_sections = lambda do |view|
  controller = view.controller if view.respond_to?(:controller)
  # FAIL TO THE DEFAULT, not to nil. Every other page in this dummy — the two
  # PagesController landings, the geo and session lab hosts, the engine's own
  # controllers — has no lab controller behind it and must resolve to the
  # engine's documented default of NO sections. `Array()` covers the same ground
  # on the other side: a lab request whose before_action has not run yet reads
  # nil, and Studio::SidebarSections.resolve should not have to be tolerant of
  # one.
  next [] unless controller.respond_to?(:lab_sidebar_sections)

  Array(controller.lab_sidebar_sections)
end

# The site footer's facts, the way a host declares them: a callable receiving the
# view. Only the lab's footer pages carry any (E2eLabController#site_footer), so
# every other page in the dummy resolves nil and renders no footer.
Studio.site_footer = lambda do |view|
  controller = view.controller if view.respond_to?(:controller)
  controller.lab_site_footer if controller.respond_to?(:lab_site_footer)
end

# A schedule on Google's real host, so the browser lane can stub it by URL. No
# such schedule exists; nothing in the suite is allowed to reach Google.
Studio.booking_url = "https://calendar.google.com/calendar/appointments/schedules/LAB-SCHEDULE"
