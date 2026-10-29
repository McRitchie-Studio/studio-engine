# frozen_string_literal: true

module Studio
  # Google sign-in that ships ready with every app (docs/GOOGLE_AUTH_SETUP.md).
  #
  # Alex McRitchie, 2026-10-29: "I want this to be automatic with new apps. Even
  # if there is still manual work to be done, please have the link for google
  # login. If there is manual work to be done to properly setup Google, the link
  # should show a modal requesting access to Google auth."
  #
  # So an app that bundles studio-engine gets, with nothing of its own:
  #
  #   * the google_oauth2 OmniAuth strategy, registered by the engine's
  #     Middleware below, UNLESS the host's own initializer registered one;
  #   * a default User.from_omniauth (Studio::OmniauthUser), which a host's own
  #     definition overrides;
  #   * the "Sign in with Google" button on /login, /signup and /profile. While
  #     the OAuth client is not configured (ready? false) the button opens a
  #     modal that asks the team to finish setup, instead of posting to a
  #     strategy that would send the person to a Google error page.
  #
  # THE ONE MANUAL STEP that cannot ship in a gem: register the app's callback
  # (redirect_uri below) on the shared production OAuth client and set
  # GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET. The modal's "Request Google setup"
  # mails the team exactly that.
  #
  # Pure Ruby apart from the methods that read Rails.application or OmniAuth,
  # each of which guards on the constant, so the unit suite loads this file as is.
  module GoogleSignIn
    PROVIDER      = "google_oauth2"
    REQUEST_PATH  = "/auth/google_oauth2"
    CALLBACK_PATH = "/auth/google_oauth2/callback"
    SCOPE         = "email,profile"
    PROMPT        = "select_account"
    CREDENTIAL_KEYS = %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].freeze

    # How long a "Request Google setup" claim holds. The key is per day, so this
    # only has to outlive the day it names.
    REQUEST_TTL_SECONDS = 26 * 60 * 60

    # Records what an OmniAuth::Builder block registers without registering
    # anything: `provider` notes its first argument, and every other call a
    # host's block makes (configure, on_failure, options) is swallowed.
    class ProviderRecorder
      attr_reader :providers

      def initialize
        @providers = []
      end

      def provider(klass, *_args, **_options, &_block)
        @providers << klass
        nil
      end

      def method_missing(*_args, **_options, &_block)
        nil
      end

      def respond_to_missing?(*_args)
        true
      end
    end

    # The engine's half of the registration: a Rack middleware the engine adds
    # to every host's stack (Studio::Engine, "studio.google_sign_in"). It is the
    # google_oauth2 strategy when the engine owns Google, and a pass-through
    # otherwise:
    #
    #   * the host registered its own provider  -> pass through; the host's wins
    #   * no credentials and not OmniAuth test mode -> pass through, so POST
    #     /auth/google_oauth2 answers 404 rather than a Google error page
    #   * otherwise -> the strategy, built from the credentials of the moment
    #
    # Deciding per request rather than at boot is what makes host detection
    # possible: the engine's initializers run BEFORE the host's
    # config/initializers, so at boot the host's OmniAuth::Builder is not yet on
    # the stack to be seen.
    class Middleware
      def initialize(app)
        @app = app
        @strategies = {}
        @lock = Mutex.new
      end

      def call(env)
        return @app.call(env) unless GoogleSignIn.engine_registers?

        strategy(*GoogleSignIn.credentials).call(env)
      end

      private

      # The strategy's callback host is pinned when the app names one (see
      # GoogleSignIn.pinned_full_host), and otherwise OmniAuth's allowed_hosts
      # is seeded from config.hosts (GoogleSignIn.seed_allowed_hosts!), so a
      # forged Host or X-Forwarded-Host never becomes the redirect_uri Google
      # sees. Either one also settles OmniAuth 2.3's request-host warning.
      def strategy(client_id, client_secret)
        @lock.synchronize do
          @strategies[[client_id, client_secret]] ||= begin
            options = { scope: SCOPE, prompt: PROMPT }
            if (full_host = GoogleSignIn.pinned_full_host)
              options[:full_host] = full_host
            else
              GoogleSignIn.seed_allowed_hosts!
            end
            ::OmniAuth::Strategies::GoogleOauth2.new(@app, client_id, client_secret, **options)
          end
        end
      end
    end

    class << self
      # True when the app holds an OAuth client: both env vars present.
      def ready?(env: ENV)
        CREDENTIAL_KEYS.all? { |key| !env[key].to_s.strip.empty? }
      end

      def credentials(env: ENV)
        CREDENTIAL_KEYS.map { |key| env[key].to_s.strip.then { |value| value.empty? ? nil : value } }
      end

      # OmniAuth's test mode answers every request with the mock, so the button
      # posts there whatever the credentials say.
      def mock_mode?
        defined?(::OmniAuth) && ::OmniAuth.config.test_mode ? true : false
      end

      # Whether the Google button POSTs to the strategy (true) or opens the
      # setup modal (false). A host that registered its own provider owns its
      # readiness, so its button keeps posting exactly as it did before the
      # engine shipped one: hub, turf-monster, moms-app, cyvasse and
      # acquisition-studio test their buttons as POST forms with no credentials.
      def button_posts?(env: ENV)
        ready?(env: env) || mock_mode? || host_registered?
      end

      # Whether the engine's own strategy answers /auth/google_oauth2.
      def engine_registers?(env: ENV)
        return false if host_registered?

        ready?(env: env) || mock_mode?
      end

      # :host, :engine or :none: who answers /auth/google_oauth2 right now.
      def registration(env: ENV)
        return :host if host_registered?

        engine_registers?(env: env) ? :engine : :none
      end

      # The callback a Google OAuth client must list for this host.
      def redirect_uri(host:, scheme: "https")
        "#{scheme}://#{host}#{CALLBACK_PATH}"
      end

      # ---- The app's canonical host: from configuration, NEVER the request ----
      #
      # "Request Google setup" mails ops a redirect URI to add to the shared
      # production OAuth client, so that URI must not come from a header a
      # stranger controls (Host, X-Forwarded-Host). In order:
      #
      #   1. Studio.google_canonical_host, set in config/initializers/studio.rb
      #   2. ENV["APP_HOST"], the deployed apps' canonical host (the hub's
      #      CanonicalHost reads the same variable)
      #   3. the first config.hosts entry that is a plain hostname: a String of
      #      letters, digits, dots and hyphens, no port, no leading dot
      #
      # nil when none is configured; the email then says so instead of naming
      # a host.
      PLAIN_HOSTNAME = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\z/i

      def canonical_host(env: ENV, configured: configured_canonical_host, hosts: rails_config_hosts)
        explicit = normalize_host(configured) || normalize_host(env["APP_HOST"])
        return explicit if explicit

        Array(hosts).find { |entry| entry.is_a?(String) && PLAIN_HOSTNAME.match?(entry) }&.downcase
      end

      # Scheme and host only, lowercased: "https://App.Example/x" -> "app.example".
      # A port an operator wrote into APP_HOST is kept; it is configuration.
      def normalize_host(value)
        text = value.to_s.strip.sub(%r{\A[a-z][a-z0-9+.-]*://}i, "").split("/").first.to_s.downcase
        text.empty? ? nil : text
      end

      def canonical_scheme(production: rails_production?)
        production ? "https" : "http"
      end

      # The redirect URI to register, from the canonical host; nil when the app
      # names none.
      def canonical_redirect_uri(env: ENV, production: rails_production?)
        host = canonical_host(env: env)
        host && redirect_uri(host: host, scheme: canonical_scheme(production: production))
      end

      # The strategy's full_host: pinned only in production and only from an
      # EXPLICIT host (Studio.google_canonical_host or APP_HOST). A desk on
      # localhost:<port> must keep its own port in the callback, and a QA app's
      # config.hosts may list the production host first.
      def pinned_full_host(env: ENV, production: rails_production?)
        return nil unless production

        host = normalize_host(configured_canonical_host) || normalize_host(env["APP_HOST"])
        host && "https://#{host}"
      end

      # OmniAuth.config.allowed_hosts mirrored from config.hosts, so OmniAuth
      # builds callbacks only on hosts the app already accepts. Left alone when
      # the app set OmniAuth's own host config, when config.hosts is empty, or
      # when it admits every host anyway (an IPAddr range, as development has).
      # A leading-dot entry (".example.com") becomes the same subdomain pattern
      # Rails gives it; ports are dropped, since OmniAuth compares bare hosts.
      def allowed_hosts_from(hosts)
        entries = Array(hosts)
        return nil if entries.empty?
        return nil if entries.any? { |entry| !entry.is_a?(String) && !entry.is_a?(Regexp) }

        entries.map do |entry|
          next entry if entry.is_a?(Regexp)

          bare = entry.downcase.sub(/:\d+\z/, "")
          bare.start_with?(".") ? /(?:[a-z0-9-]+\.)*#{Regexp.escape(bare.delete_prefix("."))}/i : bare
        end.uniq
      end

      def seed_allowed_hosts!(hosts: rails_config_hosts)
        return unless defined?(::OmniAuth)
        return if ::OmniAuth.config.full_host || ::OmniAuth.config.allowed_hosts

        allowed = allowed_hosts_from(hosts)
        ::OmniAuth.config.allowed_hosts = allowed if allowed
      end

      # The once-a-day key: the app, not the request's host, so a forged Host or
      # port cannot mint a fresh day.
      def app_key
        name = defined?(Studio) && Studio.respond_to?(:app_name) ? Studio.app_name.to_s : ""
        key = name.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
        key.empty? ? "app" : key
      end

      # Does a built middleware stack already register google_oauth2? Reads each
      # entry's class and block (ActionDispatch::MiddlewareStack::Middleware):
      #
      #   * the strategy used directly (`use OmniAuth::Strategies::GoogleOauth2`)
      #   * an OmniAuth::Builder whose block calls `provider :google_oauth2`,
      #     found by evaluating the block against a ProviderRecorder
      #
      # A Builder registering only other providers does not count, so the engine
      # still supplies Google beside them. A block the recorder cannot evaluate
      # counts as registering Google: two strategies on one path is the failure
      # this exists to prevent, so doubt resolves toward the host.
      def host_registers_google?(middlewares)
        Array(middlewares).any? do |entry|
          klass = entry.respond_to?(:klass) ? entry.klass : entry
          name = klass.to_s
          next false if name == Middleware.name
          next true if google_provider?(klass)
          next false unless omniauth_builder?(klass)

          builder_registers_google?(entry.respond_to?(:block) ? entry.block : nil)
        end
      end

      def builder_registers_google?(block)
        return false unless block

        recorder = ProviderRecorder.new
        recorder.instance_eval(&block)
        recorder.providers.any? { |provider| google_provider?(provider) }
      rescue StandardError, ScriptError
        true
      end

      def google_provider?(provider)
        name = provider.to_s
        name == PROVIDER || name.end_with?("::GoogleOauth2")
      end

      def omniauth_builder?(klass)
        return true if klass.to_s == "OmniAuth::Builder"

        defined?(::OmniAuth::Builder) && klass.is_a?(Class) && klass < ::OmniAuth::Builder ? true : false
      end

      # Memoized once the app's stack is built; nil-safe before that (and in a
      # process with no Rails app), answering false without memoizing.
      def host_registered?
        return @host_registered unless @host_registered.nil?

        stack = rails_middleware_stack
        return false unless stack

        @host_registered = host_registers_google?(stack.middlewares)
      end

      def reset!
        @host_registered = nil
        @fallback_store = nil
      end

      # "Request Google setup" is answered once per APP per day (key: app_key,
      # never a request header). Returns true for the request that claims the
      # day, false for every later one.
      #
      # Checked with exist? before the unless_exist write, because not every
      # cache store honours unless_exist; the two together leave only a race
      # between simultaneous first clicks, which costs one extra email.
      def claim_daily_request(app = app_key, store: request_store, today: current_date)
        key = "studio/google_setup_request/#{app.to_s.downcase}/#{today.iso8601}"
        return false if store.exist?(key)

        store.write(key, today.iso8601, unless_exist: true, expires_in: REQUEST_TTL_SECONDS) ? true : false
      end

      # The app's Rails.cache, unless that is a NullStore, which remembers
      # nothing and would let every click mail the team. Then a store of this
      # process's own: a per-dyno limit, still a limit.
      def request_store
        cache = defined?(::Rails) && ::Rails.respond_to?(:cache) ? ::Rails.cache : nil
        return cache if cache && !(defined?(::ActiveSupport::Cache::NullStore) && cache.is_a?(::ActiveSupport::Cache::NullStore))

        @fallback_store ||= begin
          require "active_support/cache"
          ::ActiveSupport::Cache::MemoryStore.new
        end
      end

      # The app's day (Time.zone) where ActiveSupport has one, else the system's.
      def current_date
        Date.respond_to?(:current) ? Date.current : Date.today
      end

      private

      def configured_canonical_host
        defined?(Studio) && Studio.respond_to?(:google_canonical_host) ? Studio.google_canonical_host : nil
      end

      def rails_config_hosts
        return [] unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        Array(::Rails.application.config.hosts)
      end

      def rails_production?
        defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.production? ? true : false
      end

      def rails_middleware_stack
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        stack = ::Rails.application.config.middleware
        stack.respond_to?(:middlewares) ? stack : nil
      end
    end
  end
end
