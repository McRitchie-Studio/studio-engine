# frozen_string_literal: true

require "bundler/setup"
require_relative "../support/connections_host"

# [unit] The connections tooling below the controller: a provider's
# definition, its authorize URL, code exchange, the three refresh policies
# (rotating under the row's lock, cached until near expiry, in-memory client
# credentials), the revoke, Studio::Connection's encryption, and the log
# filter. Every provider is a generic test provider (test/support/connections_host.rb);
# every HTTP answer is a stub.
class ConnectionsClientTest < ActiveSupport::TestCase
  include ConnectionsHost

  setup do
    ConnectionsHost.define_providers!
    Studio::Connection.delete_all
  end

  def ledger = Studio.connection(:ledger)
  def drive = Studio.connection(:drive)
  def tenant = Studio.connection(:tenant)

  def query(url) = Rack::Utils.parse_query(URI(url).query)

  # --- definition ------------------------------------------------------------

  test "[unit] a definition is checked at boot: key, env names, policy and account source" do
    base = { label: "X", env: { client_id: "A", client_secret: "B" }, authorize_url: "https://x.example/a", token_url: "https://x.example/t" }

    assert_raises(ArgumentError) { Studio::Connections::Provider.new("Bad-Key", **base) }
    assert_raises(ArgumentError) { Studio::Connections::Provider.new(:x, **base, env: { client_id: "A" }) }
    assert_raises(ArgumentError) { Studio::Connections::Provider.new(:x, **base, refresh: :sometimes) }
    assert_raises(ArgumentError, "a code grant never keeps its token in memory") { Studio::Connections::Provider.new(:x, **base, refresh: :memory) }
    assert_raises(ArgumentError, "a client-credentials grant always does") do
      Studio::Connections::Provider.new(:x, **base, grant: :client_credentials, refresh: :rotating)
    end
    assert_raises(ArgumentError, "an account from the callback needs a format") do
      Studio::Connections::Provider.new(:x, **base, account: :callback, account_param: "id")
    end
    assert_raises(ArgumentError) { Studio::Connections.fetch(:nope) }
  end

  test "[unit] a provider stays off until both env names are set; the stand-in makes it connectable" do
    with_env(ENV_VALUES.merge("LEDGER_CLIENT_SECRET" => nil)) do
      assert_not ledger.configured?
      assert_not ledger.connectable?
      error = assert_raises(Studio::Connections::NotConfigured) { ledger.authorize_url(redirect_uri: "https://app.example/cb", state: "s") }
      assert_includes error.message, "LEDGER_CLIENT_ID and LEDGER_CLIENT_SECRET"

      Studio::Connections::StandIn.install!(ledger)
      assert ledger.connectable?
      assert_not ledger.configured?
    end
  end

  test "[unit] the test seams are refused on a production server" do
    Rails.env = "production"
    assert Studio::Connections.production?
    assert_raises(Studio::Connections::Error) { ledger.http = ->(*) {} }
    assert_raises(Studio::Connections::Error) { ledger.sign_in_stand_in = Object.new }
    ledger.http = nil # clearing one is always allowed
    assert_nil ledger.http
  ensure
    Rails.env = "test"
  end

  # --- the browser leg ---------------------------------------------------------

  test "[unit] a code grant's sign-in asks for the scopes with the state" do
    with_env do
      url = ledger.authorize_url(redirect_uri: "https://app.example/admin/ledger/callback", state: "st")

      assert url.start_with?("https://auth.ledger.example/oauth2?")
      assert_equal({ "client_id" => "ledger-id", "redirect_uri" => "https://app.example/admin/ledger/callback", "state" => "st",
                     "response_type" => "code", "scope" => "ledger.read" }, query(url))
    end
  end

  test "[unit] a per-account host takes only an account that passes the format" do
    with_env do
      assert URI(drive.authorize_url(redirect_uri: "https://a.example/cb", state: "s", account: "acme")).host == "acme.drive.example"
      assert_equal "acme", drive.normalize_account(" https://ACME.drive.example/ ")

      ["evil.example/x", "a..b", "-acme", "acme.evil.example", "", nil, "a" * 64].each do |bad|
        assert_nil drive.normalize_account(bad), "#{bad.inspect} is not an account"
        assert_raises(Studio::Connections::InvalidAccount) { drive.authorize_url(redirect_uri: "https://a.example/cb", state: "s", account: bad) }
      end
    end
  end

  test "[unit] an admin consent asks for no scope and no code" do
    with_env do
      url = tenant.authorize_url(redirect_uri: "https://app.example/admin/tenant/callback", state: "st")

      assert_equal({ "client_id" => "tenant-id", "redirect_uri" => "https://app.example/admin/tenant/callback", "state" => "st" }, query(url))
    end
  end

  # --- the code exchange ---------------------------------------------------------

  test "[unit] HTTP Basic client auth puts the secret in the header, never the form" do
    with_env do
      requests = stub_http(ledger, grant(access_token: "a1", refresh_token: "r1"))
      ledger.exchange_code(code: "c0de", redirect_uri: "https://app.example/cb")

      request = requests.sole
      assert_equal "https://auth.ledger.example/oauth2/token", request[:url]
      assert_equal({ grant_type: "authorization_code", code: "c0de", redirect_uri: "https://app.example/cb" }, request[:form])
      assert_equal "Basic #{Base64.strict_encode64('ledger-id:ledger-secret')}", request[:headers]["Authorization"]
      assert_equal "application/x-www-form-urlencoded", request[:headers]["Content-Type"]
    end
  end

  test "[unit] form client auth posts the id, the secret and the exchange params to the account's own host" do
    with_env do
      requests = stub_http(drive, grant(access_token: "a1", refresh_token: "r1", expires_in: 2_592_000))
      drive.exchange_code(code: "c0de", redirect_uri: "https://app.example/cb", account: "acme")

      request = requests.sole
      assert_equal "https://acme.drive.example/oauth/token", request[:url]
      assert_equal({ grant_type: "authorization_code", code: "c0de", redirect_uri: "https://app.example/cb", scope: "drive.files",
                     client_id: "drive-id", client_secret: "drive-secret" }, request[:form])
      assert_nil request[:headers]["Authorization"]
    end
  end

  test "[unit] a refused exchange raises with the provider's detail, never a token" do
    with_env do
      stub_http(ledger, [400, { error: "invalid_request", error_description: "bad redirect\nsecond line" }.to_json])
      error = assert_raises(Studio::Connections::Error) { ledger.exchange_code(code: "c", redirect_uri: "https://a.example/cb") }

      assert_equal "Ledger answered 400: bad redirect", error.message
    end
  end

  # --- :rotating -------------------------------------------------------------------

  test "[unit] rotating: each refresh spends the stored token and stores the answer before the access token is used" do
    with_env do
      connection = store(:ledger, account: "4620", refresh_token: "r1", x_refresh_token_expires_in: 8_726_400)
      assert_nil connection.access_token, "a rotating provider keeps no access token"
      requests = stub_http(ledger, grant(access_token: "a2", refresh_token: "r2", x_refresh_token_expires_in: 100),
                                   grant(access_token: "a3", refresh_token: "r3"))

      assert_equal "a2", connection.fresh_access_token
      assert_equal "r2", connection.reload.refresh_token
      assert_in_delta Time.current + 100, connection.refresh_expires_at, 5
      assert_equal "a3", connection.fresh_access_token
      assert_equal "r3", connection.reload.refresh_token
      assert_equal %w[r1 r2], requests.map { _1[:form][:refresh_token] }
      assert_nil connection.access_token
    end
  end

  test "[unit] rotating: a caller holding a stale row spends the NEWEST token, because the lock reloads it" do
    with_env do
      first = store(:ledger, account: "4620", refresh_token: "r1")
      second = Studio::Connection.find(first.id)
      requests = stub_http(ledger, grant(access_token: "a2", refresh_token: "r2"), grant(access_token: "a3", refresh_token: "r3"))

      first.fresh_access_token
      assert_equal "r1", second.refresh_token, "the second object still holds the spent token in memory"
      second.fresh_access_token

      assert_equal %w[r1 r2], requests.map { _1[:form][:refresh_token] }, "the second refresh never spends r1 again"
      assert_equal "r3", first.reload.refresh_token
    end
  end

  test "[unit] rotating: an answer with no refresh token is refused and the stored one kept" do
    with_env do
      connection = store(:ledger, account: "4620", refresh_token: "r1")
      stub_http(ledger, grant(access_token: "a2"))

      assert_raises(Studio::Connections::Error) { connection.fresh_access_token }
      assert_equal "r1", connection.reload.refresh_token
    end
  end

  test "[unit] rotating: invalid_grant is Revoked and changes nothing" do
    with_env do
      connection = store(:ledger, account: "4620", refresh_token: "r1")
      stub_http(ledger, [400, { error: "invalid_grant" }.to_json])

      error = assert_raises(Studio::Connections::Revoked) { connection.fresh_access_token }
      assert_includes error.message, "connect again"
      assert_equal "r1", connection.reload.refresh_token
    end
  end

  # --- :cached ---------------------------------------------------------------------

  test "[unit] cached: a fresh access token is handed back with no request" do
    with_env do
      connection = store(:drive, account: "acme", access_token: "a1", refresh_token: "r1", expires_in: 2_592_000)
      requests = stub_http(drive)

      assert_equal "a1", connection.fresh_access_token
      assert_empty requests
    end
  end

  test "[unit] cached: within the margin it refreshes once, under the lock, and stores the new pair" do
    with_env do
      connection = store(:drive, account: "acme", access_token: "a1", refresh_token: "r1", expires_in: 3600)
      requests = stub_http(drive, grant(access_token: "a2", refresh_token: "r2", expires_in: 2_592_000))

      assert_equal "a2", connection.fresh_access_token
      connection.reload
      assert_equal %w[a2 r2], [connection.access_token, connection.refresh_token]
      assert_equal "a2", connection.fresh_access_token, "now fresh: no second request"
      assert_equal 1, requests.size
      assert_equal "https://acme.drive.example/oauth/token", requests.sole[:url]
    end
  end

  test "[unit] cached: a 401's stale token is refreshed unless another caller already replaced it" do
    with_env do
      connection = store(:drive, account: "acme", access_token: "a1", refresh_token: "r1", expires_in: 2_592_000)
      requests = stub_http(drive, grant(access_token: "a2", expires_in: 2_592_000))

      assert_equal "a2", connection.fresh_access_token(stale: "a1")
      assert_equal "r1", connection.reload.refresh_token, "an answer with no refresh token keeps the stored one"
      assert_equal "a2", connection.fresh_access_token(stale: "a1"), "a1 was already replaced: no second refresh"
      assert_equal 1, requests.size
    end
  end

  test "[unit] cached: throttling is RateLimited; an invalid refresh token is Revoked" do
    with_env do
      connection = store(:drive, account: "acme", access_token: "a1", refresh_token: "r1", expires_in: 60)
      stub_http(drive, [409, { message: "Developer over rate" }.to_json], [400, { message: "Invalid Refresh Token" }.to_json])

      assert_raises(Studio::Connections::RateLimited) { connection.fresh_access_token }
      assert_raises(Studio::Connections::Revoked) { connection.fresh_access_token }
      assert_equal "a1", connection.reload.access_token
    end
  end

  # --- :memory ---------------------------------------------------------------------

  test "[unit] memory: a client-credentials token is cached per account until near expiry, and never stored" do
    with_env do
      tenant.forget!
      connection = store(:tenant, account: ConnectionsHost::TENANT.upcase)
      requests = stub_http(tenant, grant(access_token: "g1", expires_in: 3599), grant(access_token: "g2", expires_in: 3599))

      assert_equal "g1", connection.fresh_access_token
      assert_equal "g1", tenant.access_token(ConnectionsHost::TENANT), "a bare account id reads the same cache"
      assert_equal 1, requests.size
      request = requests.sole
      assert_equal "https://login.tenant.example/#{ConnectionsHost::TENANT}/oauth2/v2.0/token", request[:url]
      assert_equal({ grant_type: "client_credentials", scope: "https://api.tenant.example/.default",
                     client_id: "tenant-id", client_secret: "tenant-secret" }, request[:form])

      assert_equal "g2", tenant.access_token(ConnectionsHost::TENANT, now: Time.current + 3600), "past expiry less the margin"
      assert_equal 1, tenant.cached_count
      tenant.forget!(ConnectionsHost::TENANT)
      assert_equal 0, tenant.cached_count
      assert_nil connection.reload.access_token
      assert_nil connection.refresh_token
    end
  end

  test "[unit] memory: a tenant that refuses the app is Revoked" do
    with_env do
      tenant.forget!
      stub_http(tenant, [400, { error: "unauthorized_client", error_description: "AADSTS700016: not found" }.to_json])

      assert_raises(Studio::Connections::Revoked) { tenant.access_token(ConnectionsHost::TENANT) }
    end
  end

  test "[unit] a private account is unique by a keyed digest and stored only encrypted" do
    connection = store(:tenant, account: ConnectionsHost::TENANT)
    again = store(:tenant, account: " #{ConnectionsHost::TENANT.upcase} ")

    assert_equal connection.id, again.id, "the same tenant consented twice keeps one row"
    assert_match(/\A\h{64}\z/, connection.account_key)
    assert_equal ConnectionsHost::TENANT, again.account_id
    raw = Studio::Connection.connection.select_value("SELECT account_secret FROM studio_connections WHERE id = #{connection.id}")
    assert_not_includes raw.to_s, ConnectionsHost::TENANT
    assert_not_includes connection.inspect, ConnectionsHost::TENANT
  end

  # --- revoke ----------------------------------------------------------------------

  test "[unit] revoke: a JSON body with Basic auth, or a form with the secret alone; none for a provider without one" do
    with_env do
      ledger_row = store(:ledger, account: "4620", refresh_token: "r1")
      ledger_requests = stub_http(ledger, [200, ""])
      assert_equal true, ledger.revoke(ledger_row)
      assert_equal({ token: "r1" }, ledger_requests.sole[:form])
      assert_equal "application/json", ledger_requests.sole[:headers]["Content-Type"]
      assert ledger_requests.sole[:headers]["Authorization"].start_with?("Basic ")

      drive_row = store(:drive, account: "acme", access_token: "a1", refresh_token: "r1")
      drive_requests = stub_http(drive, [200, ""])
      assert_equal true, drive.revoke(drive_row)
      assert_equal "https://acme.drive.example/oauth/revoke", drive_requests.sole[:url]
      assert_equal({ token: "r1", client_secret: "drive-secret" }, drive_requests.sole[:form], "the secret, but not the id")

      assert_nil tenant.revoke(store(:tenant, account: ConnectionsHost::TENANT))
      stub_http(ledger, [400, { error: "invalid_token" }.to_json])
      assert_raises(Studio::Connections::Error) { ledger.revoke(ledger_row) }
    end
  end

  # --- the row ---------------------------------------------------------------------

  test "[unit] tokens are encrypted at rest and filtered from inspect" do
    connection = store(:drive, account: "acme", access_token: "plain-access", refresh_token: "plain-refresh")
    raw = Studio::Connection.connection.select_rows("SELECT access_token, refresh_token FROM studio_connections WHERE id = #{connection.id}").first

    raw.each { |value| assert_not_includes value, "plain-" }
    assert_not_includes connection.inspect, "plain-"
    assert_equal "plain-access", connection.reload.access_token
  end

  test "[unit] a policy's token is required: the message names the field, never a value" do
    error = assert_raises(ActiveRecord::RecordInvalid) { store(:ledger, account: "4620", access_token: "only-access") }

    assert_includes error.message, "Refresh token"
    assert_not_includes error.message, "only-access"
    assert_raises(Studio::Connections::InvalidAccount) { store(:ledger, account: "not-a-number", refresh_token: "r") }
  end

  test "[unit] a row this server can no longer decrypt is unreadable, and storing the account again replaces it" do
    connection = store(:drive, account: "acme", access_token: "a1", refresh_token: "r1")
    other_keys = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("a-key-this-server-never-had")
    foreign = ActiveRecord::Encryption::Encryptor.new.encrypt("r1", key_provider: other_keys)
    # Raw SQL: update_all would encrypt the foreign ciphertext again with this server's keys.
    sql = Studio::Connection.connection
    sql.execute("UPDATE studio_connections SET refresh_token = #{sql.quote(foreign)} WHERE id = #{connection.id}")

    assert_not Studio::Connection.find(connection.id).readable?
    assert_empty Studio::Connection.readable(:drive)
    replaced = store(:drive, account: "acme", access_token: "a2", refresh_token: "r2")
    assert replaced.readable?
    assert_equal 1, Studio::Connection.for_provider(:drive).count
  end

  test "[unit] without encryption keys the app is not ready to store a connection" do
    config = ActiveRecord::Encryption.config
    saved = config.primary_key
    config.primary_key = nil
    assert_not Studio::Connections.encryption_ready?
  ensure
    config.primary_key = saved
    assert Studio::Connections.encryption_ready?
  end

  # --- the log filter --------------------------------------------------------------

  test "[unit] the filter masks a provider's keys by exact key, String values only" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    assert_equal({ "account_id" => "[FILTERED]" }, filter.filter("account_id" => "4620"))
    assert_equal({ "tenant" => "[FILTERED]" }, filter.filter("tenant" => ConnectionsHost::TENANT))
    assert_equal({ "tenant" => { "id" => "t-1" } }, filter.filter("tenant" => { "id" => "t-1" }), "a nested Hash is spared")
    assert_equal({ "my_account_id" => "x", "tenants" => "y" }, filter.filter("my_account_id" => "x", "tenants" => "y"), "exact keys only")
  end

  test "[unit] a provider declared after boot is covered by the filter the engine already installed" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "late-1", filter.filter("late_account" => "late-1")["late_account"]

    Studio.define_connection :late, label: "Late", env: { client_id: "LATE_ID", client_secret: "LATE_SECRET" },
                                    authorize_url: "https://late.example/a", token_url: "https://late.example/t",
                                    account: :described, filter_keys: %w[late_account]
    assert_equal "[FILTERED]", filter.filter("late_account" => "late-1")["late_account"]
  end

  test "[unit] the Started GET line's URL loses the account and tenant, one pair at a time" do
    env = Rack::MockRequest.env_for("/admin/tenant/callback?tenant=#{ConnectionsHost::TENANT}&admin_consent=True&state=s1&account_id=4620")
    env["action_dispatch.parameter_filter"] = Rails.application.config.filter_parameters
    path = ActionDispatch::Request.new(env).filtered_path

    assert_not_includes path, ConnectionsHost::TENANT
    assert_not_includes path, "4620"
    assert_includes path, "tenant=[FILTERED]"
    assert_includes path, "state=s1"
  end

  test "[unit] the auth code is masked on a connection controller's parameters only" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    %w[studio/connections admin/drive].each do |controller|
      assert_equal "[FILTERED]", filter.filter("controller" => controller, "code" => "c0de")["code"]
    end
    assert_equal "SAVE10", filter.filter("controller" => "coupons", "code" => "SAVE10")["code"]
  end

  # --- the stand-in ----------------------------------------------------------------

  test "[unit] the stand-in honours only the last refresh token it issued" do
    with_env(ENV_VALUES.transform_values { nil }) do
      Studio::Connections::StandIn.install!(ledger)
      url = ledger.authorize_url(redirect_uri: "https://app.example/cb", state: "s")
      assert_equal Studio::Connections::StandIn::CODE, query(url)["code"]

      first = ledger.exchange_code(code: Studio::Connections::StandIn::CODE, redirect_uri: "https://app.example/cb")
      connection = Studio::Connection.store!(:ledger, first, account: "1", by: "t")
      connection.fresh_access_token
      connection.update!(refresh_token: first["refresh_token"]) # as if the rotation had not been stored

      assert_raises(Studio::Connections::Revoked) { connection.reload.fresh_access_token }
    end
  end
end
