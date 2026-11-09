# frozen_string_literal: true

require "bundler/setup"
require_relative "../support/integrations_host"

# [integration] The mounted admin integrations page over HTTP, in a host that
# enabled all three engine integrations (test/support/integrations_host.rb):
# the fixed addresses, the admin guard on every action, the list with each
# status, Connect as a POST (with the account typed for Egnyte), the callback,
# Disconnect, the stand-ins, and the host's panel on an integration's page.
class IntegrationsPageTest < ActionDispatch::IntegrationTest
  include IntegrationsHost

  setup do
    IntegrationsHost.enable!
    Studio::Connection.delete_all
    ErrorLog.delete_all
    User.delete_all
    Studio.connection(:microsoft_365).forget!
    @admin = User.create!(email: "admin@app.example", slug: "the-admin", role: "admin")
  end

  def sign_in(user = @admin)
    post "/integrations_test_sign_in/#{user.id}"
    assert_response :ok
  end

  def qbo = Studio.integration(:quickbooks)
  def egnyte = Studio.integration(:egnyte)
  def m365 = Studio.integration(:microsoft_365)
  def location_query = Rack::Utils.parse_query(URI(response.location).query)

  def card(key) = css_select("[data-studio-integration-card='#{key}']").first

  # --- the addresses ----------------------------------------------------------

  test "the default mount puts each integration and its callback at the fixed addresses" do
    routes = Rails.application.routes
    assert_equal "/admin/integrations", routes.url_helpers.admin_integrations_path
    { "quickbooks" => "quickbooks", "egnyte" => "egnyte", "microsoft_365" => "microsoft_365" }.each do |key, segment|
      assert_equal "/admin/integrations/#{segment}", routes.url_helpers.public_send(:"admin_integrations_#{key}_path")
      assert_equal "/admin/integrations/#{segment}/callback", routes.url_helpers.public_send(:"admin_integrations_#{key}_callback_path")
      assert_equal({ controller: "studio/integrations", action: "callback", studio_connection: key },
                   routes.recognize_path("/admin/integrations/#{segment}/callback"))
      assert_equal({ controller: "studio/integrations", action: "show", studio_connection: key },
                   routes.recognize_path("/admin/integrations/#{segment}"))
    end
    assert_equal({ controller: "studio/integrations", action: "index" }, routes.recognize_path("/admin/integrations"))
  end

  test "the page shows the exact redirect URI to register" do
    sign_in
    get "/admin/integrations/quickbooks"
    assert_response :ok
    assert_select "[data-studio-integration-redirect] code", text: "http://www.example.com/admin/integrations/quickbooks/callback"
  end

  # --- who may ----------------------------------------------------------------

  test "only the host's admin guard opens the list and the pages" do
    sign_in(User.create!(email: "member@app.example", role: "member"))
    %w[/admin/integrations /admin/integrations/quickbooks /admin/integrations/egnyte].each do |path|
      get path
      assert_redirected_to "/", path
    end
  end

  test "a callable guard that answers false or nil refuses the list and a page with 403" do
    saved = Studio.connection_admin_guard
    sign_in
    [false, nil].each do |answer|
      Studio.connection_admin_guard = ->(_controller) { answer }
      get "/admin/integrations"
      assert_response :forbidden
      get "/admin/integrations/egnyte"
      assert_response :forbidden
      post "/admin/integrations/egnyte/connect", params: { egnyte_domain: "acme" }
      assert_response :forbidden
    end
    Studio.connection_admin_guard = ->(controller) { controller.send(:current_user)&.admin? }
    get "/admin/integrations"
    assert_response :ok
  ensure
    Studio.connection_admin_guard = saved
  end

  # --- the list -----------------------------------------------------------------

  test "the list shows every enabled integration with its status" do
    sign_in
    get "/admin/integrations"
    assert_response :ok
    assert_equal %w[quickbooks egnyte microsoft_365], css_select("[data-studio-integration-card]").map { _1["data-studio-integration-card"] }
    assert_equal "not_set_up", card("quickbooks")["data-status"]
    assert_select "[data-studio-integration-card='quickbooks'] [data-studio-integration-missing]", text: "HOST_QBO_ID and HOST_QBO_SECRET are not set."

    with_env do
      Studio::Connection.store!(:egnyte, { "access_token" => "a1" }, account: "acme", by: "tester", label: "acme.egnyte.com")
      get "/admin/integrations"
      assert_equal "ready", card("quickbooks")["data-status"]
      assert_equal "connected", card("egnyte")["data-status"]
      assert_select "[data-studio-integration-card='egnyte'] [data-studio-integration-status]", text: "Connected"
      assert_select "[data-studio-integration-card='egnyte'] [data-studio-integration-connection]", text: /acme\.egnyte\.com/
    end
    assert_select "[data-studio-integration-card] a[href='/admin/integrations/quickbooks']"
  end

  test "Connect is a POST form; only Egnyte asks for an account" do
    sign_in
    get "/admin/integrations"
    assert_select "form[data-studio-integration-connect='egnyte'][method='post'][action='/admin/integrations/egnyte/connect'] input[name='egnyte_domain'][required]"
    assert_select "form[data-studio-integration-connect='quickbooks'][method='post'] input[name='egnyte_domain']", count: 0
    assert_select "form[data-studio-integration-connect='quickbooks'] input[name='return_to'][value='/admin/integrations']"
  end

  # --- Egnyte: the account typed at Connect ---------------------------------

  test "egnyte: a GET connect has no route; a POST with the domain goes to the domain's own sign-in" do
    with_env do
      sign_in
      assert_raises(ActionController::RoutingError) { get "/admin/integrations/egnyte/connect", params: { egnyte_domain: "attacker" } }

      post "/admin/integrations/egnyte/connect", params: { egnyte_domain: "https://Acme.Egnyte.com/", return_to: "/admin/integrations/egnyte" }
      assert response.location.start_with?("https://acme.egnyte.com/puboauth/token?"), response.location
      assert_equal "http://www.example.com/admin/integrations/egnyte/callback", location_query["redirect_uri"]
    end
  end

  test "egnyte: a domain that is not a DNS label never leaves the site" do
    with_env do
      sign_in
      post "/admin/integrations/egnyte/connect", params: { egnyte_domain: "acme.evil.example" }
      assert_redirected_to "/admin/integrations/egnyte"
      assert_includes flash[:alert], "That is not a valid Egnyte account"
    end
  end

  test "egnyte: the callback exchanges the code, asks who signed in once, and stores the domain" do
    with_env do
      sign_in
      post "/admin/integrations/egnyte/connect", params: { egnyte_domain: "Acme", return_to: "/admin/integrations" }
      state = location_query.fetch("state")
      tokens = stub_tokens(egnyte, answer(access_token: "a1", refresh_token: "r1", expires_in: 2_592_000))
      described = stub_describe(egnyte, answer(username: "jdoe"))

      get "/admin/integrations/egnyte/callback", params: { state:, code: "c1", egnyte_domain: "attacker" }
      assert_redirected_to "/admin/integrations"
      assert_equal "Egnyte connected: acme.egnyte.com.", flash[:notice]
      assert_equal ["https://acme.egnyte.com/puboauth/token"], tokens.map { _1[:url] }
      assert_equal ["https://acme.egnyte.com/pubapi/v1/whoami"], described.map { _1[:url] }
      row = Studio::Connection.for_provider(:egnyte).sole
      assert_equal "acme", row.account_id
      assert_equal({ "username" => "jdoe" }, row.metadata)
    end
  end

  # --- QuickBooks: the company named on the callback ------------------------

  test "quickbooks: connect, call back with the realmId, then disconnect with a revoke" do
    with_env do
      sign_in
      post "/admin/integrations/quickbooks/connect", params: { return_to: "/admin/integrations/quickbooks" }
      assert response.location.start_with?("https://appcenter.intuit.com/connect/oauth2?")
      assert_equal "http://www.example.com/admin/integrations/quickbooks/callback", location_query["redirect_uri"]
      state = location_query.fetch("state")

      stub_tokens(qbo, answer(access_token: "a1", refresh_token: "r1", expires_in: 3600, x_refresh_token_expires_in: 8_726_400))
      stub_describe(qbo, answer(CompanyInfo: { CompanyName: "Acme Books" }))
      get "/admin/integrations/quickbooks/callback", params: { state:, code: "c1", realmId: "4620816365" }
      assert_redirected_to "/admin/integrations/quickbooks"
      assert_equal "QuickBooks connected: Acme Books.", flash[:notice]
      row = Studio::Connection.for_provider(:quickbooks).sole
      assert_equal "4620816365", row.account_id
      assert_equal({ "environment" => "sandbox" }, row.metadata)

      get "/admin/integrations/quickbooks"
      assert_select "[data-studio-integration-connection='#{row.id}']", text: /Acme Books/
      assert_select "[data-studio-integration-connection='#{row.id}']", text: /sandbox/
      assert_select "form[action='/admin/integrations/quickbooks/connections/#{row.id}'] input[name='_method'][value='delete']"

      revokes = stub_tokens(qbo, [200, ""])
      delete "/admin/integrations/quickbooks/connections/#{row.id}", params: { return_to: "/admin/integrations/quickbooks" }
      assert_redirected_to "/admin/integrations/quickbooks"
      assert_match(/QuickBooks revoked the grant/, flash[:notice])
      assert_equal ["https://developer.api.intuit.com/v2/oauth2/tokens/revoke"], revokes.map { _1[:url] }
      refute Studio::Connection.exists?(row.id)
    end
  end

  test "quickbooks: a callback without a valid realmId stores nothing" do
    with_env do
      sign_in
      post "/admin/integrations/quickbooks/connect"
      get "/admin/integrations/quickbooks/callback", params: { state: location_query.fetch("state"), code: "c1", realmId: "12ab" }
      assert_redirected_to "/admin/integrations/quickbooks"
      assert_match(/without naming a valid account/, flash[:alert])
      assert_equal 0, Studio::Connection.count
    end
  end

  test "a return_to outside the integration's allowlist comes back to its page" do
    with_env do
      sign_in
      post "/admin/integrations/quickbooks/connect", params: { return_to: "https://evil.example/" }
      get "/admin/integrations/quickbooks/callback", params: { state: location_query.fetch("state"), error: "access_denied" }
      assert_redirected_to "/admin/integrations/quickbooks"
    end
  end

  # --- Microsoft 365 through the stand-in -----------------------------------

  test "microsoft_365: the stand-in walks the admin consent end to end, with no client set and nothing reached" do
    m365.install_stand_in!
    sign_in
    get "/admin/integrations"
    assert_equal "ready", card("microsoft_365")["data-status"], "a stand-in makes it connectable"

    post "/admin/integrations/microsoft_365/connect", params: { return_to: "/admin/integrations" }
    assert response.location.start_with?("http://www.example.com/admin/integrations/microsoft_365/callback?"), response.location
    get response.location
    assert_redirected_to "/admin/integrations"
    assert_equal "Microsoft 365 connected: Stand-in Tenant.", flash[:notice]
    row = Studio::Connection.for_provider(:microsoft_365).sole
    assert_equal "00000000-0000-0000-0000-000000000365", row.account_id

    delete "/admin/integrations/microsoft_365/connections/#{row.id}"
    assert_match(/Entra admin center/, flash[:notice])
    refute Studio::Connection.exists?(row.id)
    assert_equal 0, Studio.connection(:microsoft_365).cached_count, "disconnect forgets the in-memory token"
  ensure
    m365.uninstall_stand_in!
  end

  test "microsoft_365: a callback without an approval stores nothing" do
    m365.install_stand_in!
    sign_in
    post "/admin/integrations/microsoft_365/connect"
    state = location_query.fetch("state")
    get "/admin/integrations/microsoft_365/callback", params: { state:, tenant: IntegrationsHost::TENANT, admin_consent: "False" }
    assert_match(/did not report an approval/, flash[:alert])
    assert_equal 0, Studio::Connection.count
  ensure
    m365.uninstall_stand_in!
  end

  # --- the host's panel ---------------------------------------------------------

  test "the host's panel renders on its integration's page with the connections, and only there" do
    with_env do
      sign_in
      Studio::Connection.store!(:quickbooks, { "refresh_token" => "r1" }, account: "4620", by: "tester")
      get "/admin/integrations/quickbooks"
      assert_select "[data-studio-integration-panel] [data-host-panel='quickbooks']", text: "host panel for QuickBooks: 1 connected"

      get "/admin/integrations/egnyte"
      assert_response :ok
      assert_select "[data-studio-integration-panel]", count: 0
      get "/admin/integrations"
      assert_select "[data-host-panel]", count: 0
    end
  end

  test "no token, or part of one, reaches the page" do
    with_env do
      sign_in
      Studio::Connection.store!(:egnyte, { "access_token" => "secret-access-abc", "refresh_token" => "secret-refresh-xyz" },
                                account: "acme", by: "tester")
      get "/admin/integrations/egnyte"
      refute_includes response.body, "secret-access"
      refute_includes response.body, "secret-refresh"
    end
  end
end
