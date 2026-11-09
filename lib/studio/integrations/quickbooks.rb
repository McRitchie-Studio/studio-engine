# frozen_string_literal: true

module Studio
  module Integrations
    # QUICKBOOKS ONLINE (Intuit), the connection only. A host's readers (company
    # info, reports) are its own; they call Studio.integration(:quickbooks).api_base(connection).
    #
    #   * Sign-in at Intuit's app center; the endpoints are Intuit's discovery
    #     document's, the same for sandbox and production.
    #   * The token and revoke calls authenticate with HTTP Basic; the revoke
    #     body is JSON.
    #   * ROTATING refresh tokens: access tokens last an hour, a refresh may
    #     answer a new refresh token and the latest must be kept, so every
    #     access_token call refreshes under the row's lock and stores the
    #     answered token first. The grant states the refresh token's own
    #     lifetime in x_refresh_token_expires_in.
    #   * The company is named on the callback (?realmId=), a number, kept out
    #     of the logs by exact key.
    #   * The environment setting (sandbox, the default, or production) says
    #     which Intuit keys these are, so which API host a new connection reads;
    #     anything but "production" is the sandbox, so a typo never points
    #     sandbox keys at live books. It is stored on the connection.
    #
    # Checked against the hub's Quickbooks::OAuthClient and Quickbooks::Reader
    # (mcritchie-studio), which cite Intuit's documents.
    module Quickbooks
      AUTHORIZE_URL = "https://appcenter.intuit.com/connect/oauth2"
      TOKEN_URL = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"
      REVOKE_URL = "https://developer.api.intuit.com/v2/oauth2/tokens/revoke"
      SCOPE = "com.intuit.quickbooks.accounting"
      API_URLS = { "sandbox" => "https://sandbox-quickbooks.api.intuit.com",
                   "production" => "https://quickbooks.api.intuit.com" }.freeze
      # Intuit retired minor versions 1-74 in August 2025: 75 is the floor.
      MINOR_VERSION = 75
      REALM_ID = /\A\d{1,20}\z/

      def self.api_url(environment) = API_URLS.fetch(environment.to_s, API_URLS.fetch("sandbox"))

      Integrations.register :quickbooks,
        label: "QuickBooks",
        summary: "A QuickBooks Online company, read with its owner's sign-in.",
        connection: {
          authorize_url: AUTHORIZE_URL, token_url: TOKEN_URL, revoke_url: REVOKE_URL,
          scopes: [SCOPE],
          client_auth: :basic, revoke_format: :json,
          refresh: :rotating, refresh_expires_in_key: "x_refresh_token_expires_in",
          account: :callback, account_param: "realmId", account_format: REALM_ID,
          filter_keys: %w[realmId],
          refusal_hint: "Check the Intuit app's redirect URI, then start again."
        },
        settings: { environment: { values: %w[sandbox production], default: "sandbox" } },
        metadata: ->(integration) { { "environment" => integration.setting(:environment) } },
        describe: lambda { |integration, grant:, account:, get:|
          token = grant["access_token"].to_s
          next {} if token.empty?

          base = "#{Quickbooks.api_url(integration.setting(:environment))}/v3/company/#{account}"
          info = get.call("#{base}/companyinfo/#{account}?minorversion=#{MINOR_VERSION}", token)["CompanyInfo"]
          { label: info.is_a?(Hash) ? info["CompanyName"] : nil }
        },
        default_label: ->(_account) { "QuickBooks company" },
        api_base: lambda { |_integration, connection|
          "#{Quickbooks.api_url(connection.metadata.to_h['environment'])}/v3/company/#{connection.account_id}"
        },
        stand_in: { callback_params: { realmId: "1000000001" },
                    answer: { "CompanyInfo" => { "CompanyName" => "Stand-in Company" } } }
    end
  end
end
