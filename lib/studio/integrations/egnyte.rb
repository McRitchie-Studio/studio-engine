# frozen_string_literal: true

module Studio
  module Integrations
    # EGNYTE, the connection only. A host's readers (folders, files) are its
    # own; they call Studio.integration(:egnyte).api_base(connection).
    #
    #   * Every Egnyte domain answers on its own host, <domain>.egnyte.com, so
    #     the admin types the domain at Connect (a POST, CSRF-checked). It is
    #     normalized ("Acme", "acme.egnyte.com" and "https://acme.egnyte.com/"
    #     are all "acme") and held to a DNS label before it reaches a URL.
    #   * One scope, Egnyte.filesystem, on the authorize URL and the exchange.
    #     The sign-in page and the token endpoint share one path.
    #   * CACHED tokens: the access token lives 30 days and Egnyte asks callers
    #     to cache it (its token endpoint allows about 100 requests an hour), so
    #     the row keeps it and refreshes only within a day of its expiry or after
    #     a 401. A refresh answers a new pair, stored before use.
    #   * The revoke takes the token and the client secret, not the id.
    #   * The token endpoint throttles with a 409 (and the API with a 429); an
    #     "invalid refresh token" detail means the grant is gone.
    #
    # Checked against the hub's Egnyte::OAuthClient, EgnyteConnection and
    # Egnyte::Reader (mcritchie-studio), which cite Egnyte's authentication docs.
    module Egnyte
      HOST_SUFFIX = ".egnyte.com"
      TOKEN_PATH = "/puboauth/token"
      REVOKE_PATH = "/pubapi/v1/tokens/revoke"
      API_PATH = "/pubapi/v1"
      SCOPE = "Egnyte.filesystem"
      # A DNS label: what may stand before .egnyte.com. Nothing else reaches a URL.
      DOMAIN = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

      def self.host(domain) = "https://#{domain}#{HOST_SUFFIX}"

      # The bare domain from what an admin typed, lower-cased (still unchecked).
      def self.normalize(value)
        value.to_s.strip.downcase.sub(%r{\Ahttps?://}, "").sub(%r{[/?#].*\z}, "").delete_suffix(HOST_SUFFIX)
      end

      Integrations.register :egnyte,
        label: "Egnyte",
        summary: "An Egnyte domain's files, read with a user's own sign-in.",
        connection: {
          authorize_url: ->(domain) { "#{Egnyte.host(domain)}#{TOKEN_PATH}" },
          token_url: ->(domain) { "#{Egnyte.host(domain)}#{TOKEN_PATH}" },
          revoke_url: ->(domain) { "#{Egnyte.host(domain)}#{REVOKE_PATH}" },
          scopes: [SCOPE], exchange_params: { scope: SCOPE },
          client_auth: :form, revoke_auth: :secret_only,
          refresh: :cached, refresh_margin: 1.day,
          account: :connect, account_param: "egnyte_domain", account_format: DOMAIN,
          normalize_account: ->(value) { Egnyte.normalize(value) },
          rate_limited_statuses: [409, 429], revoked_pattern: /invalid refresh token|invalid_grant/i,
          refusal_hint: "Check the developer key's redirect URI, then start again."
        },
        account_label: "Egnyte domain",
        account_hint: "yourcompany (from yourcompany.egnyte.com)",
        describe: lambda { |_integration, grant:, account:, get:|
          token = grant["access_token"].to_s
          next {} if token.empty?

          username = get.call("#{Egnyte.host(account)}#{API_PATH}/whoami", token)["username"].to_s.strip
          { metadata: username.empty? ? {} : { "username" => username } }
        },
        default_label: ->(domain) { "#{domain}#{HOST_SUFFIX}" },
        api_base: ->(_integration, connection) { "#{Egnyte.host(connection.account_id)}#{API_PATH}" },
        stand_in: { answer: { "username" => "stand-in" } }
    end
  end
end
