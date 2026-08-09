# New App Setup Guide

Step-by-step checklist for spinning up a new McRitchie app with the Studio engine.

Reference apps: Tax Studio (simplest), Turf Monster (full-featured with Solana).

---

## 1. Rails New

```bash
rails new x_app --database=postgresql
cd x_app
```

Pick the next available app range in McRitchie Studio's port registry (`mcritchie-studio/config/satellites.yml`; agent workflow notes live in `mcritchie-studio/docs/agents/modules/ports-and-processes.md`):

- 3000-3099 = McRitchie Studio
- 3100-3199 = Turf Monster
- 3200-3299 = Tax Studio (planned/reserved)
- 3300-3399 = next candidate range unless the registry says otherwise

Use the first port in the range as the primary callback-ready server. Reserve the rest for worktrees and parallel test stacks.

## 2. Gemfile

```ruby
# Studio engine
gem "studio-engine", "~> 0.6"

# CSS
gem "tailwindcss-rails", "~> 4.5"

# Password hashing (only if enabling Studio.auth_methods :password)
# gem "bcrypt", "~> 3.1.7"

# Environment variables
gem "dotenv-rails", groups: [:development, :test]

# Google OAuth
gem "omniauth"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection", "~> 1.0"
```

```bash
bundle install
bin/rails tailwindcss:install
```

## 3. Tailwind Config

Replace `config/tailwind.config.js`:

```js
const execSync = require('child_process').execSync
const studioPath = execSync('bundle show studio-engine').toString().trim()

const studioColors = require(`${studioPath}/tailwind/studio.tailwind.config.js`)

const shades = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900]
const utilities = ['bg', 'text', 'border']
const opacities = [5, 10, 20, 30, 40, 50]
const safelist = [
  ...utilities.map(util => `${util}-primary`),
  ...utilities.flatMap(util => opacities.map(op => `${util}-primary/${op}`)),
  ...shades.flatMap(shade =>
    utilities.map(util => `${util}-primary-${shade}`)
  ),
  ...shades.flatMap(shade =>
    utilities.flatMap(util => opacities.map(op => `${util}-primary-${shade}/${op}`))
  ),
]

module.exports = {
  darkMode: 'class',
  content: [
    './app/views/**/*.{erb,html}',
    './app/helpers/**/*.rb',
    './app/javascript/**/*.js',
    `${studioPath}/app/views/**/*.{erb,html}`,
  ],
  safelist,
  theme: studioColors.theme,
}
```

## 4. Initializers

### `config/initializers/studio.rb`

```ruby
Studio.configure do |config|
  config.app_name = "X App"
  config.session_key = :x_app_user_id          # unique per app
  config.welcome_message = ->(user) { "Welcome to X App, #{user.display_name}!" }
  config.auth_methods = %i[magic_link google]  # add :wallet or :password only when needed
  config.registration_params = [:name, :email]
  config.mailer_from = Studio.mailer_from_for_transport(
    ses_from: "X App <team@example.com>"
  )
  config.configure_sso_user = ->(user) { user.role = "viewer" }
  # Optional: defaults check wallet_address, then solana_address.
  # Set this if your User exposes a different wallet column/helper.
  # config.wallet_address_method = :solana_address
  config.theme_logos = [
    { file: "favicon.png", title: "Favicon" },
    { file: "logo.png",    title: "Navbar Logo" },
    { file: "logo.png",    title: "Auth Logo" },
  ]
  config.theme_primary = "#8E82FE"             # pick your brand color
  # Smooth-load convention (default OFF): view-transition page swaps + a
  # single render per navigation. Opt in only once every page answers fast —
  # no-preview holds the old page until the fresh response arrives. Pair with
  # `vt-pinned-header` on the sticky header (exactly one per page).
  # config.smooth_load = true
  # config.nav_spinner_min_ms = 300            # default 2500
  # Out-of-the-box navigation (default OFF — empty sections render nothing):
  # declare link sections and the engine navbar mounts a link-sidebar trigger
  # + slide-out panel. A callable receives the view context (route helpers,
  # logged_in? walls); sections flagged admin: true show to admins only.
  # config.sidebar_sections = ->(view) {
  #   [ { title: "Site", links: [
  #         { label: "Home", href: view.root_path, emoji: "🏠", desc: "Front door" } ] },
  #     { title: "Ops", admin: true, links: [
  #         { label: "Errors", href: "/error_logs", emoji: "🚨" } ] } ]
  # }
end
```

