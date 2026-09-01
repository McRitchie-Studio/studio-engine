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
# runtime dependency, because three of the apps mounting this engine
# (acquisition-studio, mcritchie-industries, moms-app) bundle no solana-studio
# and must never be made to. The style guide self-gates on the partial resolving
# for exactly that reason.
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
  end
end
