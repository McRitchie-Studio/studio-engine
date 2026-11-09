# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"
require "base64"
require "set"

module Studio
  # CONNECTIONS: the generic tooling a host app uses to connect a third-party
  # account over OAuth 2.0 (docs/CONNECTIONS.md). The tooling knows no provider.
  # A host declares each one in an initializer, and the engine gives it:
  #
  #   * Studio::Connection, one table (studio_connections) holding one row per
  #     provider and account, with the tokens encrypted (bin/rails g studio:connections);
  #   * the OAuth plumbing on the Provider below: state, the authorize URL, the
  #     code exchange, the refresh policy, the revoke, and two test seams;
  #   * Studio::ConnectionFlow, the connect, callback and disconnect actions,
  #     and Studio.draw_connection_routes, which draws them;
  #   * the log filter for the keys a provider names (LOG_FILTER).
  #
  #   Studio.define_connection :files,
  #     label: "Acme Files",
  #     env: { client_id: "ACME_CLIENT_ID", client_secret: "ACME_CLIENT_SECRET" },
  #     authorize_url: ->(account) { "https://#{account}.files.example/oauth/authorize" },
  #     token_url: ->(account) { "https://#{account}.files.example/oauth/token" },
  #     scopes: %w[files.read],
  #     refresh: :cached, refresh_margin: 1.day,
  #     account: :connect, account_param: "domain", account_format: /\A[a-z0-9-]{1,63}\z/
  #
  # Provider specifics (endpoints, scopes, quirks, readers, the admin page's
  # live read) belong to the host. Nothing in this file is named after a vendor:
  # the engine's own definitions live in Studio::Integrations (docs/INTEGRATIONS.md).
  module Connections
    # What reaching a provider can raise below HTTP: TLS, refused, timed out, DNS.
    NETWORK_ERRORS = [OpenSSL::SSL::SSLError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout].freeze

    ENCRYPTION_ENV = %w[ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
                        ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT].freeze

    # Every refusal below. A provider that names a trace_header (Intuit's
    # intuit_tid) puts the answering call's trace id on the error: as #trace_id,
    # and in the message, so the error log and the page carry it. Never a token.
    class Error < StandardError
      attr_reader :trace_header, :trace_id

      def initialize(message = nil, trace_header: nil, trace_id: nil)
        @trace_header = trace_header
        @trace_id = trace_id.to_s.strip.presence
        super(@trace_id && message ? "#{message} [#{@trace_header}: #{@trace_id}]" : message)
      end
    end
    # The provider's client id or secret is not set on this server.
    class NotConfigured < Error; end
    # The provider no longer honours the stored grant: revoked, expired, superseded.
    class Revoked < Error; end
    # The provider is throttling this app or this token.
    class RateLimited < Error; end

    # Where the browser leg starts, per grant.
    GRANTS = %i[authorization_code client_credentials].freeze
    # How an access token is obtained after the browser leg:
    #   :rotating  refresh on every call, under the row's lock, storing the
    #              answered refresh token before the access token is used; no
    #              access token is stored
    #   :cached    keep the access token, encrypted, and refresh it under the
    #              row's lock only within refresh_margin of its expiry (or after
    #              a 401, named by `stale:`), storing the new pair before use
    #   :memory    the client-credentials grant: no refresh token exists, and the
    #              access token lives in this process's memory only
    REFRESH_POLICIES = %i[rotating cached memory].freeze
    # Where the account a row is keyed by comes from:
    #   :connect   the admin names it before Connect (a form param); it is kept
    #              in the session, and the callback never reads it from its query
    #   :callback  the provider names it on the callback (a query param)
    #   :described the host's describe hook names it after the exchange
    ACCOUNT_SOURCES = %i[connect callback described].freeze
    CLIENT_AUTH = %i[form basic secret_only].freeze

    # An account that fails the provider's format: it never reaches a URL or a row.
    class InvalidAccount < ArgumentError; end

    # One provider's drawn routes: where they live, the controller serving
    # them, the route-name prefix, and the return_to allowlist (first = default).
    Route = Struct.new(:provider, :path, :as, :controller, :return_paths, keyword_init: true)

    class << self
      def define(key, **options)
        provider = Provider.new(key, **options)
        registry_lock.synchronize do
          @filter_keys = nil
          registry[provider.key] = provider
        end
      end

      def fetch(key)
        registry_lock.synchronize { registry[key.to_s] } or raise ArgumentError, "no connection provider is defined as #{key.to_s.inspect}"
      end

      def defined?(key) = registry_lock.synchronize { registry.key?(key.to_s) }
      def all = registry_lock.synchronize { registry.values }

      # Forgets every provider and route. Tests only.
      def reset!
        registry_lock.synchronize do
          registry.clear
          routes.clear
          @filter_keys = @controllers = nil
        end
      end

      # The routes Studio.draw_connection_routes drew, by provider key.
      def routes = (@routes ||= {})
      def route(key) = registry_lock.synchronize { routes[key.to_s] }

      def record_route(route)
        registry_lock.synchronize do
          @controllers = nil
          routes[route.provider] = route
        end
      end

      # The controllers that serve a callback, as params["controller"] names them.
      # Memoized: the log filter asks on every logged parameter.
      def controllers = @controllers || registry_lock.synchronize { @controllers ||= routes.values.map(&:controller).to_set.freeze }

      # Every exact key a provider asked to keep out of the logs.
      def filter_keys = @filter_keys || registry_lock.synchronize { @filter_keys ||= registry.values.flat_map(&:filter_keys).to_set.freeze }

      # Can this app store a connection: are its Active Record encryption keys set?
      def encryption_ready?
        return false unless defined?(::ActiveRecord::Encryption)

        config = ::ActiveRecord::Encryption.config
        config.has_primary_key?.present? && config.has_key_derivation_salt?.present?
      end

      # True on a production server.
      def production?
        defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.production?
      end

      # The test seams are allowed only in development and test (or with no
      # Rails at all): a staging or QA environment refuses them as production does.
      def seams_allowed?
        return true unless defined?(::Rails) && ::Rails.respond_to?(:env)

        ::Rails.env.development? || ::Rails.env.test?
      end

      private

      def registry = (@registry ||= {})
      def registry_lock = (@registry_lock ||= Monitor.new)
    end

    # THE LOG FILTER, which the engine appends to config.filter_parameters.
    #
    # Rails 8.1 filters the "Started GET" line's URL one query pair at a time,
    # as a one-key hash with no controller to scope by
    # (ActionDispatch::Http::FilterParameters#filtered_query_string), so a
    # controller-scoped filter leaves a callback's account id in that line. A
    # provider's filter_keys are therefore matched by EXACT key wherever they
    # appear, String values only (a nested Hash under the same name is spared).
    #
    # The auth code is masked in the Parameters line of the connection
    # controllers only: a bare `code` filter would mask every other `code` param
    # in the app. It still rides the Started GET URL, where it is already spent.
    LOG_FILTER = lambda do |key, value, params = nil|
      next unless value.is_a?(String)

      name = key.to_s
      if Studio::Connections.filter_keys.include?(name)
        value.replace("[FILTERED]")
      elsif name == "code" && params.is_a?(Hash) && Studio::Connections.controllers.include?(params["controller"].to_s)
        value.replace("[FILTERED]")
      end
    end

    # One provider, as a host declared it. Every option is checked here, at
    # boot, so a typo fails the host's boot instead of a sign-in.
    class Provider
      Token = Struct.new(:value, :expires_at)

      attr_reader :key, :label, :env, :grant, :refresh, :refresh_margin, :scopes, :client_auth, :revoke_auth,
                  :revoke_format, :account_source, :account_param, :account_format, :private_account,
                  :authorize_params, :exchange_params, :rotation, :refresh_expires_in_key, :declined_errors,
                  :refusal_hint, :revoked_errors, :revoked_pattern, :rate_limited_statuses, :filter_keys,
                  :revoke_note, :callback_check, :describe, :trace_header

      # Stand-in for the provider's token and revoke endpoints:
      # (url, form, headers) -> [status, body]. nil means the provider itself.
      # Tests, the e2e lane and a local demo only; refused outside development and test.
      attr_reader :http

      # Stand-in for the provider's sign-in page (authorize_url only), for the
      # e2e lane and a local demo: anything answering
      # authorize_url(redirect_uri:, state:, account:). Refused outside development and test.
      # The code exchange and the refresh still run through .http.
      attr_reader :sign_in_stand_in

      def initialize(key, label:, env:, authorize_url:, token_url:, revoke_url: nil, grant: :authorization_code,
                     refresh: nil, refresh_margin: 5.minutes, scopes: [], client_auth: :form, revoke_auth: nil,
                     revoke_format: :form, account: :callback, account_param: nil, account_format: nil,
                     normalize_account: nil, private_account: false, authorize_params: {}, exchange_params: {},
                     rotation: nil, refresh_expires_in_key: nil, declined_errors: %w[access_denied],
                     refusal_hint: "Check the app's redirect URI, then start again.", revoked_errors: %w[invalid_grant],
                     revoked_pattern: nil, rate_limited_statuses: [429], filter_keys: [], revoke_note: nil,
                     callback_check: nil, describe: nil, trace_header: nil)
        @key = key.to_s
        raise ArgumentError, "a connection key is lower-case letters, digits and underscores: #{@key.inspect}" unless @key.match?(/\A[a-z][a-z0-9_]*\z/)

        @label = label.to_s
        @env = env.to_h.transform_keys(&:to_sym)
        raise ArgumentError, "#{@key}: env names client_id and client_secret" unless @env.keys.sort == %i[client_id client_secret] && @env.values.all?(String)

        @grant = choose(grant, GRANTS, "grant")
        @refresh = choose(refresh || (@grant == :client_credentials ? :memory : :rotating), REFRESH_POLICIES, "refresh")
        if (@grant == :client_credentials) != (@refresh == :memory)
          raise ArgumentError, "#{@key}: the client-credentials grant, and only it, keeps its token in memory (refresh: :memory)"
        end

        @authorize_url = authorize_url
        @token_url = token_url
        @revoke_url = revoke_url
        @refresh_margin = refresh_margin
        @scopes = Array(scopes).map(&:to_s)
        @client_auth = choose(client_auth, CLIENT_AUTH - [:secret_only], "client_auth")
        @revoke_auth = choose(revoke_auth || @client_auth, CLIENT_AUTH, "revoke_auth")
        @revoke_format = choose(revoke_format, %i[form json], "revoke_format")
        @account_source = choose(account, ACCOUNT_SOURCES, "account")
        @account_param = account_param&.to_s
        @account_format = account_format
        if %i[connect callback].include?(@account_source) && !(@account_param && @account_format.is_a?(Regexp))
          raise ArgumentError, "#{@key}: an account from the #{@account_source} needs account_param and an account_format Regexp"
        end
        @normalize_account = normalize_account || ->(value) { value.to_s.strip }
        @private_account = private_account ? true : false
        @authorize_params = authorize_params.to_h
        @exchange_params = exchange_params.to_h
        @rotation = choose(rotation || (@refresh == :rotating ? :required : :optional), %i[required optional], "rotation")
        @refresh_expires_in_key = refresh_expires_in_key&.to_s
        @declined_errors = Array(declined_errors).map(&:to_s)
        @refusal_hint = refusal_hint.to_s
        @revoked_errors = Array(revoked_errors).map(&:to_s)
        @revoked_pattern = revoked_pattern
        @rate_limited_statuses = Array(rate_limited_statuses).map(&:to_i)
        @filter_keys = Array(filter_keys).map(&:to_s)
        # A private account's callback param is filtered whether or not the host listed it.
        @filter_keys |= [@account_param] if @private_account && @account_source == :callback
        @revoke_note = revoke_note || "Remove this app's access in #{@label} to revoke it there."
        @callback_check = callback_check
        @describe = describe
        # A response header naming the call for the provider's support (Intuit:
        # intuit_tid). Read from every token, refresh and revoke answer, logged
        # with the call, kept as #last_trace_id and put on every error raised.
        @trace_header = trace_header&.to_s
        @cache = {}
        @cache_lock = Mutex.new
      end

      def http=(callable)
        refuse_seam_outside_dev_and_test!("http") unless callable.nil?
        @http = callable
      end

      def sign_in_stand_in=(stand_in)
        refuse_seam_outside_dev_and_test!("sign_in_stand_in") unless stand_in.nil?
        @sign_in_stand_in = stand_in
      end

      def client_id = ENV[env[:client_id]].to_s
      def client_secret = ENV[env[:client_secret]].to_s
      def env_names = env.values

      # The client id and secret are set on this server.
      def configured? = env_names.all? { |name| ENV[name].to_s.strip != "" }

      # Can a Connect start on this server: the client is set, or the stand-in is.
      def connectable? = configured? || !sign_in_stand_in.nil?

      def revocable? = !@revoke_url.nil?

      # The account as a row keys it, or nil when it is not one: normalized,
      # then held to account_format (always, when one is given). A strict
      # format is what keeps an account named in a form out of a URL's host.
      def normalize_account(value)
        normalized = @normalize_account.call(value)
        return nil if normalized.nil? || normalized.to_s.empty?

        normalized = normalized.to_s
        return nil if account_format && !account_format.match?(normalized)

        normalized
      end

      # What a row is unique by: the account itself, or a keyed digest of it
      # when the account is private (it is then stored only encrypted).
      def account_key_for(account)
        return account unless private_account

        secret = defined?(::Rails) && ::Rails.application ? ::Rails.application.secret_key_base : raise(Error, "no secret_key_base to key a private account by")
        OpenSSL::HMAC.hexdigest("SHA256", secret, "studio-connection:#{key}:#{account}")
      end

      # An endpoint's URL: the static String, or the callable's answer for a
      # checked account (a per-account host). Raises InvalidAccount for an
      # account that fails account_format, so it never reaches a URL.
      def url_for(option, account)
        value = { authorize: @authorize_url, token: @token_url, revoke: @revoke_url }.fetch(option)
        return nil if value.nil?
        return value.to_s unless value.respond_to?(:call)

        checked = normalize_account(account) or raise InvalidAccount, "not a #{label} account"
        value.call(checked).to_s
      end

      # Where the browser goes to sign in (a code grant) or approve the app (a
      # client-credentials grant's admin consent).
      def authorize_url(redirect_uri:, state:, account: nil)
        return sign_in_stand_in.authorize_url(redirect_uri:, state:, account:) if sign_in_stand_in

        ensure_configured!
        params = { client_id:, redirect_uri:, state: }
        if grant == :authorization_code
          params[:response_type] = "code"
          params[:scope] = scopes.join(" ") if scopes.any?
        end
        url = url_for(:authorize, account)
        "#{url}#{url.include?('?') ? '&' : '?'}#{URI.encode_www_form(params.merge(authorize_params))}"
      end

      # The token endpoint's JSON for a sign-in's code.
      def exchange_code(code:, redirect_uri:, account: nil)
        token_request(account, { grant_type: "authorization_code", code:, redirect_uri: }.merge(exchange_params))
      end

      # An access token for `connection` (a Studio::Connection; for :memory,
      # also a bare account id), by this provider's refresh policy. Raises
      # Revoked when the provider no longer honours the grant.
      def access_token(connection, stale: nil, now: Time.current)
        case refresh
        when :rotating then rotating_access_token(connection, now:)
        when :cached then cached_access_token(connection, stale:, now:)
        when :memory then memory_access_token(connection.respond_to?(:account_id) ? connection.account_id : connection, now:)
        end
      end

      # Revokes the connection's grant at the provider. True when it took it;
      # nil when this provider has no revoke endpoint; raises Error otherwise.
      def revoke(connection)
        return nil unless revocable?

        token = connection.refresh_token.presence || connection.access_token
        raise Error, "this connection holds no token to revoke" if token.to_s.empty?

        form = { token: }
        post(url_for(:revoke, connection.account_id), form, auth: revoke_auth, format: revoke_format, allow_empty: true)
        true
      end

      # Drops the in-memory token of one account, or every account's (:memory).
      def forget!(account = nil)
        @cache_lock.synchronize { account ? @cache.delete(account.to_s.downcase) : @cache.clear }
      end

      # The trace_header value of this thread's latest call to the provider, or nil.
      def last_trace_id = (Thread.current[:studio_connection_traces] ||= {})[key]

      # Reads trace_header from a response's headers (a Hash or a Net::HTTPResponse),
      # remembers it as last_trace_id, and logs it with the call (no token, no body).
      # Host readers call it on their own responses too.
      def record_trace(headers, call:, status:)
        return nil unless trace_header

        value = case headers
                when Hash then headers.find { |name, _| name.to_s.casecmp?(trace_header) }&.last
                else headers.respond_to?(:[]) ? headers[trace_header] : nil
                end
        value = Array(value).first.to_s.strip.presence
        (Thread.current[:studio_connection_traces] ||= {})[key] = value
        if defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger
          ::Rails.logger.info("[studio_connection] provider=#{key} call=#{call} status=#{status} #{trace_header}=#{value || '-'}")
        end
        value
      end

      # How many accounts have a token cached in this process (:memory).
      def cached_count = @cache_lock.synchronize { @cache.size }

      # When a grant's token stops working, from a seconds field; nil when the
      # provider gave no positive lifetime.
      def self.expiry(grant, field, now)
        return nil if field.nil?

        seconds = Integer(grant[field].to_s, exception: false)
        seconds&.positive? ? now + seconds : nil
      end

      private

      def choose(value, allowed, name)
        value = value.to_sym
        return value if allowed.include?(value)

        raise ArgumentError, "#{@key}: #{name} is one of #{allowed.map(&:inspect).join(', ')}, not #{value.inspect}"
      end

      def refuse_seam_outside_dev_and_test!(name)
        raise Error, "#{label}: the #{name} stand-in is for tests, the e2e lane and a local demo (development and test only)" unless Connections.seams_allowed?
      end

      def ensure_configured!
        raise NotConfigured, "#{env_names.join(' and ')} are not set on this server" unless configured? || http
      end

      def rotating_access_token(connection, now:)
        answer = connection.with_lock do
          raise Revoked, "#{label}: this connection holds no refresh token; connect again" if connection.refresh_token.blank?

          grant = token_request(connection.account_id, { grant_type: "refresh_token", refresh_token: connection.refresh_token })
          connection.rotate!(grant, now:)
          grant
        end
        # After the lock commits: a raise inside it would roll back the token the provider already rotated.
        answer["access_token"].presence or raise Error, "#{label} answered a refresh with no access token"
      end

      def cached_access_token(connection, stale:, now:)
        connection.with_lock do
          current = connection.access_token
          next current if stale.present? && current != stale
          next current if stale.blank? && connection.access_fresh?(now)
          raise Revoked, "#{label}: this connection holds no refresh token; connect again" if connection.refresh_token.blank?

          grant = token_request(connection.account_id, { grant_type: "refresh_token", refresh_token: connection.refresh_token })
          raise Error, "#{label} answered a refresh with no access token" if grant["access_token"].blank?

          connection.rotate!(grant, now:)
          grant["access_token"]
        end
      end

      def memory_access_token(account, now:)
        account = normalize_account(account) or raise InvalidAccount, "not a #{label} account"
        cache_key = account.downcase
        cached = @cache_lock.synchronize { @cache[cache_key] }
        return cached.value if cached && cached.expires_at > now

        form = { grant_type: "client_credentials" }
        form[:scope] = scopes.join(" ") if scopes.any?
        answer = token_request(account, form)
        value = answer["access_token"].presence or raise Error, "#{label} answered a token request with no access token"
        lifetime = answer["expires_in"].to_i
        @cache_lock.synchronize { @cache[cache_key] = Token.new(value, now + lifetime - refresh_margin) }
        value
      end

      def token_request(account, form)
        post(url_for(:token, account), form, auth: client_auth, format: :form)
      end

      def post(url, form, auth:, format:, allow_empty: false)
        ensure_configured!
        headers = { "Accept" => "application/json",
                    "Content-Type" => format == :json ? "application/json" : "application/x-www-form-urlencoded" }
        case auth
        when :form then form = form.merge(client_id:, client_secret:)
        when :secret_only then form = form.merge(client_secret:)
        when :basic then headers["Authorization"] = "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}"
        end
        status, body, answered = call(url, form, headers)
        trace = record_trace(answered, call: form.key?(:token) ? "revoke" : form[:grant_type].to_s, status:)
        json = parse(body)
        # A revoke (allow_empty) is confirmed by any 2xx, a 204 included; a token answer must be a 200 with a body.
        return json if allow_empty ? (200..299).cover?(status) : (status == 200 && json.any?)

        raise_for(status, json, trace)
      end

      def raise_for(status, json, trace = nil)
        detail = json["error_description"].to_s.lines.first.to_s.strip
        detail = (json["error"] || json["message"] || json["errorMessage"]).to_s if detail.empty?
        detail = "no detail" if detail.empty?
        traced = { trace_header:, trace_id: trace }
        raise RateLimited.new("#{label} is throttling this app (#{status}); try again in a few minutes", **traced) if rate_limited_statuses.include?(status)
        raise Revoked.new("#{label} no longer accepts this connection (#{detail}); connect again", **traced) if revoked?(status, json, detail)

        raise Error.new("#{label} answered #{status}: #{detail}", **traced)
      end

      def revoked?(status, json, detail)
        return false unless [400, 401, 403].include?(status)

        revoked_errors.include?(json["error"].to_s) || (revoked_pattern ? revoked_pattern.match?(detail) : false)
      end

      def parse(body)
        json = JSON.parse(body.to_s)
        json.is_a?(Hash) ? json : {}
      rescue JSON::ParserError
        {}
      end

      # [status, body, response headers]. A stand-in may answer [status, body]
      # or [status, body, { "header" => "value" }].
      def call(url, form, headers)
        return http.call(url, form, headers) if http

        uri = URI(url)
        raise Error, "#{label}: a token endpoint must be https" unless uri.scheme == "https"

        request = Net::HTTP::Post.new(uri)
        headers.each { |name, value| request[name] = value }
        request.body = headers["Content-Type"] == "application/json" ? JSON.generate(form) : URI.encode_www_form(form)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
        [response.code.to_i, response.body, response]
      rescue *NETWORK_ERRORS => e
        raise Error, "#{label} could not be reached: #{e.class}"
      end
    end
  end
end