### `config/initializers/studio_mail_transport.rb`

```ruby
Studio::MailTransport.configure!
```

This shared transport selects SES SMTP when `MAIL_TRANSPORT=ses` and
`SES_SMTP_USERNAME` / `SES_SMTP_PASSWORD` are present. Resend remains the
rollback path when `RESEND_API_KEY` is present and SES is not active. During
Resend rollback, `Studio.mailer_from_for_transport` uses `RESEND_MAILER_FROM`
so new apps can send through the shared `McRitchie Studio
<team@mcritchie.studio>` sender before their SES production setup is complete.

### `config/initializers/session_store.rb`

```ruby
Rails.application.config.session_store :cookie_store,
  key: "_x_app_session",
  secure: Rails.env.production?,
  httponly: true,
  same_site: :lax
```

Use an app-specific cookie key by default. Shared-domain SSO is optional and should be enabled only after the hub/satellite cookie contract is deliberately reviewed.

### `config/initializers/omniauth.rb`

```ruby
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
    ENV["GOOGLE_CLIENT_ID"],
    ENV["GOOGLE_CLIENT_SECRET"],
    scope: "email,profile",
    prompt: "select_account"
end

OmniAuth.config.allowed_request_methods = [:post]
```

Keep OmniAuth's request phase POST-only. Custom Google entrypoints should render
an auto-submitting POST form to `/auth/google_oauth2`, not redirect with GET.

## 5. Database Migrations

### Engine migrations — install these FIRST

The engine ships its own migrations (the email outbox, `Studio::Link`,
`Studio::Enumeral`, and an `image_caches` column relaxation). Copy them in with
the standard Rails engine task — note the task is `studio_engine:`, not
`studio:`, and each copied file lands with a `.studio_engine.rb` suffix and a
provenance comment naming the original timestamp:

```bash
bin/rails studio_engine:install:migrations
bin/rails db:migrate
```

**Install all of them, and re-run both commands after every engine upgrade.**
Every engine migration is safe on every app: the ones that create tables add a
table you may not use yet, and the one that ALTERS an app-owned table
(`allow_null_image_cache_owner`) no-ops when that table is absent
(studio-engine >= 0.30.1).

One limit worth knowing: `install:migrations` skips **by migration name**, so an
app already holding an older copy of a migration never receives an updated one
from a later engine release — re-running brings you NEW migrations, not revised
versions of ones you already have. If a release note says a migration changed,
replace your copy by hand.

Do **not** try to slim the set down by deleting copies you think you don't need.
`install:migrations` builds its skip-list from the files **present**, so a
deleted copy is re-copied with a fresh timestamp on your next upgrade — deletion
is not durable, which is why the guard lives in the migration instead.

The outbox is the one that bites if you skip the step entirely:
`Studio::Email.deliver` records mail only when `studio_email_deliveries` EXISTS,
and falls back to a plain async `deliver_later` when it doesn't — silently, with
no error. An app missing the migration therefore drops every captured email and
shows an always-empty `/_studio/local_emails`. That was a real bug in
mcritchie-industries, fixed 2026-08-08.

Verify the install rather than trusting it:

```ruby
Studio::EmailDelivery.available?  # => true
```

### Users

```ruby
class CreateUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :users do |t|
      t.string :name
      t.string :email
      t.string :provider
      t.string :uid
      t.string :role, default: "viewer"
      t.string :slug

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :slug, unique: true
    add_index :users, [:provider, :uid], unique: true
  end
end
```

Add `password_digest` only if the app deliberately enables password auth:

```ruby
add_column :users, :password_digest, :string, null: false, default: ""
```

### Error Logs

```ruby
class CreateErrorLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :error_logs do |t|
      t.string :slug
      t.text :message
      t.text :inspect
      t.text :backtrace
      t.string :target_type
      t.bigint :target_id
      t.string :target_name
      t.string :parent_type
      t.bigint :parent_id
      t.string :parent_name

      t.timestamps
    end

    add_index :error_logs, :slug, unique: true
  end
end
```

### Theme Settings

```ruby
class CreateThemeSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :theme_settings do |t|
      t.string :app_name
      t.string :primary
      t.string :dark
      t.string :light
      t.string :accent1
      t.string :accent2
      t.string :warning
      t.string :danger

      t.timestamps
    end

    add_index :theme_settings, :app_name, unique: true
  end
end
```

```bash
bin/rails db:create db:migrate
```

## 6. User Model

