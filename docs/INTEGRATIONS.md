# Integrations

The engine's registry of integration connection definitions. It is built on the
connection tooling ([`CONNECTIONS.md`](CONNECTIONS.md)). The engine ships one
definition for each integration it knows. A host turns one on with one line, and
mounts one admin page that lists, connects and disconnects them.

A definition holds the **connection only**: the URLs, the scopes, the token
behaviour, and a minimal describe that names the account just connected (the
company, the user or the organization). It holds no reader and makes no
business-data call. A host writes its own readers, and shows what they read in a
panel on the integration's page.

| Key | Integration | Grant | Tokens | Account |
|-----|-------------|-------|--------|---------|
| `:quickbooks` | QuickBooks Online (Intuit) | code | `:rotating`, HTTP Basic client auth, JSON revoke | the company, named on the callback (`realmId`) |
| `:egnyte` | Egnyte | code | `:cached`, refreshed within 1 day of expiry, secret-only revoke | the domain, typed at Connect |
| `:microsoft_365` | Microsoft 365 (Microsoft Graph, app-only) | client credentials after admin consent | `:memory`, no revoke endpoint | the tenant, named on the callback (private) |

## Enable an integration

Install the connection table first (`bin/rails g studio:connections`, then
`bin/rails db:migrate`; see [`CONNECTIONS.md`](CONNECTIONS.md#install)). Do not
also declare the same key with `Studio.define_connection`.

In an initializer, for example `config/initializers/studio_integrations.rb`:

```ruby
Studio.enable_integration :quickbooks,
  env: { client_id: "INTUIT_CLIENT_ID", client_secret: "INTUIT_CLIENT_SECRET",
         environment: "INTUIT_ENVIRONMENT" },
  panel: "admin/integrations/quickbooks_panel"

Studio.enable_integration :egnyte,
  env: { client_id: "EGNYTE_CLIENT_ID", client_secret: "EGNYTE_CLIENT_SECRET" }

Studio.enable_integration :microsoft_365,
  env: { client_id: "MSGRAPH_CLIENT_ID", client_secret: "MSGRAPH_CLIENT_SECRET" }
```

| Option | Meaning |
|--------|---------|
| `env:` | Required. The host's env var **names**, never values. `client_id:` and `client_secret:` always. QuickBooks also takes `environment:` (see below). An unknown key fails the boot. |
| `panel:` | A host partial for the integration's page (see Host panel). |
| `label:` | Replaces the integration's name on the page and in every message. |
| `scopes:` | Replaces the definition's scopes, for example to add `openid` to QuickBooks. |

An enabled integration stays off until both its client id and its secret are set.
Its page says "Not set up" and names the missing variables. Connect then says which
variables are missing and does not leave the site.

`Studio.integration(:quickbooks)` is the enabled integration.
`Studio.integration(:quickbooks).provider`, also `Studio.connection(:quickbooks)`,
is its connection provider. `Studio.integrations` lists the enabled ones in order.

## Mount the page

In `config/routes.rb`, after the initializers have enabled the integrations:

```ruby
Studio.draw_integrations_routes(self)
```

| Route | Name | What |
|-------|------|------|
| `GET /admin/integrations` | `admin_integrations` | The list: each integration, its status, Connect |
| `GET /admin/integrations/<key>` | `admin_integrations_<key>` | One integration: its connections, Disconnect, the redirect URI, the host panel |
| `POST /admin/integrations/<key>/connect` | `admin_integrations_<key>_connect` | Connect. POST only for Egnyte (the domain is typed); also `GET` for the others |
| `GET /admin/integrations/<key>/callback` | `admin_integrations_<key>_callback` | The OAuth callback. Register this URL at the provider |
| `DELETE /admin/integrations/<key>/connections/:id` | `admin_integrations_<key>_disconnect` | Disconnect |

So with the default mount the redirect URIs to register are:

| Integration | Redirect URI |
|-------------|--------------|
| QuickBooks | `https://<host>/admin/integrations/quickbooks/callback` |
| Egnyte | `https://<host>/admin/integrations/egnyte/callback` |
| Microsoft 365 | `https://<host>/admin/integrations/microsoft_365/callback` |

Each integration's page also shows its exact redirect URI.

`path:` moves the whole page (`Studio.draw_integrations_routes(self, path: "ops/integrations")`).
Moving it changes every redirect URI. `as:` changes the route-name prefix.
`controller:` names a host controller that includes `Studio::ConnectionFlow` and
adds `index` and `show`. The default is the engine's `Studio::IntegrationsController`.

### Who may

The host's admin guard, `Studio.connection_admin_guard`, runs before every action:
the list, each page, Connect, the callback and Disconnect. See
[`CONNECTIONS.md`](CONNECTIONS.md#who-may). A callable guard that answers `false`
or `nil` refuses with a 403.

### Status

| Status | When |
|--------|------|
| Not set up | The client id or secret is not set (and no stand-in is installed), or the app's encryption keys are not set. The page says which. |
| Ready to connect | It can connect, and no readable connection is stored. |
| Connected | At least one readable connection is stored. |

## Host panel

A panel is the host's own partial, rendered on the integration's page below its
connections. Use it for a live read through the host's own reader. It gets two
locals: `integration:` (the enabled integration) and `connections:` (its readable
`Studio::Connection` rows, newest first).

```erb
<%# app/views/admin/integrations/_quickbooks_panel.html.erb %>
<%# locals: (integration:, connections:) %>
<% connections.each do |connection| %>
  <%= render "admin/integrations/quickbooks_read", read: Books::Reader.new(connection).company_info %>
<% end %>
```

A host reader gets its token and its base URL from the integration:

```ruby
token = connection.fresh_access_token                                  # QuickBooks, Egnyte
token = Studio.connection(:microsoft_365).access_token(connection)     # Microsoft 365
base  = Studio.integration(:quickbooks).api_base(connection)
```

| Integration | `api_base(connection)` |
|-------------|------------------------|
| QuickBooks | `https://quickbooks.api.intuit.com/v3/company/<realmId>`, or the sandbox host when the connection's `metadata["environment"]` is `sandbox` |
| Egnyte | `https://<domain>.egnyte.com/pubapi/v1` |
| Microsoft 365 | `https://graph.microsoft.com/v1.0` |

The reader handles `Studio::Connections::Revoked` (connect again) and `RateLimited`.
QuickBooks asks for `minorversion=75` or later on every call
(`Studio::Integrations::Quickbooks::MINOR_VERSION`).

## Each definition

### QuickBooks

- Sign-in at `appcenter.intuit.com/connect/oauth2` with the scope
  `com.intuit.quickbooks.accounting`.
- Token and revoke calls use HTTP Basic client auth. The revoke body is JSON.
- Refresh tokens rotate. Every token read refreshes under the row's lock, and the
  answered refresh token is stored before the access token is used. A refresh
  that answers no refresh token refuses. `x_refresh_token_expires_in` sets
  `refresh_expires_at`.
- `realmId` names the company on the callback. It is a number, and it is kept out
  of the logs by its exact key.
- `environment:` names the env var that says which Intuit keys these are. Only
  `production` (any case) selects production. Anything else, or no variable, is the
  sandbox, so a typo never points sandbox keys at live books. The value is stored
  in each new connection's `metadata["environment"]`.
- Describe: one `GET .../v3/company/<realmId>/companyinfo/<realmId>`, for the
  company name.

### Egnyte

- The admin types the domain at Connect, on a CSRF-checked POST. It is
  lower-cased and stripped of a scheme, a path and `.egnyte.com`, so `Acme`,
  `acme.egnyte.com` and `https://acme.egnyte.com/` are all `acme`. It must then be
  one DNS label, or it never reaches a URL.
- Sign-in and token endpoint: `https://<domain>.egnyte.com/puboauth/token`, with
  the scope `Egnyte.filesystem` on both.
- The access token is cached. It is refreshed only within one day of its expiry,
  or after a 401 (`fresh_access_token(stale: token)`).
- The revoke sends the token and the client secret, not the client id.
- A 409 or a 429 raises `RateLimited`. "Invalid refresh token" raises `Revoked`.
- Describe: one `GET /pubapi/v1/whoami`. The label is `<domain>.egnyte.com`, and
  the username goes in `metadata["username"]`.

### Microsoft 365

- A tenant administrator approves the app at
  `login.microsoftonline.com/common/adminconsent`. The callback must carry
  `admin_consent=True`, or nothing is connected.
- The tenant GUID is lower-cased, so one tenant never makes two rows. It is
  private: it is stored only encrypted, the row is keyed by a digest, and the
  callback's `tenant` param is kept out of the logs by its exact key.
- Tokens: the client-credentials grant on the tenant's own token endpoint, with
  the scope `https://graph.microsoft.com/.default`. No refresh token exists. The
  access token is cached in this process's memory per tenant.
- The application permissions are set on the app registration, not here. Admin
  consent grants what the registration lists.
- `unauthorized_client` raises `Revoked`: the app is not found in, or not enabled
  for, the tenant.
- There is no revoke endpoint. Disconnect deletes the row and forgets the token,
  and tells the admin to remove the app in the tenant's Entra admin center.
- Describe: one `GET /v1.0/organization/<tenant>`, for the organization's name.

If a describe call fails, the connection is still stored. It takes the default
label, and it keeps its metadata (QuickBooks's environment).

## Tests, the e2e lane and a local demo

`Studio.integration(:quickbooks).install_stand_in!` stands in the sign-in page,
the token and revoke endpoints
([`Studio::Connections::StandIn`](CONNECTIONS.md#tests-the-e2e-lane-and-a-local-demo))
and the describe call. A connect then walks end to end with no client registered
and no request sent to the provider. QuickBooks comes back with a test `realmId`,
and Microsoft 365 with a test tenant and an approval. `uninstall_stand_in!` removes
it. Both are refused outside the development and test environments.

```ruby
# config/initializers/studio_integrations.rb, after the enable lines
if (Rails.env.development? && ENV["INTEGRATIONS_STAND_IN"] == "1") || (Rails.env.test? && ENV["E2E_STAND_INS"] == "1")
  Studio.integrations.each(&:install_stand_in!)
end
```

`integration.api_http = ->(url, headers) { [status, body] }` stands in the describe
call alone, for a unit test.

The engine's own proof is `test/integration/integrations_definitions_test.rb`
(each definition, with stubbed HTTP) and `test/integration/integrations_page_test.rb`
(the page in the dummy app), on `test/support/integrations_host.rb`.

## Sources

Each definition was checked against the hub's working OAuth clients and readers
(`mcritchie-studio`: `app/services/{quickbooks,egnyte,msgraph}/oauth_client.rb`
and their readers and tests). Those clients cite the vendors' own documents:
Intuit's OpenID discovery document, Egnyte's authentication docs, and Microsoft's
identity-platform client-credentials flow.
