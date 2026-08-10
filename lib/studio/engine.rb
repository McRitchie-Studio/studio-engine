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
        studio/canvas_confetti.js
        studio/studio_confetti.js
        studio/sortable.js
      ]
    end

    rake_tasks do
      load File.expand_path("../tasks/studio_email.rake", __dir__)
      load File.expand_path("../tasks/studio_ses.rake", __dir__)
    end

    config.after_initialize do
      # Validate the host app's User model satisfies the engine's contract.
      # See docs/USER_CONTRACT.md. Opt out with Studio.validate_user_contract = false.
      if defined?(::User) && ::User.is_a?(Class) &&
         (!defined?(::ActiveRecord::Base) || ::User.ancestors.include?(::ActiveRecord::Base))
        Studio.validate_user_contract!(::User)
      end
    end
  end
end