```ruby
class User < ApplicationRecord
  include Sluggable
  # Only add this when Studio.auth_methods includes :password and the users
  # table has password_digest:
  # has_secure_password validations: false

  def name_slug
    name.present? ? name.parameterize : "user-#{id}"
  end

  def display_name
    name.presence || email&.split("@")&.first || "User"
  end

  def admin?
    role == "admin"
  end

  def self.from_omniauth(auth)
    user = find_by(provider: auth.provider, uid: auth.uid)
    return user if user

    user = find_by(email: auth.info.email)
    if user
      user.update!(provider: auth.provider, uid: auth.uid)
      return user
    end

    create!(
      email: auth.info.email,
      name: auth.info.name,
      provider: auth.provider,
      uid: auth.uid
    )
  rescue ActiveRecord::RecordNotUnique
    find_by(email: auth.info.email) || find_by(provider: auth.provider, uid: auth.uid)
  end
end
```

Passwordless apps should not assign throwaway passwords. Email proof comes from
consuming a magic link — `Studio::LinkConsumption#consume_magic_link`, which
burns the row via `Studio::Link#burn`; Google proof comes from OmniAuth and any
host-level token validation you add.

## 7. Application Controller

```ruby
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end
```

## 8. Routes

```ruby
Rails.application.routes.draw do
  # Optional but recommended for passwordless apps: make /signin the canonical
  # create-or-login page and redirect legacy GETs there.
  get "signin", to: "sessions#new", as: :signin
  get "login",  to: redirect("/signin"), as: nil
  get "signup", to: redirect("/signin"), as: nil

  Studio.routes(self)

  root "pages#index"

  # Admin: Navbar review (engine controller)
  get "admin/navbar", to: "navbar#show", as: :admin_navbar

  # App-specific routes here...
end
```

`Studio.routes(self)` draws `POST /magic_link` (request a link) when
`Studio.auth_methods` includes `:magic_link`, and `GET`/`POST /l/:token` (the
scanner-safe confirm page and the consume that burns the token) whenever
`Studio.draw_link_routes` is on. **A magic link needs the `studio_links`
table**, which section 5's `bin/rails studio_engine:install:migrations` already
copies — run that (and `db:migrate`) before enabling `:magic_link`. Do **not**
hand-copy the engine's `create_studio_links` migration on top: the rake task
installs it as `<timestamp>_create_studio_links.studio_engine.rb`, a hand copy
keeps its own name, and both declare `class CreateStudioLinks` — so
`db:migrate` dies on `ActiveRecord::DuplicateMigrationNameError`.

The stock engine sign-in view now renders from `Studio.auth_methods`: a
passwordless app gets the magic-link request form (posting to
`magic_link_request_path`) and the Google button (`/auth/google_oauth2`) out of
the box, and the password field appears only when `Studio.password_login_available?`
(passwords enabled AND the User responds to `authenticate`). A passwordless app no
longer needs to override the sign-in page for correctness — override it only for a
bespoke layout. Use Turf Monster's `/signin` flow as the full-featured reference.

## 9. Layout

### `app/views/layouts/application.html.erb`

```erb
<!DOCTYPE html>
<html>
  <head>
    <title><%= content_for(:title) || "X App" %></title>
    <%= render "layouts/studio/head" %>
  </head>

  <body x-data class="bg-page text-body min-h-screen" :class="{ 'dev-mode': $store.devMode }">
    <%= render "studio/banners/environment" %>
    <%= render "layouts/navbar" %>

    <div class="max-w-7xl mx-auto px-4 py-6">
      <%= render "layouts/studio/flash" %>
      <%= yield %>
    </div>
  </body>
</html>
```

**Environment banner**: one render call, no conditional around it. Earlier
versions of this guide pasted a hand-rolled yellow `<div>` here, and every app
that copied it drifted — different show rules, different labels, and no link to
the local email inbox. `studio/banners/environment` now owns all three
decisions:

| Decision | Rule |
|---|---|
| Whether it appears | Every environment except real production. A QA app (Rails production + `QA_ENV=true`) is a review target, so it appears there too. |
| What it says | `"<Env> Environment"`, or `"QA Environment · Non-production"` on QA. Add segments with `extra:`. |
| Whether the inbox links | Only where `/_studio/local_emails` actually resolves — the same gate the controller enforces. Off-box (QA) the button degrades to an inert status chip, never a dead link. |

Locals, all optional: `preview:` (suppress inside a navbar-preview render — a
duplicate `vt-pinned-header` silently kills view transitions), `extra:`
(message segments), `devnet:` (chip), `environment_label:` (override the whole
message).

