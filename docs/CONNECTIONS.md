# Connections

Generic tooling to connect a third-party account to a host app over OAuth 2.0.
The engine knows no provider. A host declares each provider it connects, and the
engine gives it the table, the OAuth plumbing, the admin actions, the routes and
the log filter. Provider details (endpoints, scopes, quirks, readers and the admin
page's live read) stay in the host.

| Part | What it is |
|------|------------|
| `Studio::Connection` | One table, `studio_connections`. One row per provider and account. Tokens are encrypted. |
| `Studio.define_connection` | Declares a provider (`Studio::Connections::Provider`). |
| `Studio::ConnectionFlow` | The `connect`, `callback` and `disconnect` actions. `Studio::ConnectionsController` includes it. |
| `Studio.draw_connection_routes` | Draws one provider's routes. |
| `Studio::Connections::LOG_FILTER` | Keeps the keys a provider names out of the logs. The engine installs it. |
| `Studio::Connections::StandIn` | A stand-in provider for the e2e lane and a local demo. |

## Install

```sh
bin/rails g studio:connections   # the migration and a commented initializer
bin/rails db:migrate
```

`bin/rails studio_engine:install:migrations` copies the same migration. The
generator copies only this one migration.

The app must have Active Record encryption keys (`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`,
`ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`).
Without them, Connect refuses before it asks the provider for anything. If the keys
are lost or changed, a stored row becomes unreadable (`readable?` is false). It then
counts as not connected, and connecting again replaces it.

The host's `ApplicationController` must include `Studio::ErrorHandling`. The flow uses
its `rescue_and_log`, `current_user` and (by default) `require_admin`.

## Declare a provider

In an initializer, for example `config/initializers/studio_connections.rb`:

```ruby
Studio.define_connection :files,
  label: "Example Files",
  env: { client_id: "EXAMPLE_FILES_CLIENT_ID", client_secret: "EXAMPLE_FILES_CLIENT_SECRET" },
  authorize_url: ->(account) { "https://#{account}.files.example/oauth/authorize" },
  token_url: ->(account) { "https://#{account}.files.example/oauth/token" },
  revoke_url: ->(account) { "https://#{account}.files.example/oauth/revoke" },
  scopes: %w[files.read],
  refresh: :cached, refresh_margin: 1.day,
  account: :connect, account_param: "files_domain", account_format: /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/,
  describe: ->(grant:, account:, provider:) { { label: "#{account}.files.example" } }
```

A provider stays off until both of its env names are set. Its routes are drawn,
but Connect says which variables are missing and does not leave the site.
`configured?` says whether the client is set. `connectable?` is also true when a
stand-in is installed.

### Options

| Option | Default | Meaning |
|--------|---------|---------|
| `label:` | required | The name on every message. |
| `env:` | required | `{ client_id: "NAME", client_secret: "NAME" }`: the env var names, never values. |
| `authorize_url:`, `token_url:` | required | A String, or a callable that takes the checked account (a per-account host). |
| `revoke_url:` | `nil` | As above. `nil` means the provider has no revoke endpoint. Disconnect then deletes the row and shows `revoke_note:`. |
| `grant:` | `:authorization_code` | Or `:client_credentials`, for an app-only grant behind an admin consent. |
| `refresh:` | `:rotating` (`:memory` for client credentials) | The refresh policy (see below). |
| `refresh_margin:` | `5.minutes` | `:cached`: refresh this long before expiry. `:memory`: drop the token this long before expiry. |
| `scopes:` | `[]` | Space-joined on the authorize URL (code grant) and on the client-credentials request. |
| `client_auth:` | `:form` | `:form` puts the id and secret in the form. `:basic` uses an HTTP Basic header. |
| `revoke_auth:` | `client_auth` | Also `:secret_only` (the secret in the form, without the id). |
| `revoke_format:` | `:form` | Or `:json`. The body is `{ token: <refresh token, else access token> }`. Any 2xx answer confirms the revoke. |
| `account:` | `:callback` | Where the account comes from (see below). |
| `account_param:` | | The form param (`:connect`) or callback query param (`:callback`) that names the account. |
| `account_format:` | | A Regexp. The normalized account must match it. Required for `:connect` and `:callback`. |
| `normalize_account:` | strip | A callable that turns what was typed or sent into the account. A provider whose ids are case-insensitive (a tenant GUID, a domain) should pass one that lowercases, so one account never makes two rows. |
| `private_account:` | `false` | The account is stored only encrypted. The row is unique by a keyed digest of it (HMAC of `secret_key_base`). Its callback param is log-filtered even if `filter_keys:` omits it. If `secret_key_base` is rotated, a reconnect makes a second row; delete the old one. |
| `authorize_params:`, `exchange_params:` | `{}` | Extra params on the authorize URL and on the code exchange. |
| `rotation:` | `:required` for `:rotating`, else `:optional` | `:required` refuses a refresh answer that has no refresh token. `:optional` keeps the stored token. |
| `refresh_expires_in_key:` | `nil` | The grant field with the refresh token's lifetime in seconds. It sets `refresh_expires_at`. |
| `callback_check:` | `nil` | `->(params) { "message" or nil }`. A message refuses the callback, for example a missing admin consent. |
| `describe:` | `nil` | `->(grant:, account:, provider:) { { account:, label:, metadata: } }`. Names the account after the exchange (who signed in, the company name). A `Studio::Connections::Error` here goes to the error log, and the row stores under `label:`. |
| `declined_errors:` | `%w[access_denied]` | Callback `error` codes that mean the person said no. |
| `refusal_hint:` | redirect URI hint | Shown after any other callback error. |
| `revoked_errors:`, `revoked_pattern:` | `%w[invalid_grant]`, `nil` | A 400/401/403 with one of these errors, or a detail that matches the pattern, raises `Revoked`. |
| `rate_limited_statuses:` | `[429]` | These statuses raise `RateLimited`. |
| `filter_keys:` | `[]` | Request keys kept out of the logs by exact key (see Logs). |
| `revoke_note:` | generic | Shown when the provider cannot or did not confirm a revoke. |

### Refresh policies

| Policy | What is stored | `access_token` |
|--------|----------------|----------------|
| `:rotating` | the refresh token | Refreshes on every call, under the row's lock. Stores the answered refresh token before the access token is used. |
| `:cached` | the access and refresh tokens, and the access expiry | Returns the stored token while it is fresh. Within `refresh_margin` of expiry, or for a `stale:` token an API refused with a 401, refreshes once under the row's lock. Stores the new pair before it is used. |
| `:memory` | no token | The client-credentials grant. The token is cached in this process's memory per account until `refresh_margin` before expiry. `forget!` drops it. |

`with_lock` reloads the row. So a caller that holds a stale row waits, then spends
the newest refresh token. Two refreshes never spend one token.

### Where the account comes from

| `account:` | Example | Behaviour |
|------------|---------|-----------|
| `:connect` | a per-account domain | The admin names it in the Connect form (`account_param`). It is checked against `account_format`, kept in the session, and used for the URLs. The callback never reads it from its query. |
| `:callback` | a company id, a tenant id | The provider names it on the callback (`account_param`). It is checked against `account_format`. |
| `:described` | the email of the person who signed in | The `describe` hook returns `account:`. |

## Draw the routes

In `config/routes.rb`:

```ruby
Studio.draw_connection_routes(self, :files, path: "admin/files", controller: "admin/files",
                                            return_to: %w[/admin/files /integrations])
```

| Route | Name |
|-------|------|
| `POST /admin/files/connect` (also `GET` when the provider takes no account at Connect) | `admin_files_connect` |
| `GET /admin/files/callback` | `admin_files_callback`. Register this URL at the provider as the redirect URI. |
| `DELETE /admin/files/connections/:id` | `admin_files_disconnect` |
| `GET /admin/files` (only with `show: true`) | `admin_files` |

- `controller:` is the host's own controller that includes `Studio::ConnectionFlow` and adds `show`, the provider's page with its live read. Without it, the engine's `Studio::ConnectionsController` serves the three actions and no page is drawn.
- `show:` draws the page route. It defaults to true when `controller:` names a host controller.
- `return_to:` is the allowlist that `return_to` may name. Its first path is the default. Anything else goes to the default, so it is never an open redirect.
- `as:` overrides the route-name prefix (default: the path with `/` as `_`).

```ruby
module Admin
  class FilesController < ApplicationController
    include Studio::ConnectionFlow

    def show
      @connections = Studio::Connection.readable(:files)
    end
  end
end
```

The Connect button posts to `admin_files_connect_path` with `return_to` and, for
`account: :connect`, the `account_param` field. Disconnect sends `DELETE` to
`admin_files_disconnect_path(connection)`.

### Who may

`Studio.connection_admin_guard` is the guard for all three actions. It is one of two kinds:

- A method name on the controller (default `:require_admin`, from `Studio::ErrorHandling`).
  It refuses as a `before_action` does, by rendering or redirecting.
- A callable that takes the controller. It may render or redirect, or it may answer.
  An answer of `false` or `nil` refuses with a 403, so `->(c) { c.current_user&.admin? }` is safe.

Connect is POST-only for a provider with `account: :connect`. A GET skips Rails'
CSRF check, so a link that carries an attacker's account could otherwise start a
connection to that account in a signed-in admin's session. The action also refuses a
GET for such a provider (405) when a host draws its own route.

### What the flow does

- **connect** checks the encryption keys, then the account (`:connect`). It keeps a
  fresh OAuth state in the session and redirects to the provider.
- **callback** sends `Cache-Control: no-store`. It checks the state first: a mismatch
  is a 400, and the state works once. Then it checks the provider's `error`, the
  keys, `callback_check` and the account. It exchanges the code (code grant), calls
  `describe` and stores the row.
- **disconnect** revokes at the provider when there is a revoke endpoint and the
  row is readable. It forgets a `:memory` token and deletes the row. The message
  says whether the provider confirmed the revoke.

No token, and no part of one, is rendered, flashed or logged. A refused exchange,
describe or revoke goes to the error log (`rescue_and_log`) and is also shown on
the page.

## Use a connection

```ruby
connection = Studio::Connection.readable(:files).first
token = connection.fresh_access_token              # by the provider's policy
token = connection.fresh_access_token(stale: token) # after the API answered 401 (:cached)
Studio.connection(:tenant).access_token(tenant_id)  # :memory, by a bare account id
```

`access_token` raises `Studio::Connections::Revoked` when the provider no longer
honours the grant, and `RateLimited` when it throttles. Every other refusal raises
`Studio::Connections::Error`. `connection.metadata` holds what `describe` returned
(for example, the provider environment the account lives in). `connection.label`
holds the account's display name.

## Logs

The engine appends `Studio::Connections::LOG_FILTER` to `config.filter_parameters`:

- Every key in a provider's `filter_keys`, by **exact** key, String values only.
  Rails 8.1 filters the "Started GET" line's URL one query pair at a time, as a
  one-key hash with no controller to scope by
  (`ActionDispatch::Http::FilterParameters#filtered_query_string`). A
  controller-scoped filter would leave a callback's account id in that line.
- `code` on the connection controllers' parameters only. It still appears in the
  Started GET URL, where it is already spent.

## Tests, the e2e lane and a local demo

Each provider has two seams. Both are refused outside the development and test
environments, so a staging or QA environment refuses them as production does.

- `provider.http = ->(url, form, headers) { [status, body] }` stands in for the token and revoke endpoints.
- `provider.sign_in_stand_in` stands in for the sign-in page (anything that answers `authorize_url(redirect_uri:, state:, account:)`).

`Studio::Connections::StandIn.install!(provider, callback_params: {...})` installs
both. Its sign-in page comes straight back with its code (and the callback params).
Its token endpoint honours only the last refresh token it issued, so a rotation that
was not stored shows up as `Revoked` on the next read.

```ruby
# config/initializers/studio_connections.rb, after the definitions
if (Rails.env.development? && ENV["FILES_STAND_IN"] == "1") || (Rails.env.test? && ENV["E2E_STAND_INS"] == "1")
  Rails.application.config.to_prepare { Studio::Connections::StandIn.install!(Studio.connection(:files)) }
end
```

The engine's own proof is `test/integration/connections_client_test.rb` and
`test/integration/connections_flow_test.rb`. They use three generic test providers,
one per policy (`test/support/connections_host.rb`).
