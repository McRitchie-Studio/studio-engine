# frozen_string_literal: true

module Studio
  module Integrations
    # MICROSOFT 365 (Microsoft Graph, app-only), the connection only. A host's
    # readers (users, teams, sites) are its own; they call
    # Studio.integration(:microsoft_365).api_base(connection) with a token from
    # Studio.connection(:microsoft_365).access_token(connection).
    #
    #   * A tenant administrator approves the app at Microsoft's admin-consent
    #     page (common: the tenant is not known until they sign in). Microsoft
    #     comes back with ?tenant=<GUID>&admin_consent=True; anything but an
    #     approval refuses the callback.
    #   * The tenant id is private: stored only encrypted, the row keyed by a
    #     digest, the callback's tenant param kept out of the logs by exact
    #     key. It is lower-cased, so one tenant never makes two rows.
    #   * CLIENT CREDENTIALS on the tenant's own token endpoint, with the Graph
    #     .default scope (the application permissions the app registration
    #     lists). No refresh token exists: the access token lives in this
    #     process's memory only, per tenant.
    #   * unauthorized_client means the app is not found in, or not enabled
    #     for, the tenant: the grant is gone.
    #   * NO REVOKE endpoint: consent is removed in the tenant's admin center.
    #
    # Checked against the hub's Msgraph::OAuthClient and Msgraph::Reader
    # (mcritchie-studio), which cite Microsoft's identity-platform docs.
    module Microsoft365
      LOGIN_HOST = "https://login.microsoftonline.com"
      AUTHORIZE_URL = "#{LOGIN_HOST}/common/adminconsent"
      SCOPE = "https://graph.microsoft.com/.default"
      API_URL = "https://graph.microsoft.com/v1.0"
      TENANT_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      Integrations.register :microsoft_365,
        label: "Microsoft 365",
        summary: "A Microsoft 365 tenant, read app-only after an administrator approves the app.",
        connection: {
          grant: :client_credentials,
          authorize_url: AUTHORIZE_URL,
          token_url: ->(tenant) { "#{LOGIN_HOST}/#{tenant}/oauth2/v2.0/token" },
          scopes: [SCOPE],
          account: :callback, account_param: "tenant", account_format: TENANT_ID,
          normalize_account: ->(value) { value.to_s.strip.downcase },
          private_account: true, filter_keys: %w[tenant],
          revoked_errors: %w[unauthorized_client],
          declined_errors: %w[access_denied permission_denied consent_required],
          callback_check: lambda { |params|
            "Microsoft did not report an approval. Nothing was connected." unless params[:admin_consent].to_s.casecmp?("true")
          },
          refusal_hint: "A tenant bought through a reseller may block the approval; otherwise check the app registration's redirect URI, then start again.",
          revoke_note: "Remove the app in the tenant's Microsoft Entra admin center (Enterprise applications) to revoke its access there."
        },
        describe: lambda { |integration, grant:, account:, get:|
          token = integration.provider.access_token(account)
          { label: get.call("#{API_URL}/organization/#{account}", token)["displayName"] }
        },
        default_label: ->(_tenant) { "Microsoft 365 tenant" },
        api_base: ->(_integration, _connection) { API_URL },
        stand_in: { callback_params: { tenant: "00000000-0000-0000-0000-000000000365", admin_consent: "True" },
                    answer: { "displayName" => "Stand-in Tenant" } }
    end
  end
end