The banner uses inline styles rather than Tailwind classes so it renders
identically across apps with different CSS builds. The `devMode` Alpine store is
initialized by the engine's `_head.html.erb`, and the `dev-mode` body class
drives dev-only UI.

**QA and email, stated plainly:** on QA the inbox page is unreachable and email
capture is off, both because `Rails.env.production?` hard-closes
`Studio.local_tool_enabled?` / `Studio.local_email_capture?`. QA sends real
mail through the real transport. Setting `LOCAL_EMAIL_CAPTURE=1` on a QA dyno
does nothing.

### `app/views/layouts/_navbar.html.erb`

Copy from the engine base and add your nav links to the desktop `<nav>` and mobile sub-navbar sections. See [NAVBAR_SETUP.md](NAVBAR_SETUP.md).

## 10. Public Assets

Place in `public/`:
- `favicon.png` — browser tab icon
- `logo.png` — navbar + auth page logo
- `studio-logo.svg` — optional, only if the app participates in one-way SSO

## 11. Seeds

```ruby
# db/seeds.rb
admin = User.find_or_create_by!(email: "alex@mcritchie.studio") do |u|
  u.name = "Alex McRitchie"
  u.role = "admin"
end
puts "Seeded admin: #{admin.email}"
```

```bash
bin/rails db:seed
```

## 12. Google Cloud Console

Add redirect URI for your app's port:
```
http://localhost:{PORT}/auth/google_oauth2/callback
```

See [GOOGLE_AUTH_SETUP.md](GOOGLE_AUTH_SETUP.md) for full instructions.

## 13. CSS Component Classes

The engine ships the shared component classes — do NOT copy them from another
app. Add ONE line to `app/assets/tailwind/application.css` (after
`@import "tailwindcss";`):

```css
@import "../builds/tailwind/studio_engine";
```

That entry point is auto-generated by tailwindcss-rails on every build/watch
(or manually with `bin/rails tailwindcss:engines`) from the engine's
`app/assets/tailwind/studio_engine/engine.css`. It defines `.card`,
`.card-hover`, `.badge`, `.input-field`, `.empty-state`, `.json-debug`,
`.label-upper`, `.studio-link-sidebar-layer` (the link-sidebar stacking
layer), the Alpine `[x-cloak]` pre-init rule, and the button system (`.btn`,
`.btn-primary`, `.btn-secondary`, `.btn-outline`, `.btn-danger`,
`.btn-warning`, `.btn-success`, `.btn-google`, `.btn-neutral`, `.btn-sm`,
`.btn-lg`) as Tailwind v4 utilities wired to the theme CSS custom properties
(`--color-cta` etc.), so they follow the app's 7-role theme in dark and light
mode. The
shared Tailwind preset (already wired in section 3) is required — the classes
`@apply` its `surface`/`heading`/`subtle`/`primary` tokens — and also provides
`text-2xs` (11px) and `text-3xs` (10px) for dense UI instead of
`text-[11px]`/`text-[10px]` arbitrary values.

Section 3's `content` glob entry for the engine's views
(`${studioPath}/app/views/**/*.{erb,html}`) is load-bearing here: `@utility`
classes are only emitted when Tailwind sees them used, so an app that skips
that glob gets silently unstyled engine partials.

## 14. Hub Link (McRitchie Studio)

Add a nav link in McRitchie Studio only after the app is registered in `mcritchie-studio/config/satellites.yml`. If the app participates in one-way SSO, point the link at `/sso_login`; otherwise point at the app root or a public landing page.

## 15. Lint And CI

Two things a fresh app gets wrong by default. Both fail as a RED CI lane on the
app's very first push, and both look like code defects when they aren't.

### Lint — run it before your first commit

The generated `.rubocop.yml` inherits `rubocop-rails-omakase`, which enforces
`[ a, b ]` (spaces inside array brackets). Hand-written and scaffolded code
routinely uses `[a, b]`, so a brand-new app is usually born with a red `lint`
lane:

```bash
bin/rubocop -a      # autocorrects the Layout cops
bin/rubocop         # must print "no offenses detected" before your first PR
```

**Most of the house keeps the cop and formats to it**; two apps opt out. Surveyed
against `origin/main` on 2026-08-09 — note that a `.rubocop.yml` may disable the
cop indirectly through `inherit_from`, so follow that line before concluding
anything:

