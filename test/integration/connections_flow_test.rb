# frozen_string_literal: true

require "bundler/setup"
require_relative "../support/connections_host"

# [integration] The connect, callback and disconnect flow over HTTP, for each
# generic test provider (test/support/connections_host.rb): the admin guard,
# the OAuth state, the account named before Connect (kept in the session, never
# read from the callback), the account named on the callback, an admin
# consent, the describe hook, the return_to allowlist, the off switches
# (credentials and encryption keys), the revoke on disconnect, and the log
# filter on a real callback request.
class ConnectionsFlowTest < ActionDispatch::IntegrationTest
  include ConnectionsHost

  setup do
    ConnectionsHost.define_providers!
    Studio::Connection.delete_all
    ErrorLog.delete_all
    User.delete_all
    Studio.connection(:tenant).forget!
    @admin = User.create!(email: "admin@app.example", slug: "the-admin", role: "admin")
  end

  def sign_in(user = @admin)
    post "/connections_test_sign_in/#{user.id}"
    assert_response :ok
  end

  def ledger = Studio.connection(:ledger)
  def drive = Studio.connection(:drive)
  def tenant = Studio.connection(:tenant)

  def started_state
    query = Rack::Utils.parse_query(URI(response.location).query)
    query.fetch("state")
  end

  # --- who may ---------------------------------------------------------------

  test "only the host's admin guard lets a person connect, call back or disconnect" do
    with_env do
      sign_in(User.create!(email: "member@app.example", role: "member"))
      get "/admin/ledger/connect"
      assert_redirected_to "/"
      get "/admin/ledger/callback", params: { state: "x", code: "c" }
      assert_redirected_to "/"
      row = store(:ledger, account: "4620", refresh_token: "r1")
      delete "/admin/ledger/connections/#{row.id}"
      assert_redirected_to "/"
      assert Studio::Connection.exists?(row.id)
    end
  end

  test "a callable guard that answers false or nil refuses with 403; true lets the admin in" do
    saved = Studio.connection_admin_guard
    with_env do
      sign_in
      [false, nil].each do |answer|
        Studio.connection_admin_guard = ->(_controller) { answer }
        get "/admin/ledger/connect"
        assert_response :forbidden, answer.inspect
      end
      Studio.connection_admin_guard = ->(controller) { controller.send(:current_user)&.admin? }
      get "/admin/ledger/connect"
      assert response.location.to_s.start_with?("https://auth.ledger.example/"), "an admin passes"
    end
  ensure
    Studio.connection_admin_guard = saved
  end

  test "the guard is the host's to name: a callable taking the controller" do
    saved = Studio.connection_admin_guard
    Studio.connection_admin_guard = ->(controller) { controller.head(:forbidden) }
    with_env do
      sign_in
      get "/admin/ledger/connect"
      assert_response :forbidden
    end
  ensure
    Studio.connection_admin_guard = saved
  end

  # --- a rotating code grant, account named on the callback ------------------------

  test "connect, callback, store: the code is exchanged once and the account described" do
    with_env do
      sign_in
      get "/admin/ledger/connect", params: { return_to: "/integrations" }
      assert_response :redirect
      assert response.location.start_with?("https://auth.ledger.example/oauth2?")
      state = started_state
      requests = stub_http(ledger, grant(access_token: "a1", refresh_token: "r1", x_refresh_token_expires_in: 8_726_400))

      get "/admin/ledger/callback", params: { state:, code: "c0de", account_id: "4620" }

      assert_redirected_to "/integrations"
      assert_equal "Ledger connected: Ledger Co 4620.", flash[:notice]
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "http://www.example.com/admin/ledger/callback", requests.sole[:form][:redirect_uri]
      connection = Studio::Connection.for_provider(:ledger).sole
      assert_equal %w[4620 r1 the-admin], [connection.account_id, connection.refresh_token, connection.connected_by]
      assert_equal({ "environment" => "sandbox" }, connection.metadata)
      assert_equal [{ provider: "ledger", account: "4620", access_token: "a1" }], ConnectionsHost::DESCRIBED
      assert_not_includes flash[:notice], "r1"
    end
  end

  test "a callback whose state does not match is refused before anything is asked, and a state works once" do
    with_env do
      sign_in
      get "/admin/ledger/connect"
      state = started_state
      requests = stub_http(ledger, grant(access_token: "a1", refresh_token: "r1"))

      get "/admin/ledger/callback", params: { state: "forged", code: "c0de", account_id: "4620" }
      assert_response :bad_request
      get "/admin/ledger/callback", params: { state:, code: "c0de", account_id: "4620" }
      assert_response :bad_request, "the forged try spent the stored state"
      assert_empty requests
      assert_equal 0, Studio::Connection.count
    end
  end

  test "a declined sign-in, and any other refusal, connect nothing" do
    with_env do
      sign_in
      get "/admin/ledger/connect"
      get "/admin/ledger/callback", params: { state: started_state, error: "access_denied" }
      assert_equal "The sign-in was declined on Ledger. Nothing was connected.", flash[:alert]

      get "/admin/ledger/connect"
      get "/admin/ledger/callback", params: { state: started_state, error: "invalid_scope" }
      assert_equal "Ledger refused the sign-in (invalid_scope). Check the app's redirect URI, then start again.", flash[:alert]
      assert_equal 0, Studio::Connection.count
    end
  end

  test "a callback naming no valid account connects nothing and spends no code" do
    with_env do
      sign_in
      requests = stub_http(ledger)
      [nil, "12ab", "1 OR 1=1"].each do |account_id|
        get "/admin/ledger/connect"
        get "/admin/ledger/callback", params: { state: started_state, code: "c0de", account_id: }.compact
        assert_redirected_to "/admin/ledger"
        assert_includes flash[:alert], "without naming a valid account"
      end
      assert_empty requests
      assert_equal 0, Studio::Connection.count
    end
  end

  test "a refused exchange is said on the page and kept in the error log" do
    with_env do
      sign_in
      get "/admin/ledger/connect"
      stub_http(ledger, [400, { error: "invalid_grant" }.to_json])
      get "/admin/ledger/callback", params: { state: started_state, code: "spent", account_id: "4620" }

      assert_includes flash[:alert], "Ledger refused to exchange the sign-in code"
      assert_equal 1, ErrorLog.count
      assert_equal 0, Studio::Connection.count
    end
  end

  test "return_to is honoured only when it is exactly one of the route's paths" do
    with_env do
      sign_in
      ["https://evil.example/", "//evil.example", "/integrations/../x"].each do |target|
        get "/admin/ledger/connect", params: { return_to: target }
        get "/admin/ledger/callback", params: { state: started_state, error: "access_denied" }
        assert_redirected_to "/admin/ledger"
      end
    end
  end

  test "off until the host sets the credentials: Connect names the env vars and leaves the site" do
    with_env(ENV_VALUES.merge("LEDGER_CLIENT_ID" => nil)) do
      sign_in
      get "/admin/ledger/connect"

      assert_redirected_to "/admin/ledger"
      assert_equal "Ledger connections are not set up on this server: LEDGER_CLIENT_ID and LEDGER_CLIENT_SECRET are not set.", flash[:alert]
    end
  end

  test "without encryption keys Connect refuses before it asks the provider anything" do
    config = ActiveRecord::Encryption.config
    saved = config.key_derivation_salt
    with_env do
      sign_in
      config.key_derivation_salt = nil
      get "/admin/ledger/connect"

      assert_redirected_to "/admin/ledger"
      assert_includes flash[:alert], "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"
      assert_includes flash[:alert], "Nothing was asked of Ledger."
    end
  ensure
    config.key_derivation_salt = saved
  end

  # --- a cached code grant on a per-account host, account named before Connect ------

  test "the host's own controller serves the page and the flow; the account comes from the session, never the callback" do
    with_env do
      sign_in
      get "/admin/drive"
      assert_equal "drive page: ", response.body

      post "/admin/drive/connect", params: { drive_domain: "https://ACME.drive.example/" }
      assert_equal "acme.drive.example", URI(response.location).host
      requests = stub_http(drive, grant(access_token: "a1", refresh_token: "r1", expires_in: 2_592_000))
      get "/admin/drive/callback", params: { state: started_state, code: "c0de", drive_domain: "evil" }

      assert_redirected_to "/admin/drive"
      assert_equal "https://acme.drive.example/oauth/token", requests.sole[:url]
      connection = Studio::Connection.for_provider(:drive).sole
      assert_equal %w[acme a1 r1 acme.drive.example], [connection.account_id, connection.access_token, connection.refresh_token, connection.label]
      assert connection.access_fresh?
      get "/admin/drive"
      assert_equal "drive page: acme.drive.example", response.body
    end
  end

  test "a provider that takes the account at Connect is POST-only: a GET link cannot start a connection" do
    with_env do
      sign_in
      assert_raises(ActionController::RoutingError) { get "/admin/drive/connect", params: { drive_domain: "attacker" } }
      get "/admin/drive/connect_by_hand", params: { drive_domain: "attacker" }
      assert_response :method_not_allowed
      assert_nil session["studio_connection_drive_state"], "no state was started"

      get "/admin/ledger/connect" # no account input: GET stays allowed
      assert response.location.to_s.start_with?("https://auth.ledger.example/")
    end
  end

  test "a domain that is not one is refused at Connect and never reaches a URL" do
    with_env do
      sign_in
      post "/admin/drive/connect", params: { drive_domain: "evil.example/x" }

      assert_redirected_to "/admin/drive"
      assert_includes flash[:alert], "That is not a Drive account"
    end
  end

  test "a callback with no account kept from Connect is refused as a state mismatch" do
    with_env do
      sign_in
      get "/admin/ledger/connect" # a state for another provider
      get "/admin/drive/callback", params: { state: started_state, code: "c0de" }

      assert_response :bad_request
    end
  end

  # --- a client-credentials grant behind an admin consent -------------------------

  test "an admin consent stores the tenant encrypted and asks for no token at callback" do
    with_env(ENV_VALUES.transform_values { nil }) do
      Studio::Connections::StandIn.install!(tenant, callback_params: { tenant: ConnectionsHost::TENANT.upcase, admin_consent: "True" })
      sign_in
      get "/admin/tenant/connect"
      follow_redirect!

      assert_redirected_to "/admin/tenant"
      assert_equal "Tenant Suite connected: Tenant Suite.", flash[:notice]
      connection = Studio::Connection.for_provider(:tenant).sole
      assert_equal ConnectionsHost::TENANT, connection.account_id
      assert_nil connection.refresh_token
      assert_empty tenant.http.requests, "the consent itself spends no token request"
      assert_equal "[FILTERED]", request.filtered_parameters["tenant"]
      assert_not_includes request.filtered_path, ConnectionsHost::TENANT.upcase
    end
  end

  test "a consent the provider did not report, or a tenant that is not one, connects nothing" do
    with_env do
      sign_in
      get "/admin/tenant/connect"
      get "/admin/tenant/callback", params: { state: started_state, tenant: ConnectionsHost::TENANT }
      assert_equal "Tenant Suite did not report an approval. Nothing was connected.", flash[:alert]

      get "/admin/tenant/connect"
      get "/admin/tenant/callback", params: { state: started_state, tenant: "not-a-guid", admin_consent: "True" }
      assert_includes flash[:alert], "without naming a valid account"

      get "/admin/tenant/connect"
      get "/admin/tenant/callback", params: { state: started_state, error: "consent_required" }
      assert_equal "The sign-in was declined on Tenant Suite. Nothing was connected.", flash[:alert]
      assert_equal 0, Studio::Connection.count
    end
  end

  # --- disconnect -------------------------------------------------------------------

  test "disconnect revokes at the provider, then deletes the row" do
    with_env do
      sign_in
      row = store(:ledger, account: "4620", refresh_token: "r1")
      requests = stub_http(ledger, [200, ""])
      delete "/admin/ledger/connections/#{row.id}", params: { return_to: "/integrations" }

      assert_redirected_to "/integrations"
      assert_response :see_other
      assert_includes flash[:notice], "Ledger revoked the grant"
      assert_equal "https://auth.ledger.example/oauth2/revoke", requests.sole[:url]
      assert_not Studio::Connection.exists?(row.id)
    end
  end

  test "a refused revoke still deletes the row, logs the refusal and says so" do
    with_env do
      sign_in
      row = store(:ledger, account: "4620", refresh_token: "r1")
      stub_http(ledger, [500, ""])
      delete "/admin/ledger/connections/#{row.id}"

      assert_includes flash[:notice], "did not confirm the revoke"
      assert_equal 1, ErrorLog.count
      assert_not Studio::Connection.exists?(row.id)
    end
  end

  test "a provider with no revoke endpoint deletes the row, forgets its token and names where to revoke" do
    with_env do
      sign_in
      row = store(:tenant, account: ConnectionsHost::TENANT)
      stub_http(tenant, grant(access_token: "g1", expires_in: 3599))
      row.fresh_access_token
      assert_equal 1, tenant.cached_count

      delete "/admin/tenant/connections/#{row.id}"
      assert_includes flash[:notice], "Remove the app in the tenant's admin center"
      assert_equal 0, tenant.cached_count
      assert_not Studio::Connection.exists?(row.id)
    end
  end

  test "disconnect finds only its own provider's rows" do
    with_env do
      sign_in
      other = store(:drive, account: "acme", access_token: "a1", refresh_token: "r1")
      delete "/admin/ledger/connections/#{other.id}"

      assert_equal "That Ledger account was not connected, so nothing changed.", flash[:notice]
      assert Studio::Connection.exists?(other.id)
    end
  end

  # --- the logs ----------------------------------------------------------------------

  test "a real callback's parameters and URL keep the code and the account out of the log" do
    with_env do
      sign_in
      get "/admin/ledger/connect"
      stub_http(ledger, grant(access_token: "a1", refresh_token: "r1"))
      get "/admin/ledger/callback", params: { state: started_state, code: "c0de-secret", account_id: "4620" }

      assert_equal "[FILTERED]", request.filtered_parameters["code"]
      assert_equal "[FILTERED]", request.filtered_parameters["account_id"]
      assert_not_includes request.filtered_path, "4620"
    end
  end
end
