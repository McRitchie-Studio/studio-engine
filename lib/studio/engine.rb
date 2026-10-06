require_relative "log_rotation"
require_relative "component_gallery"
# Components (docs/FRONT_END_STANDARD.md). Required here, not left to the host's
# Gemfile, because every app takes ViewComponent through this engine.
#
# Lookbook, the gallery, is NOT required here: an app that wants it bundles it
# (see the gemspec), and Bundler.require loads it. Listed AFTER studio-engine, so
# view_component is required first: its after_initialize, which decides whether
# to draw its own preview routes, must run before Lookbook's, which turns
# previews on for its own use. Studio::ComponentGallery.load_order_ok? records
# the order this file saw.
Studio::ComponentGallery.lookbook_loaded_before_engine = defined?(::Lookbook::Engine) ? true : false
require "view_component"

module Studio
  class Engine < ::Rails::Engine
    # Cap the local (development + test) log files, for every host app and
    # every future one, with nobody running anything.
    #
    # ORDERING IS THE WHOLE TRICK — do not demote this to a bare initializer.
    # Rails' `:initialize_logger` is a BOOTSTRAP initializer, so it runs before
    # every railtie/engine initializer and does `Rails.logger ||= config.logger
    # || <default>`. An engine that assigns `app.config.logger` from an ordinary
    # initializer is a silent NO-OP: Rails.logger is already built. Verified,
    # not assumed — a probe boot kept Rails' 100 MB cap and its own file.
    # So this hands Rails the size BEFORE Rails builds the logger, which is
    # exactly the knob `:initialize_logger` reads:
    #   ActiveSupport::Logger.new(config.default_log_file, 1, config.log_file_size)
    # and Rails keeps ownership of the path, formatter, level, and tagging.
    #
    # `after: :load_environment_hook` pins the lower edge of that window for two
    # reasons: config/environments/*.rb is loaded by `:load_environment_config`
    # (declared `before: :load_environment_hook`), so the host's own choices are
    # already visible here; and it keeps Railtie's implicit `after: <previous
    # initializer>` chaining from dragging `studio.assets` forward with us.
    # WHICH cap (and whether to touch anything at all) is Studio::LogRotation's
    # decision — Rails-free, and unit-tested a branch at a time.
    #
    # The host's escape hatch, `Studio.local_log_max_bytes`, is read here rather
    # than from config.x.<key>: an unset config.x key returns an empty
    # ActiveSupport::OrderedOptions, NOT nil, so `config.x.foo || default`
    # silently assigns the OrderedOptions and rotation then dies inside a
    # rescued comparison. The behavioral test caught that; a config read-back
    # would have called it green.
    initializer "studio.logger", before: :initialize_logger, after: :load_environment_hook do |app|
      cap = Studio::LogRotation.cap_for(
        env: Rails.env,
        host_logger: app.config.logger,
        override: Studio.local_log_max_bytes
      )
      app.config.log_file_size = cap if cap
    end

    initializer "studio.assets" do |app|
      app.config.assets.precompile += %w[
        studio/sticky_table_header.css
        studio/sticky_table_header.js
        studio/alpine.js
        studio/canvas_confetti.js
        studio/studio_confetti.js
        studio/sortable.js
        studio/leaflet.js
        studio/leaflet.css
        studio/session.js
        studio/montserrat-latin.woff2
        studio/montserrat-latin-ext.woff2
      ]

      # The INHERITED default email banners (Studio::EmailImage). They ride the
      # gem so a brand-new app sends branded email on day one with an empty S3
      # bucket. Enumerated from disk rather than listed by hand so adding a
      # default is a one-file change. Sprockets hosts (mcritchie-studio,
      # turf-monster) need the explicit precompile entry; propshaft hosts
      # (mcritchie-industries, moms-app) serve everything on config.assets.paths
      # and ignore this list.
      # Named on the CLASS, not bare: an initializer block is instance_exec'd on
      # an Engine INSTANCE, where a bare call resolves to nothing and boots red.
      app.config.assets.precompile += Studio::Engine.default_email_banner_logical_paths

      # The subdivision flags behind the shared geo badge. Same reasoning as the
      # banners above: a sprockets host needs each logical path enumerated, and
      # enumerating from disk means adding a flag is a one-file change. Only the
      # US set ships — every other country's badge renders an emoji flag, which
      # costs no bytes at all.
      app.config.assets.precompile += Studio::Engine.subdivision_flag_logical_paths

      # The engine's ES modules (app/javascript), which config/importmap.rb pins.
      # On the asset paths so an importmap pin resolves on sprockets and propshaft
      # alike, and enumerated for sprockets' precompile list like the banners.
      javascript_root = Studio::Engine.root.join("app/javascript").to_s
      if app.config.assets.respond_to?(:paths) && app.config.assets.paths.is_a?(Array)
        app.config.assets.paths << javascript_root unless app.config.assets.paths.map(&:to_s).include?(javascript_root)
      end
      app.config.assets.precompile += Studio::Engine.javascript_module_logical_paths
    end

    # ---- THE ENGINE'S IMPORTMAP PINS ------------------------------------------
    #
    # A host draws the engine's pins with no edit of its own: this adds the
    # engine's config/importmap.rb to importmap-rails' list of maps BEFORE
    # importmap-rails draws them (its "importmap" initializer appends the host's
    # config/importmap.rb last). The host's map is drawn after the engine's, so a
    # host that pins the same name wins. This is the mechanism importmap-rails
    # documents for engines ("Composing import maps").
    #
    # The contract a module joins by being here:
    #   - it lives under app/javascript/studio/ and is pinned as "studio/<name>";
    #   - pins are NOT preloaded, so a page fetches only the modules it imports;
    #   - its logical asset path shares the studio/ prefix with the classic
    #     scripts in app/assets/javascripts/studio, so a module may not reuse one
    #     of those names (test/integration/engine_importmap_pins_test.rb).
    # A host without importmap-rails (a footer-only consumer) skips this.
    initializer "studio.importmap", before: "importmap" do |app|
      next unless app.config.respond_to?(:importmap)

      app.config.importmap.paths << Studio::Engine.root.join("config/importmap.rb")
      app.config.importmap.cache_sweepers << Studio::Engine.root.join("app/javascript")
    end

    # ---- COMPONENTS AND THE GALLERY -------------------------------------------
    #
    # ViewComponent reads its preview settings in "view_component.set_configs",
    # so these land first. The previews live in app/components/previews, which
    # is its own autoload root (below): Studio::BadgeComponentPreview, not
    # Previews::Studio::BadgeComponentPreview. ViewComponent's own preview pages
    # move behind the admin wall (PREVIEWS_ROUTE, PREVIEWS_CONTROLLER), and each
    # preview renders in a layout carrying the host's stylesheets.
    paths.add "app/components/previews", autoload: true

    initializer "studio.view_component", before: "view_component.set_configs" do |app|
      previews = app.config.view_component.previews
      preview_path = Studio::Engine.root.join("app/components/previews").to_s
      previews.paths << preview_path unless previews.paths.include?(preview_path)
      previews.route = Studio::ComponentGallery::PREVIEWS_ROUTE
      previews.controller = Studio::ComponentGallery::PREVIEWS_CONTROLLER
      previews.default_layout = Studio::ComponentGallery::PREVIEW_LAYOUT
    end

    # Lookbook's settings, before Lookbook's after_initialize reads them and
    # before the host's config/initializers, so a host can still change one.
    #
    # It also takes Lookbook's UI assets off the public middleware stack.
    # Lookbook serves /lookbook-assets through a Rack::Static it adds for every
    # request; Studio.routes serves the same files from inside the admin
    # constraint instead, so an app that does not draw the gallery serves none
    # of Lookbook and a visitor never learns it is there. The delete matches by
    # class, so a host cannot add a Rack::Static of its own (none does).
    initializer "studio.component_gallery", after: "lookbook.assets.serve" do
      next unless Studio::ComponentGallery.lookbook_loaded?

      unless Studio::ComponentGallery.load_order_ok?
        warn "studio-engine: lookbook was required before studio-engine; list it after " \
             "studio-engine in the Gemfile so ViewComponent decides its preview routes first"
      end
      Studio::ComponentGallery.configure_lookbook!(::Lookbook.config)
      config.app_middleware.delete(::Rack::Static)
    end

    # Logical asset paths ("emails/magic-link.png") for every default banner the
    # gem ships.
    def self.default_email_banner_logical_paths
      Dir[File.expand_path("../../app/assets/images/emails/*", __dir__)]
        .select { |path| File.file?(path) }
        .map { |path| "emails/#{File.basename(path)}" }
        .sort
    end

    # Logical asset paths ("studio/local_path.js") for every ES module the
    # engine pins (config/importmap.rb).
    def self.javascript_module_logical_paths
      base = File.expand_path("../../app/javascript", __dir__)
      Dir[File.join(base, "**/*.js")]
        .select { |path| File.file?(path) }
        .map { |path| path.delete_prefix("#{base}/") }
        .sort
    end

    # Logical asset paths ("state-flags/wa.svg") for every subdivision flag the
    # gem ships.
    # Both the vector art and the small rasters behind it: the badge renders one
    # SVG, /admin/geo's grid renders 52 PNGs (the SVG set is ~10 MB of real
    # vector art, which is not a page's worth of downloads for 16px squares).
    def self.subdivision_flag_logical_paths
      Dir[File.expand_path("../../app/assets/images/state-flags/*", __dir__),
          File.expand_path("../../app/assets/images/state-flags/thumb/*", __dir__)]
        .select { |path| File.file?(path) }
        .map { |path| path.include?("/thumb/") ? "state-flags/thumb/#{File.basename(path)}" : "state-flags/#{File.basename(path)}" }
        .sort
    end

    rake_tasks do
      load File.expand_path("../tasks/studio_email.rake", __dir__)
      load File.expand_path("../tasks/studio_ses.rake", __dir__)
    end

    # ---- A FOOTER-ONLY CONSUMER: a host with no ActiveRecord ------------------
    #
    # An app with no database can take the engine for its site footer alone
    # (docs/SITE_FOOTER.md, "An app with no database"). Each block below changes
    # nothing for a host that loads ActiveRecord; each one used to be a
    # workaround in the consumer (rantly). Studio.active_record? is the switch.
    # test/integration/footer_only_consumer_test.rb boots that host.

    # The engine's app/ roots a footer-only host must not EAGER load: every one
    # but app/helpers. Its models subclass ApplicationRecord, its controllers
    # skip :require_authentication, its mailers and jobs subclass ActionMailer
    # and ActiveJob, and the two concerns roots (app/controllers/concerns,
    # app/models/concerns) are roots of their OWN to Zeitwerk: excluding
    # app/models does not exclude app/models/concerns, and Sluggable sits
    # there. They stay lazily loadable, and nothing in a
    # host that draws no Studio.routes asks for them.
    #
    # Read off the engine's own eager-load paths rather than listed, so a root
    # added later is excluded by default: the footer-only surface is the helpers
    # (studio_site_footer and its siblings), and a new root earns a place beside
    # them by being made to load without ActiveRecord.
    FOOTER_ONLY_EAGER_ROOTS = %w[app/helpers].freeze

    def self.active_record_dependent_roots
      root_path = root.to_s
      config.all_eager_load_paths.map(&:to_s)
            .select { |path| path.start_with?("#{root_path}/") && File.directory?(path) }
            .reject { |path| FOOTER_ONLY_EAGER_ROOTS.include?(path.delete_prefix("#{root_path}/")) }
            .sort
    end

    initializer "studio.footer_only_eager_load" do
      next if Studio.active_record?

      Studio::Engine.active_record_dependent_roots.each do |path|
        Rails.autoloaders.main.do_not_eager_load(path)
      end
    end

    # `studio_engine:install:migrations` with no ActiveRecord. Rails defines it
    # for every engine that ships db/migrate, and it invokes
    # `railties:install:migrations`, which only ActiveRecord's tasks define, so
    # it raised and rake exited 1. The hub's release sweep runs it in every
    # member after each engine publish (mcritchie-studio bin/release.rb,
    # install_engine_migrations!) and aborts on a non-zero exit. With no
    # ActiveRecord, Rails' version is not drawn (has_migrations? below) and this
    # one says so and exits 0, writing nothing.
    rake_tasks do
      next if Studio.active_record?

      namespace railtie_name do
        namespace :install do
          desc "No-op: this app loads no ActiveRecord, so it installs none of studio-engine's migrations"
          task :migrations do
            puts "studio-engine: this app loads no ActiveRecord, so there are no migrations to install"
          end
        end
      end
    end

    private

    # Rails' engine reads this to decide whether to draw
    # `<engine>:install:migrations` (Rails::Engine, its rake_tasks block).
    def has_migrations?
      Studio.active_record? && super
    end

    public

    # Survey definitions (docs/SURVEYS.md): every *.rb under
    # Studio.survey_definitions_path, loaded on boot and again on each
    # development reload so an edited definition takes effect without a restart.
    # Surveys defined in an initializer instead stay registered either way.
    config.to_prepare do
      dir = Studio.survey_definitions_path
      Studio::Survey.load_definitions!(Rails.root.join(dir)) if dir.present? && Rails.root
    end

    config.after_initialize do
      # Configure the IP -> location provider for every app that has the gem,
      # so geo detection works the same way everywhere: HTTPS (without which
      # ipinfo silently returns nothing), a 3s timeout, and a Rails.cache-backed
      # IP cache. AFTER initialize, because the cache duck needs Rails.cache to
      # exist. An app that configures Geocoder itself sets
      # Studio.configure_geocoder = false — or simply configures Geocoder itself,
      # which `force: false` leaves alone. An app with no geocoder gem is
      # unaffected either way (configure! returns false and does nothing).
      Studio::Geo::Lookup.configure!(force: false) if Studio.configure_geocoder

      # Validate the host app's User model satisfies the engine's contract.
      # See docs/USER_CONTRACT.md. Opt out with Studio.validate_user_contract = false.
      #
      # ONLY A HOST WITH ACTIVERECORD, and only an ActiveRecord User. The
      # contract is what the engine's sign-in, admin and error-log surfaces call
      # on a user RECORD, and every one of them needs a database. A host with no
      # ActiveRecord (a footer-only consumer) has no such surface to break, and
      # a ::User it does define is its own business: rantly's is a sample
      # profile read from YAML. The rule is ActiveRecord's absence rather than
      # "drew no Studio.routes", because the routes are drawn after this check's
      # inputs exist and an app can call the helpers without drawing them.
      if Studio.active_record? && defined?(::User) && ::User.is_a?(Class) &&
         ::User.ancestors.include?(::ActiveRecord::Base)
        Studio.validate_user_contract!(::User)
      end
    end

  end
end
