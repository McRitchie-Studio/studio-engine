module Studio
  class Engine < ::Rails::Engine
    # Byte caps for the host app's LOCAL log files. Deliberate values, not
    # defaults: Rails' own `config.load_defaults "7.1"` sets log_file_size to
    # 100 MB for development AND test, and keeps one rotated sibling — so a
    # stock app carries up to ~400 MB of log per checkout, times every worktree.
    # 16 MB still holds a full day of local request logs; 8 MB covers a whole
    # test run. Raising these is a decision, not a default.
    DEVELOPMENT_LOG_MAX_BYTES = 16 * 1024 * 1024
    TEST_LOG_MAX_BYTES        = 8 * 1024 * 1024

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
    initializer "studio.logger", before: :initialize_logger, after: :load_environment_hook do |app|
      # Local envs only. Production (and QA, which boots as production) sends
      # its stream to STDOUT for the platform to take; never touch that.
      next unless Rails.env.local?
      # A host that named its own logger has already decided. Leave it alone.
      next if app.config.logger
      # Host escape hatch. Set from config/application.rb (after `require
      # "studio"`) or config/environments/*.rb — both load before this runs,
      # whereas config/initializers/studio.rb does not:
      #   Studio.local_log_max_bytes = false          # opt out entirely
      #   Studio.local_log_max_bytes = 64.megabytes   # choose your own cap
      #
      # Deliberately NOT config.x.<key>: an unset config.x key returns an empty
      # ActiveSupport::OrderedOptions, not nil, so `config.x.foo || default`
      # silently assigns the OrderedOptions and rotation dies in a rescued
      # comparison. Caught by the behavioral test, invisible to a config read-back.
      next if Studio.local_log_max_bytes == false

      app.config.log_file_size =
        Studio.local_log_max_bytes ||
        (Rails.env.test? ? TEST_LOG_MAX_BYTES : DEVELOPMENT_LOG_MAX_BYTES)
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