| Opts OUT of `Layout/SpaceInsideArrayLiteralBrackets` | Keeps it |
|---|---|
| mcritchie-studio (`.rubocop.yml:6`), turf-monster (`.rubocop_todo.yml:59`, 658 suppressed offences) | mcritchie-industries · moms-app · rolio · acquisition-studio · chain-ops |

Either answer is defensible — the template ships the override commented out for
exactly this reason. What is NOT defensible is a red lane nobody owns: moms-app's
`lint` lane was red from its very first CI run and stayed red, so by the time it
mattered nothing downstream could tell a new break from the standing one.

### CI — declare your system dependencies

The generated workflow installs `libpq-dev` and `libvips` and nothing else:

```yaml
- name: Install packages
  run: sudo apt-get update && sudo apt-get install --no-install-recommends -y libpq-dev libvips
```

**If your app shells out to any other binary, add it to that step in EVERY job
that runs tests** (the workflow has separate `test` and `system-test` jobs, each
with its own install step — updating one and not the other is the common miss).

The failure mode is misleading: the test that exercises the missing binary raises
inside its own setup, so the lane reads as a code defect rather than a missing
package. moms-app's `BookStitcher` shells out to `ffmpeg`; its suite failed on
fixture generation, and the app's README had listed `ffmpeg` as a requirement the
whole time — the requirement was documented for humans and never told to CI.

### System tests — the job exists; the tests do not

`rails new` generates a **`system-test` CI job** and puts `capybara` +
`selenium-webdriver` in the Gemfile, but it does **not** create `test/system/` or
`test/application_system_test_case.rb`. So a fresh app's system-test lane dies on:

```
cannot load such file -- <app>/test/system (LoadError)
```

It has never run a test, and it never will until you give it content. Create both,
and add at least one real system test:

```ruby
# test/application_system_test_case.rb
require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
end
```

**The mechanic is in the generator:** on Rails 8, `test/system` and
`application_system_test_case.rb` are scaffolded only behind a `devcontainer?`
guard (`railties app_generator.rb:257-262`, 8.1.3.1 — Rails 7.2 has no such guard),
while the CI template emits the `test:system` invocation regardless. A plain
`rails new` as in § 1 therefore hands you the lane without the tests.

Surveyed against `origin/main` on 2026-08-09 — refs given so you can re-check
rather than trust this table, and **so you can tell a stale answer from a current
one.** Every app below runs `test:system` in CI (e.g.
`turf-monster/.github/workflows/ci.yml:115`, `chain-ops/.github/workflows/ci.yml:93`);
acquisition-studio has no `ci.yml` at all.

| App (`origin/main`) | `test/system/*_test.rb` | `.keep` | What the lane reports |
|---|---|---|---|
| mcritchie-studio `92e3e284` | 7 | yes | a true verdict |
| rolio `f40ca94` | 2 | yes | a true verdict |
| mcritchie-industries `847254e` | 1 | yes | a true verdict |
| moms-app `80648fe` | 1 | no | a true verdict |
| turf-monster `da1dc87` | **0** | yes | **permanently GREEN, testing nothing** |
| chain-ops `d44060f` | **0** | yes | **permanently GREEN, testing nothing** |

So most apps do have real system tests. The trap is the pair that do not: a
committed `test/system/.keep` makes `bin/rails test:system` glob an existing
directory, find zero tests, and exit **green** — where an absent directory would
raise `cannot load such file` and go red.

**And the `.keep` may not have been anyone's decision.** Rails 7.2's generator
creates it unconditionally (`railties 7.2.3.1 app_generator.rb:254-255`), so a
7.2-era app inherits a green-forever lane without choosing one. Do not read those
two rows as a deliberate posture; read them as what happens by default.

Check your own lane before you trust it: `git ls-files test/system`. If the answer
is `.keep` alone, that lane has never tested anything. Give it real tests or delete
the job — what you must not do is leave a green that means nothing, because an
unquestioned green hides far better than a red.

Pick assertions the cheaper tiers genuinely cannot make. A system test earns its
cost through the real browser — JS actually executing, a redirect actually
followed — so asserting only server-rendered markup here duplicates an integration
test at many times the runtime.

## 16. Verify

```bash
bin/rails server -p {PORT}
```

