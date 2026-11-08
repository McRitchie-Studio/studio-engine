# frozen_string_literal: true

require "securerandom"

module Studio
  module Connections
    # A STAND-IN PROVIDER for the e2e lane and a local demo: a host walks a
    # connection with no client registered at the provider. NEVER production
    # (the Provider seams refuse it there).
    #
    #   Studio::Connections::StandIn.install!(Studio.connection(:files))
    #   Studio::Connections::StandIn.install!(Studio.connection(:tenant),
    #     callback_params: { tenant: "00000000-0000-0000-0000-000000000000", admin_consent: "True" })
    #
    # The sign-in page comes straight back to the callback with the stand-in's
    # code (and any callback_params). The token and revoke endpoints are stood
    # in at the HTTP layer (Provider#http), so the real exchange, refresh and
    # rotation run: like a rotating provider, every grant answers a new refresh
    # token and only the LAST one issued for a token URL is honoured, so a
    # refresh that failed to store its new pair shows up as Revoked on the next
    # read. Access tokens live `access_lifetime` seconds. The memory is this
    # process's own.
    module StandIn
      CODE = "studio-connection-stand-in-code"

      class SignIn
        def initialize(callback_params: {})
          @callback_params = callback_params.to_h
        end

        def authorize_url(redirect_uri:, state:, account: nil)
          query = { code: CODE }.merge(@callback_params).merge(state:)
          "#{redirect_uri}?#{URI.encode_www_form(query)}"
        end
      end

      # The token and revoke endpoints: (url, form, headers) -> [status, body].
      class Tokens
        attr_reader :requests

        def initialize(access_lifetime: 3600)
          @access_lifetime = access_lifetime
          @live = {}
          @requests = []
          @lock = Mutex.new
        end

        def call(url, form, headers)
          @lock.synchronize do
            @requests << { url:, form:, headers: }
            next [200, ""] if form.key?(:token)

            case form[:grant_type]
            when "authorization_code"
              form[:code] == CODE ? issue(url) : refuse
            when "refresh_token"
              @live[url] && form[:refresh_token] == @live[url] ? issue(url) : refuse
            when "client_credentials"
              [200, { token_type: "Bearer", expires_in: @access_lifetime, access_token: "stand-in-access-#{SecureRandom.hex(8)}" }.to_json]
            else [400, { error: "unsupported_grant_type" }.to_json]
            end
          end
        end

        private

        def refuse = [400, { error: "invalid_grant", error_description: "the stand-in did not issue that" }.to_json]

        def issue(url)
          @live[url] = "stand-in-refresh-#{SecureRandom.hex(8)}"
          [200, { access_token: "stand-in-access-#{SecureRandom.hex(8)}", refresh_token: @live[url],
                  expires_in: @access_lifetime, token_type: "bearer" }.to_json]
        end
      end

      def self.install!(provider, callback_params: {}, access_lifetime: 3600)
        provider.sign_in_stand_in = SignIn.new(callback_params:)
        provider.http = Tokens.new(access_lifetime:)
        provider
      end

      def self.uninstall!(provider)
        provider.sign_in_stand_in = nil
        provider.http = nil
        provider
      end
    end
  end
end
