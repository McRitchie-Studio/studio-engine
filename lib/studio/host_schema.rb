# frozen_string_literal: true

module Studio
  # The columns the engine's models write on tables the HOST holds: error_logs,
  # theme_settings and image_caches. The engine's Ensure*Table migrations create
  # or complete those tables; this checks, at boot, that the host has actually
  # run them, so a missing column is named at startup instead of surfacing later
  # as a 500 on the first save that writes it (a theme save on a host without
  # theme_settings.slug was the case that prompted it).
  #
  # The check is one-directional: it looks only for REQUIRED columns that are
  # absent. Extra columns, extra indexes, a different NOT NULL or a different
  # type are the host's business and never reported.
  #
  # HOW LOUD, per environment (Studio.host_schema_check):
  #
  #   :raise  development and test, by default. A developer or a CI suite sees
  #           Studio::HostSchemaError at boot with the table, the column and the
  #           two commands that fix it.
  #   :log    every other environment (production, and QA, which runs as
  #           production), by default. Rails.logger.error plus a Sentry message
  #           when the host loads sentry-ruby. It never raises there, for two
  #           reasons. Heroku's release phase boots the app to run db:migrate,
  #           the very command that adds the column, so a raise at boot would
  #           make the fix undeployable. And a missing column breaks the one
  #           surface that writes it (an admin theme save, an email banner
  #           upload); taking every page down to report it trades a small
  #           outage for a total one.
  #   false   off.
  #
  # The check never runs inside a rake task (db:migrate, install:migrations,
  # assets:precompile): those boot the app precisely to change or ignore the
  # schema, and a report there would be wrong by the time the task finishes. It
  # also stays quiet when the database cannot be reached; it has nothing to say
  # about a schema it cannot read.
  module HostSchema
    REQUIRED_COLUMNS = {
      "error_logs" => %w[
        slug message inspect backtrace
        target_type target_id target_name
        parent_type parent_id parent_name
        created_at updated_at
      ].freeze,
      "theme_settings" => %w[
        app_name slug primary dark light accent1 accent2 warning danger
        created_at updated_at
      ].freeze,
      "image_caches" => %w[
        owner_type owner_id purpose variant s3_key source_url content_type bytes
        created_at updated_at
      ].freeze
    }.freeze

    MODES = [:raise, :log, false].freeze

    module_function

    # { "table" => ["missing", "columns"] } for every required table that is
    # absent (all its columns listed) or short of a column. Empty when the host
    # satisfies the contract.
    def missing_columns(connection)
      REQUIRED_COLUMNS.each_with_object({}) do |(table, required), missing|
        present = connection.table_exists?(table) ? connection.columns(table).map(&:name) : []
        absent = required - present
        missing[table] = absent if absent.any?
      end
    end

    def message(missing)
      lines = missing.map do |table, columns|
        if columns == REQUIRED_COLUMNS[table]
          "  #{table}: the table is missing"
        else
          "  #{table}: missing #{columns.join(', ')}"
        end
      end

      <<~MSG
        studio-engine: this app's database is missing columns the engine's models write.

        #{lines.join("\n")}

        Install and run the engine's migrations (they create a missing table, add
        a missing column and change nothing else):

          bin/rails studio_engine:install:migrations
          bin/rails db:migrate

        Set Studio.host_schema_check = false in config/initializers/studio.rb to
        silence this check.
      MSG
    end

    # The mode in force: the host's Studio.host_schema_check, or :raise in
    # development and test and :log everywhere else.
    def mode(setting: Studio.host_schema_check, env: Rails.env)
      return setting unless setting.nil?

      env.development? || env.test? ? :raise : :log
    end

    # The boot hook. Returns the missing-columns hash it found (empty when the
    # host is whole or the check was skipped) and acts on it per `mode`.
    def check!(connection: nil, mode: self.mode, logger: Rails.logger)
      return {} if mode == false

      missing =
        begin
          if connection
            missing_columns(connection)
          else
            ActiveRecord::Base.connection_pool.with_connection { |conn| missing_columns(conn) }
          end
        rescue ActiveRecord::ActiveRecordError => e
          logger&.debug("[studio-engine] host schema check skipped: #{e.class}: #{e.message}")
          return {}
        end
      return missing if missing.empty?

      text = message(missing)
      raise Studio::HostSchemaError, text if mode == :raise

      logger&.error("[studio-engine] #{text}")
      report_to_sentry(text)
      missing
    end

    # True while a rake task is running: the app booted to migrate, install or
    # precompile, not to serve.
    def inside_rake_task?
      defined?(::Rake) && ::Rake.respond_to?(:application) &&
        ::Rake.application.respond_to?(:top_level_tasks) &&
        ::Rake.application.top_level_tasks.any?
    end

    def report_to_sentry(text)
      return unless defined?(::Sentry) && ::Sentry.respond_to?(:capture_message)

      ::Sentry.capture_message(text, level: :error)
    rescue StandardError
      nil
    end
  end
end
