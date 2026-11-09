# frozen_string_literal: true

require "bundler/setup"
require_relative "../support/integrations_host"

# [unit] The integrations registry below the controller: the catalog, the
# enable switch, and each engine definition (QuickBooks, Egnyte, Microsoft 365)
# as a connection: its authorize URL, code exchange, refresh policy, revoke,
# account rules, log filter keys and its one describe call. Every HTTP answer
# is a stub (test/support/integrations_host.rb).
class IntegrationsDefinitionsTest < ActiveSupport::TestCase
  include IntegrationsHost

  setup do
    IntegrationsHost.enable!
    Studio::Connection.delete_all
    Studio.connection(:microsoft_365).forget!
  end

  def qbo = Studio.integration(:quickbooks)
  def egnyte = Studio.integration(:egnyte)
  def m365 = Studio.integration(:microsoft_365)
  def query(url) = Rack::Utils.parse_query(URI(url).query)

  def filtered(key, value = "secret-value", params = {})
    copy = value.dup
    Studio::Connections::LOG_FILTER.call(key, copy, params)
    copy
  end

  def in_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  # --- the catalog and the switch ------------------------------------------

  test "[unit] the catalog holds the three connection definitions, each frozen" do
    assert_equal %w[quickbooks egnyte microsoft_365], Studio::Integrations.catalog.map(&:key)
    assert Studio::Integrations.catalog.all?(&:frozen?)
    assert_raises(ArgumentError) { Studio::Integrations.definition(:fathom) }
  end

  test "[unit] a definition carries the connection only: no reader, no business-data call" do
    assert_equal %i[key label summary connection settings account_label account_hint metadata describe default_label api_base stand_in],
                 Studio::Integrations::Definition.members
    public_api = Studio::Integrations::Integration.public_instance_methods(false).sort
    assert_equal %i[api_base api_http api_http= connections definition describe_account env install_stand_in! key label
                    missing panel provider setting status status_label summary uninstall_stand_in!].sort, public_api
    refute qbo.respond_to?(:describe_get), "the describe transport is not a reader a host can call"
  end

  test "[unit] enable names the host's env vars, defines the connection, and refuses an unknown env key" do
    provider = Studio.connection(:quickbooks)
    assert_same provider, qbo.provider
    assert_equal %w[HOST_QBO_ID HOST_QBO_SECRET], provider.env_names
    assert_equal "QuickBooks", provider.label
    assert_equal [qbo, egnyte, m365], Studio.integrations

    assert_raises(ArgumentError) { Studio.enable_integration(:egnyte, env: { client_id: "A", client_secret: "B", environment: "C" }) }
    assert_raises(ArgumentError) { Studio.enable_integration(:egnyte, env: { client_id: "A", client_secret: :B }) }
    assert_raises(ArgumentError) { Studio.enable_integration(:egnyte, env: { client_id: "A" }) }
    assert_raises(ArgumentError) { Studio.enable_integration(:nope, env: { client_id: "A", client_secret: "B" }) }
    assert_raises(ArgumentError) { Studio.integration(:nope) }
  end

  test "[unit] an enabled integration stays off until its client id and secret are set" do
    refute qbo.provider.configured?
    assert_equal :not_set_up, qbo.status
    assert_equal ["HOST_QBO_ID and HOST_QBO_SECRET are not set."], qbo.missing
    assert_raises(Studio::Connections::NotConfigured) { qbo.provider.authorize_url(redirect_uri: "https://app.example/cb", state: "s") }

    with_env do
      assert_equal :ready, qbo.status
      assert_empty qbo.missing
      Studio::Connection.store!(:quickbooks, { "refresh_token" => "r1" }, account: "4620", by: "tester")
      assert_equal :connected, qbo.status
      assert_equal "Connected", qbo.status_label
    end
    with_env("HOST_QBO_ID" => "qbo-id", "HOST_QBO_SECRET" => " ") do
      assert_equal ["HOST_QBO_SECRET is not set."], qbo.missing
    end
  end

  test "[unit] without the encryption keys an integration is not set up, whatever its env" do
    with_env do
      without_encryption do
        assert_equal :not_set_up, egnyte.status
        assert_equal ["The app's Active Record encryption keys are not set."], egnyte.missing
      end
    end
  end

  test "[unit] enable may relabel and rescope; the definition is unchanged" do
    Studio.enable_integration :quickbooks, env: { client_id: "A", client_secret: "B" }, label: "Books", scopes: %w[com.intuit.quickbooks.accounting openid]
    assert_equal "Books", Studio.integration(:quickbooks).label
    assert_equal %w[com.intuit.quickbooks.accounting openid], Studio.connection(:quickbooks).scopes
    assert_equal "QuickBooks", Studio::Integrations.definition(:quickbooks).label
  end

  # --- QuickBooks ------------------------------------------------------------

  test "[unit] quickbooks: Intuit's sign-in with the accounting scope; the company comes back on the callback" do
    with_env do
      url = qbo.provider.authorize_url(redirect_uri: "https://app.example/admin/integrations/quickbooks/callback", state: "s1")
      assert url.start_with?("https://appcenter.intuit.com/connect/oauth2?")
      assert_equal({ "client_id" => "qbo-id", "redirect_uri" => "https://app.example/admin/integrations/quickbooks/callback",
                     "state" => "s1", "response_type" => "code", "scope" => "com.intuit.quickbooks.accounting" }, query(url))
    end
    assert_equal :callback, qbo.provider.account_source
    assert_equal "realmId", qbo.provider.account_param
    assert_equal "9341452177", qbo.provider.normalize_account(" 9341452177 ")
    assert_nil qbo.provider.normalize_account("93414x")
  end

  test "[unit] quickbooks: Basic client auth, a rotating refresh that keeps the latest token and its lifetime" do
    with_env do
      requests = stub_tokens(qbo, answer(access_token: "a1", refresh_token: "r1", expires_in: 3600, x_refresh_token_expires_in: 8_726_400),
                             answer(access_token: "a2", refresh_token: "r2", expires_in: 3600, x_refresh_token_expires_in: 8_000_000))
      grant = qbo.provider.exchange_code(code: "c1", redirect_uri: "https://app.example/cb")
      assert_equal "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer", requests[0][:url]
      assert_equal "Basic #{Base64.strict_encode64('qbo-id:qbo-secret')}", requests[0][:headers]["Authorization"]
      refute requests[0][:form].key?(:client_secret), "Basic auth: the secret rides the header, not the form"

      row = Studio::Connection.store!(:quickbooks, grant, account: "4620", by: "tester")
      assert_nil row.access_token, "a rotating connection stores no access token"
      assert_equal "a2", row.fresh_access_token
      row.reload
      assert_equal "r2", row.refresh_token
      assert_in_delta Time.current + 8_000_000, row.refresh_expires_at, 5
    end
  end

  test "[unit] quickbooks: a refresh without a new refresh token, or an invalid_grant, refuses" do
    with_env do
      row = Studio::Connection.store!(:quickbooks, { "refresh_token" => "r1" }, account: "4620", by: "tester")
      stub_tokens(qbo, answer(access_token: "a2"))
      assert_raises(Studio::Connections::Error) { row.fresh_access_token }
      assert_equal "r1", row.reload.refresh_token

      stub_tokens(qbo, answer(400, error: "invalid_grant"))
      assert_raises(Studio::Connections::Revoked) { row.fresh_access_token }
    end
  end

  test "[unit] quickbooks: the revoke is a JSON body with Basic auth" do
    with_env do
      row = Studio::Connection.store!(:quickbooks, { "refresh_token" => "r9" }, account: "4620", by: "tester")
      requests = stub_tokens(qbo, [200, ""])
      assert qbo.provider.revoke(row)
      assert_equal "https://developer.api.intuit.com/v2/oauth2/tokens/revoke", requests[0][:url]
      assert_equal "application/json", requests[0][:headers]["Content-Type"]
      assert_equal({ token: "r9" }, requests[0][:form])
      assert requests[0][:headers]["Authorization"].start_with?("Basic ")
    end
  end

  test "[unit] quickbooks: the environment is the sandbox unless the host's env var says production" do
    with_env do
      assert_equal "sandbox", qbo.setting(:environment)
      with_env("HOST_QBO_ENVIRONMENT" => " Production ") { assert_equal "production", qbo.setting(:environment) }
      with_env("HOST_QBO_ENVIRONMENT" => "prod") { assert_equal "sandbox", qbo.setting(:environment) }
    end
    Studio.enable_integration :quickbooks, env: { client_id: "A", client_secret: "B" }
    with_env("HOST_QBO_ENVIRONMENT" => "production") { assert_equal "sandbox", Studio.integration(:quickbooks).setting(:environment) }
  end

  test "[unit] quickbooks: describe reads the company name once, on the environment's API host, and stores the environment" do
    with_env("HOST_QBO_ENVIRONMENT" => "production") do
      requests = stub_describe(qbo, answer(CompanyInfo: { CompanyName: "Acme Books" }))
      described = qbo.describe_account(grant: { "access_token" => "a1" }, account: "4620")
      assert_equal({ label: "Acme Books", metadata: { "environment" => "production" } }, described)
      assert_equal 1, requests.size
      assert_equal "https://quickbooks.api.intuit.com/v3/company/4620/companyinfo/4620?minorversion=75", requests[0][:url]
      assert_equal "Bearer a1", requests[0][:headers]["Authorization"]
    end
  end

  test "[unit] quickbooks: a refused describe keeps the environment and the default label" do
    stub_describe(qbo, answer(403, Fault: {}))
    described = qbo.describe_account(grant: { "access_token" => "a1" }, account: "4620")
    assert_equal({ label: "QuickBooks company", metadata: { "environment" => "sandbox" } }, described)
  end

  test "[unit] quickbooks: api_base follows the connection's stored environment" do
    row = Studio::Connection.store!(:quickbooks, { "refresh_token" => "r1" }, account: "4620", by: "tester", metadata: { environment: "production" })
    assert_equal "https://quickbooks.api.intuit.com/v3/company/4620", qbo.api_base(row)
    row.update!(metadata: {})
    assert_equal "https://sandbox-quickbooks.api.intuit.com/v3/company/4620", qbo.api_base(row)
  end

  test "[unit] quickbooks: realmId is kept out of the logs by exact key only" do
    assert_equal "[FILTERED]", filtered("realmId")
    assert_equal "secret-value", filtered("realmIdentity")
    assert_equal "secret-value", filtered("realmid")
  end

  # --- Egnyte ------------------------------------------------------------------

  test "[unit] egnyte: the domain typed at Connect is lower-cased, stripped to a DNS label, or refused" do
    provider = egnyte.provider
    assert_equal :connect, provider.account_source
    assert_equal "egnyte_domain", provider.account_param
    %w[acme Acme ACME.egnyte.com https://Acme.Egnyte.com/ https://acme.egnyte.com/app?x=1].each do |typed|
      assert_equal "acme", provider.normalize_account(typed), typed
    end
    ["", "acme.evil.example", "-acme", "acme_co", "a" * 64, "acme.egnyte.com.evil.example"].each do |typed|
      assert_nil provider.normalize_account(typed), typed
    end
    assert_raises(Studio::Connections::InvalidAccount) { provider.url_for(:token, "acme.evil.example") }
  end

  test "[unit] egnyte: the sign-in and the token endpoint live on the domain's own host" do
    with_env do
      url = egnyte.provider.authorize_url(redirect_uri: "https://app.example/cb", state: "s1", account: "acme")
      assert url.start_with?("https://acme.egnyte.com/puboauth/token?")
      assert_equal "Egnyte.filesystem", query(url)["scope"]
      assert_equal "code", query(url)["response_type"]

      requests = stub_tokens(egnyte, answer(access_token: "a1", refresh_token: "r1", expires_in: 2_592_000))
      egnyte.provider.exchange_code(code: "c1", redirect_uri: "https://app.example/cb", account: "acme")
      assert_equal "https://acme.egnyte.com/puboauth/token", requests[0][:url]
      assert_equal({ grant_type: "authorization_code", code: "c1", redirect_uri: "https://app.example/cb", scope: "Egnyte.filesystem",
                     client_id: "egnyte-id", client_secret: "egnyte-secret" }, requests[0][:form])
    end
  end

  test "[unit] egnyte: the access token is cached and refreshed only within a day of expiry" do
    with_env do
      row = Studio::Connection.store!(:egnyte, { "access_token" => "a1", "refresh_token" => "r1", "expires_in" => 2_592_000 },
                                      account: "acme", by: "tester")
      requests = stub_tokens(egnyte, answer(access_token: "a2", refresh_token: "r2", expires_in: 2_592_000))
      assert_equal "a1", row.fresh_access_token
      assert_empty requests

      row.update!(access_expires_at: 23.hours.from_now)
      assert_equal "a2", row.fresh_access_token
      assert_equal 1, requests.size
      assert_equal "r2", row.reload.refresh_token
    end
  end

  test "[unit] egnyte: a 409 is throttling, an invalid refresh token is a revoked grant" do
    with_env do
      row = Studio::Connection.store!(:egnyte, { "access_token" => "a1", "refresh_token" => "r1", "expires_in" => 60 }, account: "acme", by: "tester")
      stub_tokens(egnyte, answer(409, message: "Developer over rate"))
      assert_raises(Studio::Connections::RateLimited) { row.fresh_access_token }
      stub_tokens(egnyte, answer(400, error_description: "Invalid refresh token"))
      assert_raises(Studio::Connections::Revoked) { row.fresh_access_token }
    end
  end

  test "[unit] egnyte: the revoke sends the token and the secret, never the id" do
    with_env do
      row = Studio::Connection.store!(:egnyte, { "access_token" => "a1", "refresh_token" => "r1" }, account: "acme", by: "tester")
      requests = stub_tokens(egnyte, [200, ""])
      assert egnyte.provider.revoke(row)
      assert_equal "https://acme.egnyte.com/pubapi/v1/tokens/revoke", requests[0][:url]
      assert_equal({ token: "r1", client_secret: "egnyte-secret" }, requests[0][:form])
    end
  end

  test "[unit] egnyte: describe asks who signed in once; the label is the domain's host" do
    requests = stub_describe(egnyte, answer(username: "jdoe"))
    described = egnyte.describe_account(grant: { "access_token" => "a1" }, account: "acme")
    assert_equal({ label: "acme.egnyte.com", metadata: { "username" => "jdoe" } }, described)
    assert_equal ["https://acme.egnyte.com/pubapi/v1/whoami"], requests.map { _1[:url] }
    assert_equal "https://acme.egnyte.com/pubapi/v1", egnyte.api_base(Studio::Connection.new(provider: "egnyte", account_key: "acme"))
  end

  # --- Microsoft 365 -----------------------------------------------------------

  test "[unit] microsoft_365: an administrator's consent at the common endpoint; no scope on it" do
    with_env do
      url = m365.provider.authorize_url(redirect_uri: "https://app.example/cb", state: "s1")
      assert url.start_with?("https://login.microsoftonline.com/common/adminconsent?")
      assert_equal({ "client_id" => "m365-id", "redirect_uri" => "https://app.example/cb", "state" => "s1" }, query(url))
    end
    check = m365.provider.callback_check
    assert_nil check.call(ActionController::Parameters.new(admin_consent: "True"))
    assert_match(/did not report an approval/, check.call(ActionController::Parameters.new(admin_consent: "False")))
    assert_match(/did not report an approval/, check.call(ActionController::Parameters.new({})))
  end

  test "[unit] microsoft_365: the tenant is lower-cased, private, and keyed by a digest" do
    provider = m365.provider
    assert_equal TENANT, provider.normalize_account(TENANT.upcase)
    assert_nil provider.normalize_account("not-a-guid")
    row = Studio::Connection.store!(:microsoft_365, {}, account: TENANT.upcase, by: "tester")
    assert_equal TENANT, row.account_id
    refute_equal TENANT, row.account_key
    again = Studio::Connection.store!(:microsoft_365, {}, account: TENANT, by: "tester")
    assert_equal row.id, again.id, "one tenant, whatever its case, is one row"
  end

  test "[unit] microsoft_365: client credentials on the tenant's token endpoint, cached in memory" do
    with_env do
      requests = stub_tokens(m365, answer(access_token: "t1", expires_in: 3600))
      assert_equal "t1", m365.provider.access_token(TENANT.upcase)
      assert_equal "t1", m365.provider.access_token(TENANT)
      assert_equal 1, requests.size
      assert_equal "https://login.microsoftonline.com/#{TENANT}/oauth2/v2.0/token", requests[0][:url]
      assert_equal({ grant_type: "client_credentials", scope: "https://graph.microsoft.com/.default",
                     client_id: "m365-id", client_secret: "m365-secret" }, requests[0][:form])
    end
  end

  test "[unit] microsoft_365: unauthorized_client is a revoked grant; there is no revoke endpoint" do
    with_env do
      stub_tokens(m365, answer(400, error: "unauthorized_client"))
      assert_raises(Studio::Connections::Revoked) { m365.provider.access_token(TENANT) }
    end
    refute m365.provider.revocable?
    assert_match(/admin center/, m365.provider.revoke_note)
  end

  test "[unit] microsoft_365: describe takes an app token, then reads the organization's name once" do
    with_env do
      stub_tokens(m365, answer(access_token: "t1", expires_in: 3600))
      requests = stub_describe(m365, answer(displayName: "Acme Corp"))
      described = m365.describe_account(grant: {}, account: TENANT)
      assert_equal({ label: "Acme Corp", metadata: {} }, described)
      assert_equal ["https://graph.microsoft.com/v1.0/organization/#{TENANT}"], requests.map { _1[:url] }
      assert_equal "Bearer t1", requests[0][:headers]["Authorization"]
    end
  end

  test "[unit] microsoft_365: tenant is kept out of the logs by exact key only" do
    assert_equal "[FILTERED]", filtered("tenant")
    assert_equal "secret-value", filtered("tenant_name")
    assert_equal "secret-value", filtered("Tenant")
  end

  # --- the describe call and the stand-ins ---------------------------------

  test "[unit] the describe call refuses plain http and treats a 429 as throttling" do
    assert_raises(Studio::Connections::Error) { qbo.send(:describe_get, "http://quickbooks.api.intuit.com/x", "t") }
    stub_describe(qbo, answer(429))
    assert_raises(Studio::Connections::RateLimited) { qbo.send(:describe_get, "https://quickbooks.api.intuit.com/x", "t") }
    stub_describe(qbo, [200, "not json"])
    assert_equal({}, qbo.send(:describe_get, "https://quickbooks.api.intuit.com/x", "t"))
  end

  test "[unit] the stand-ins are refused outside development and test" do
    %w[production staging].each do |name|
      in_env(name) do
        assert_raises(Studio::Connections::Error) { qbo.api_http = ->(_url, _headers) { [200, "{}"] } }
        assert_raises(Studio::Connections::Error) { egnyte.install_stand_in! }
        assert_nil qbo.api_http
      end
    end
    in_env("development") { assert egnyte.install_stand_in!.provider.sign_in_stand_in }
    egnyte.uninstall_stand_in!
    assert_nil egnyte.api_http
    assert_nil egnyte.provider.http
  end
end