- [ ] Homepage loads with navbar, logo, brand title
- [ ] Environment banner shows "Development Environment" + DEV MODE + the Local Inbox link (§ 9)
- [ ] Dark/light mode toggle works
- [ ] `/signin` (or the app's chosen auth page) shows logo + enabled auth methods
- [ ] Legacy `/login` and `/signup` GETs redirect to `/signin`, if using the unified auth pattern
- [ ] Magic-link sign-in works
- [ ] Google OAuth works (after adding redirect URI)
- [ ] `/admin/theme` loads (logged in as admin)
- [ ] `/admin/navbar` loads (admin preview page)
- [ ] `/error_logs` loads
- [ ] SSO from McRitchie Studio works, if enabled

---

## Optional: Solana Integration

If the app needs Solana wallet auth and/or on-chain operations, add this on top of the base setup. Reference: Turf Monster (`docs/SOLANA.md`).

### Additional Gems

```ruby
gem "solana-studio", "~> 0.4.7"
gem "ed25519"           # Signature verification
gem "sidekiq"           # Background jobs (ATA creation, balance sync)
```

### Additional User Columns

```ruby
add_column :users, :web2_solana_address, :string             # Managed wallet (server-signed)
add_column :users, :web3_solana_address, :string             # Phantom wallet (user-signed)
add_column :users, :encrypted_web2_solana_private_key, :text  # Encrypted keypair
add_column :users, :level, :integer, default: 1, null: false
add_column :users, :username, :string
```

Do not add DB balance columns for new Solana apps unless you are intentionally
building a ledger. Turf Monster's current model keeps USDC/USDT in each user's
token account and reads balance from chain/cache.

### Solana Initializer

```ruby
# config/initializers/solana.rb
require Rails.root.join("app/services/solana/keypair")
```

### Solana Routes

```ruby
# If you only need basic wallet auth, add :wallet to Studio.auth_methods and let
# Studio.routes draw /auth/solana/nonce + /auth/solana/verify.
#
# Add app-specific routes that can conflict with OmniAuth wildcards BEFORE
# Studio.routes.
get "auth/phantom/callback", to: "solana_sessions#phantom_callback"

Studio.routes(self)
```

If the host needs fully custom magic-link or wallet routes, opt out before
`Studio.configure` and draw every auth route yourself:

```ruby
# config/initializers/studio.rb
Studio.draw_auth_routes = false
```

```ruby
# config/routes.rb
get  "auth/solana/nonce",  to: "solana_sessions#nonce"
post "auth/solana/verify", to: "solana_sessions#verify"

# Wallet
resource :wallet, only: [:show] do
  get  :sync
end
```

### Services to Copy

From `turf-monster/app/services/solana/`:
- `config.rb` — env var accessors
- `keypair.rb` — Rails extensions (admin keypair, encryption)

Signature verification, RPC, transaction building, Borsh, and SPL helpers come
from the `solana-studio` gem. Local apps should only copy app-specific wrappers
when they truly need app behavior beyond the gem.

### JS Modules to Copy

From `turf-monster/app/javascript/`:
- `solana_utils.js` — Base58, balance refresh, shared utilities
- `phantom_deeplink.js` — Mobile Phantom deep linking

Pin in `config/importmap.rb` and import in `application.js`.

### Environment Variables

Add to `.env` (see [ENV_SETUP.md](ENV_SETUP.md)):
```env
SOLANA_ADMIN_KEY=...
SOLANA_RPC_URL=https://api.devnet.solana.com
```

Use the owning app docs and McRitchie Studio credential inventory for the
current 1Password item names. Do not copy wallet addresses or private key
material into this engine setup guide.

### Wallet Types

| Type | Column | Who Signs | Use Case |
|------|--------|-----------|----------|
| Managed | `web2_solana_address` | Server (keypair in DB) | Users who don't have Phantom |
| Phantom | `web3_solana_address` | User's browser extension | Web3 native users |

Expose one wallet helper for shared session/SSO awareness:

```ruby
def solana_address
  web3_solana_address || web2_solana_address
end
```

Then set `config.wallet_address_method = :solana_address`, or rely on the
engine default fallback when the method is named `solana_address`.

### Key Concepts

- **Nonce-based auth**: Server generates nonce → client signs with Phantom → server verifies Ed25519 signature
- **Managed wallets**: Server generates a keypair on user creation, encrypts the secret with `MANAGED_WALLET_ENCRYPTION_KEY`, and signs only the flows the app explicitly allows.
- **Balance**: read token balances from chain/cache; avoid a parallel DB-balance source of truth.
- **Seeds/Level**: on-chain progression system; Turf Monster's current default season schedule is `[25, 19, 14, 10, 7]`.

See `turf-monster/docs/SOLANA.md` and `turf-monster/docs/AUTH.md` for full architecture.
