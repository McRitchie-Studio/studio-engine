# frozen_string_literal: true

module Studio
  module Integrations
    # QUICKBOOKS ONLINE (Intuit), the connection only. A host's readers (company
    # info, reports) are its own; they call Studio.integration(:quickbooks).api_base(connection).
    #
    #   * Sign-in at Intuit's app center. The endpoints come from Intuit's
    #     discovery document
    #     (https://developer.api.intuit.com/.well-known/openid_configuration),
    #     the same for sandbox and production.
    #   * The token and revoke calls authenticate with HTTP Basic; the revoke
    #     body is JSON.
    #   * CACHED access token, refreshed when it expires: Intuit's access token
    #     lives about an hour (expires_in 3600). The row keeps it, encrypted,
    #     with its expiry, and reuses it until 5 minutes before that expiry, or
    #     until the API answers 401 (fresh_access_token(stale: token)). Then it
    #     refreshes ONCE under the row's lock, reloading the row first, so a
    #     racing caller waits and reads the new token instead of spending the
    #     refresh token twice. A reader that still gets a 401 after that one
    #     refresh asks the admin to connect again; it never loops.
    #   * The refresh token ROTATES and the newest must be kept: every refresh
    #     answer must carry one (rotation: :required, else nothing is stored and
    #     the refresh refuses), and it is stored, with the access token and
    #     x_refresh_token_expires_in, before the access token is used.
    #   * invalid_grant on a refresh is a revoked grant: connect again.
    #   * intuit_tid: Intuit names every answer with this response header, and
    #     asks apps to keep it for support. It is read from every token
    #     exchange, refresh, revoke and describe answer, logged with the call
    #     (no token), kept as provider.last_trace_id, and carried by every error
    #     raised (Error#trace_id, and in its message, so the error log has it).
    #     Host readers call provider.record_trace(response, call:, status:).
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
          refresh: :cached, refresh_margin: 5.minutes, rotation: :required,
          refresh_expires_in_key: "x_refresh_token_expires_in",
          account: :callback, account_param: "realmId", account_format: REALM_ID,
          filter_keys: %w[realmId], trace_header: "intuit_tid",
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
