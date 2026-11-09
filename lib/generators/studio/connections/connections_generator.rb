# frozen_string_literal: true

require "rails/generators"

module Studio
  module Generators
    # Adopt the connections tooling (docs/CONNECTIONS.md) in one repeatable step:
    #
    #   bin/rails g studio:connections
    #   bin/rails db:migrate
    #
    # What it does, each step idempotent (a second run changes nothing):
    #
    #   1. copies the engine's studio_connections migration into db/migrate,
    #      in exactly the form `studio_engine:install:migrations` writes (so that
    #      task later sees it and skips it), and ONLY that migration;
    #   2. writes config/initializers/studio_connections.rb, a commented example
    #      provider to fill in, unless the file exists.
    #
    # It declares no provider and draws no route: the host names each provider
    # it connects, and its routes, itself.
    class ConnectionsGenerator < Rails::Generators::Base
      MIGRATION_NAME = "create_studio_connections"
      ENGINE_SCOPE = "studio_engine"
      INITIALIZER = "config/initializers/studio_connections.rb"

      def copy_migration
        existing = Dir.glob(File.join(destination_root, "db/migrate/*_#{MIGRATION_NAME}{,.#{ENGINE_SCOPE}}.rb"))
        if existing.any?
          say_status :identical, existing.first.delete_prefix("#{destination_root}/"), :blue
          return
        end

        source = self.class.engine_migration
        original_version = File.basename(source)[/\A\d+/]
        body = "# This migration comes from #{ENGINE_SCOPE} (originally #{original_version})\n#{File.read(source)}"
        create_file "db/migrate/#{self.class.next_version}_#{MIGRATION_NAME}.#{ENGINE_SCOPE}.rb", body
      end

      def write_initializer
        if File.exist?(File.join(destination_root, INITIALIZER))
          say_status :identical, INITIALIZER, :blue
          return
        end

        create_file INITIALIZER, INITIALIZER_BODY
      end

      def next_steps
        say <<~TEXT

          Connections installed. Next:
            bin/rails db:migrate
            Declare each provider in #{INITIALIZER}, then draw its routes in config/routes.rb:
              Studio.draw_connection_routes(self, :files, path: "admin/files", controller: "admin/files")
            Or enable an integration the engine defines (docs/INTEGRATIONS.md) and mount its page:
              Studio.enable_integration :quickbooks, env: { client_id: "INTUIT_CLIENT_ID", client_secret: "INTUIT_CLIENT_SECRET" }
              Studio.draw_integrations_routes(self)
            Set the provider's client id and secret, and the app's Active Record encryption keys.
        TEXT
      end

      def self.engine_migration
        File.expand_path("../../../../db/migrate/20261108130000_#{MIGRATION_NAME}.rb", __dir__)
      end

      def self.next_version
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      INITIALIZER_BODY = <<~RUBY
        # frozen_string_literal: true

        # Integrations the engine already defines (studio-engine docs/INTEGRATIONS.md):
        # QuickBooks, Egnyte, Microsoft 365. One line each, naming this app's env
        # vars; mount the page with Studio.draw_integrations_routes(self).
        #
        # Studio.enable_integration :quickbooks,
        #   env: { client_id: "INTUIT_CLIENT_ID", client_secret: "INTUIT_CLIENT_SECRET", environment: "INTUIT_ENVIRONMENT" }
        #
        # Connections (studio-engine docs/CONNECTIONS.md). One Studio.define_connection
        # per provider this app connects; each stays off until its client id and
        # secret are set. Draw its routes in config/routes.rb with
        # Studio.draw_connection_routes. The example below is a placeholder: no
        # such provider exists.
        #
        # Studio.define_connection :files,
        #   label: "Example Files",
        #   env: { client_id: "EXAMPLE_FILES_CLIENT_ID", client_secret: "EXAMPLE_FILES_CLIENT_SECRET" },
        #   authorize_url: "https://files.example/oauth/authorize",
        #   token_url: "https://files.example/oauth/token",
        #   revoke_url: "https://files.example/oauth/revoke",
        #   scopes: %w[files.read],
        #   refresh: :rotating,
        #   account: :callback, account_param: "account_id", account_format: /\\A\\d{1,20}\\z/,
        #   filter_keys: %w[account_id]
        #
        # Who may connect (default: :require_admin from Studio::ErrorHandling):
        # Studio.connection_admin_guard = :require_admin
      RUBY
    end
  end
end
