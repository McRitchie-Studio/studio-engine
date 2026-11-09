# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"

module Studio
  # INTEGRATIONS: the engine's registry of integration CONNECTION definitions
  # (docs/INTEGRATIONS.md), on top of the generic connection tooling
  # (Studio::Connections, docs/CONNECTIONS.md).
  #
  # The engine ships one definition per integration it knows (QuickBooks,
  # Egnyte, Microsoft 365). A definition holds the connection only: the URLs,
  # the scopes, the token behaviour, and a minimal describe that names the
  # account just connected (the company, the user, the organization). It holds
  # NO reader and makes no business-data call: a host writes its own readers
  # and plugs them into the integration's page with a panel.
  #
  # A host turns one on with one line in an initializer, naming its own env vars:
  #
  #   Studio.enable_integration :quickbooks,
  #     env: { client_id: "INTUIT_CLIENT_ID", client_secret: "INTUIT_CLIENT_SECRET",
  #            environment: "INTUIT_ENVIRONMENT" },
  #     panel: "admin/integrations/quickbooks_panel"
  #
  # and mounts the admin page with Studio.draw_integrations_routes. An enabled
  # integration stays off (Connect says which env vars are missing) until its
  # client id and secret are set.
  module Integrations
    # Seconds to open the describe call's connection, and to read its answer.
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20

    # One integration the engine knows: the connection only.
    #
    #   key             the integration's key, and its connection's
    #   label           the name on the page and every message
    #   summary         one line on the page: what connecting it gives the host
    #   connection      the Studio::Connections::Provider options, every one but
    #                   env:, label: and describe:
    #   settings        extra env vars a host may name besides the client id and
    #                   secret: { name: { values: [...], default: "..." } }; a
    #                   value outside `values` reads as the default
    #   account_label   the Connect form's field label (account: :connect only)
    #   account_hint    its placeholder
    #   metadata        ->(integration) { Hash }: stored on every new connection,
    #                   with no network call (the provider environment)
    #   describe        ->(integration, grant:, account:, get:) { { label:, metadata: } }:
    #                   names the account just connected with ONE call through
    #                   `get` (->(url, token) { JSON Hash }); a Connections::Error
    #                   there stores the connection under default_label
    #   default_label   ->(account) { String }: the label when describe cannot say
    #   api_base        ->(integration, connection) { String }: where the host's
    #                   own readers send their calls for this connection
    #   stand_in        { callback_params: {...}, answer: {...} }: what the
    #                   stand-in's sign-in page sends back, and what its describe
    #                   call answers (development and test only)
    Definition = Struct.new(:key, :label, :summary, :connection, :settings, :account_label, :account_hint,
                            :metadata, :describe, :default_label, :api_base, :stand_in, keyword_init: true)

    # The statuses an enabled integration can be in, in order.
    STATUSES = {
      not_set_up: "Not set up",
      ready: "Ready to connect",
      connected: "Connected"
    }.freeze

    class << self
      # Adds a definition to the engine's catalog. The engine's own definitions
      # register themselves when lib/studio/integrations/*.rb loads.
      def register(key, **fields)
        definition = Definition.new(key: key.to_s, settings: {}, metadata: ->(_integration) { {} },
                                    default_label: nil, stand_in: {}, **fields)
        definition.settings = definition.settings.to_h.transform_keys(&:to_sym)
        lock.synchronize { catalog_map[definition.key] = definition.freeze }
      end

      # Every integration the engine knows, enabled or not.
      def catalog = lock.synchronize { catalog_map.values }

      def definition(key)
        lock.synchronize { catalog_map[key.to_s] } or
          raise ArgumentError, "the engine has no integration #{key.to_s.inspect}; it knows #{catalog.map(&:key).join(', ')}"
      end

      # Turns an integration on: defines its connection (Studio.define_connection)
      # with the host's env names, and adds it to the admin page.
      def enable(key, env:, panel: nil, label: nil, scopes: nil)
        integration = Integration.new(definition(key), env:, panel:, label:, scopes:)
        lock.synchronize { enabled_map[integration.key] = integration }
        integration
      end

      # The enabled integrations, in the order the host enabled them.
      def all = lock.synchronize { enabled_map.values }

      def enabled?(key) = lock.synchronize { enabled_map.key?(key.to_s) }

      def fetch(key)
        lock.synchronize { enabled_map[key.to_s] } or raise ArgumentError, "the integration #{key.to_s.inspect} is not enabled"
      end

      # Where draw_integrations_routes mounted the page ("admin/integrations").
      attr_accessor :mount_path

      # Forgets every enabled integration (not the catalog). Tests only.
      def reset!
        lock.synchronize do
          enabled_map.clear
          @mount_path = nil
        end
      end

      private

      def catalog_map = (@catalog_map ||= {})
      def enabled_map = (@enabled_map ||= {})
      def lock = (@lock ||= Monitor.new)
    end

    # One integration a host enabled: its definition, the host's env names, its
    # connection provider and the host's panel.
    class Integration
      attr_reader :definition, :env, :panel, :provider

      # Stand-in for the describe call: (url, headers) -> [status, body]. nil
      # means the provider itself. Refused outside development and test.
      attr_reader :api_http

      def initialize(definition, env:, panel: nil, label: nil, scopes: nil)
        @definition = definition
        @env = env.to_h.transform_keys(&:to_sym)
        unknown = @env.keys - %i[client_id client_secret] - definition.settings.keys
        raise ArgumentError, "#{key}: env names client_id, client_secret#{definition.settings.keys.map { ", #{_1}" }.join}; not #{unknown.join(', ')}" if unknown.any?
        raise ArgumentError, "#{key}: env values are env var names (Strings)" unless @env.values.all?(String)

        @panel = panel&.to_s
        options = definition.connection.merge(
          label: label || definition.label,
          env: @env.slice(:client_id, :client_secret),
          describe: ->(grant:, account:, provider:) { describe_account(grant:, account:) }
        )
        options[:scopes] = Array(scopes) if scopes
        @provider = Studio.define_connection(definition.key, **options)
      end

      def key = definition.key
      def label = provider.label
      def summary = definition.summary

      # A setting's value from the host's env var: one of its values, else its default.
      def setting(name)
        spec = definition.settings.fetch(name.to_sym)
        value = @env[name.to_sym] && ENV[@env[name.to_sym]].to_s.strip.downcase
        spec[:values].include?(value) ? value : spec[:default]
      end

      # Every connection of this integration this server can read, newest first.
      def connections = Studio::Connection.readable(key)

      # What keeps a Connect from starting here, as sentences (empty when none).
      def missing
        reasons = []
        unless provider.connectable?
          unset = provider.env_names.reject { |name| ENV[name].to_s.strip != "" }
          reasons << "#{unset.join(' and ')} #{unset.one? ? 'is' : 'are'} not set."
        end
        reasons << "The app's Active Record encryption keys are not set." unless Studio::Connections.encryption_ready?
        reasons
      end

      # :not_set_up, :ready or :connected (STATUSES).
      def status
        return :not_set_up if missing.any?

        connections.any? ? :connected : :ready
      end

      def status_label = STATUSES.fetch(status)

      # Where the host's readers send their calls for `connection`.
      def api_base(connection) = definition.api_base.call(self, connection)

      def api_http=(callable)
        unless callable.nil? || Studio::Connections.seams_allowed?
          raise Studio::Connections::Error, "#{label}: the describe stand-in is for tests, the e2e lane and a local demo (development and test only)"
        end

        @api_http = callable
      end

      # Stands the whole integration in: the provider's sign-in page and token
      # endpoints (Studio::Connections::StandIn) and the describe call.
      # Development and test only; refused anywhere else.
      def install_stand_in!(access_lifetime: 3600)
        answer = definition.stand_in.fetch(:answer, {}).to_json
        self.api_http = ->(_url, _headers) { [200, answer] }
        Studio::Connections::StandIn.install!(provider, callback_params: definition.stand_in.fetch(:callback_params, {}), access_lifetime:)
        self
      end

      def uninstall_stand_in!
        self.api_http = nil
        Studio::Connections::StandIn.uninstall!(provider)
        self
      end

      # The provider's describe hook: the definition's metadata, then its one
      # describe call. A refusal there keeps the metadata and the default label.
      def describe_account(grant:, account:)
        metadata = definition.metadata.call(self).to_h
        described = {}
        if definition.describe
          begin
            described = definition.describe.call(self, grant:, account:, get: method(:describe_get)).to_h.symbolize_keys
          rescue Studio::Connections::Error => e
            Rails.logger.warn("[studio_integration] describe #{key} refused: #{e.class}") if defined?(::Rails) && ::Rails.logger
          end
        end
        label = described[:label].to_s.strip.presence || definition.default_label&.call(account)
        { label:, metadata: metadata.merge(described[:metadata].to_h) }.compact
      end

      private

      # The describe call's one GET: a bearer token, JSON back. Raises
      # Studio::Connections::Error (RateLimited on a 429) on anything but a 200.
      def describe_get(url, token)
        headers = { "Authorization" => "Bearer #{token}", "Accept" => "application/json" }
        status, body = api_http ? api_http.call(url, headers) : request(url, headers)
        json = begin
          JSON.parse(body.to_s)
        rescue JSON::ParserError
          {}
        end
        json = {} unless json.is_a?(Hash)
        raise Studio::Connections::RateLimited, "#{label} is throttling this app (429)" if status == 429
        raise Studio::Connections::Error, "#{label} answered #{status} to the describe call" unless status == 200

        json
      end

      def request(url, headers)
        uri = URI(url)
        raise Studio::Connections::Error, "#{label}: a describe call must be https" unless uri.scheme == "https"

        get = Net::HTTP::Get.new(uri)
        headers.each { |name, value| get[name] = value }
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { _1.request(get) }
        [response.code.to_i, response.body]
      rescue *Studio::Connections::NETWORK_ERRORS => e
        raise Studio::Connections::Error, "#{label} could not be reached: #{e.class}"
      end
    end
  end
end
