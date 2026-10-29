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

      def strategy(client_id, client_secret)
        @lock.synchronize do
          @strategies[[client_id, client_secret]] ||=
            ::OmniAuth::Strategies::GoogleOauth2.new(@app, client_id, client_secret, scope: SCOPE, prompt: PROMPT)
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

      # "Request Google setup" is answered once per host per day. Returns true
      # for the request that claims the day, false for every later one.
      #
      # Checked with exist? before the unless_exist write, because not every
      # cache store honours unless_exist; the two together leave only a race
      # between simultaneous first clicks, which costs one extra email.
      def claim_daily_request(host, store: request_store, today: current_date)
        key = "studio/google_setup_request/#{host.to_s.downcase}/#{today.iso8601}"
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

      def rails_middleware_stack
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        stack = ::Rails.application.config.middleware
        stack.respond_to?(:middlewares) ? stack : nil
      end
    end
  end
end
