require_relative "log_rotation"

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
    end

    # Logical asset paths ("emails/magic-link.png") for every default banner the
    # gem ships.
    def self.default_email_banner_logical_paths
      Dir[File.expand_path("../../app/assets/images/emails/*", __dir__)]
        .select { |path| File.file?(path) }
        .map { |path| "emails/#{File.basename(path)}" }
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
      if defined?(::User) && ::User.is_a?(Class) &&
         (!defined?(::ActiveRecord::Base) || ::User.ancestors.include?(::ActiveRecord::Base))
        Studio.validate_user_contract!(::User)
      end
    end
  end
end
