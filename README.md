# Studio Engine

Shared Rails engine for McRitchie apps. Provides authentication, error handling, dynamic theming, and common concerns used by [McRitchie Studio](https://app.mcritchie.studio) and [Turf Monster](https://app.turfmonster.media).

> **Part of the McRitchie ecosystem** — see [`ECOSYSTEM.md`](https://github.com/McRitchie-Studio/mcritchie-studio/blob/main/docs/ECOSYSTEM.md) for the 5-repo map; [`house-burn-down.md`](https://github.com/McRitchie-Studio/mcritchie-studio/blob/main/docs/agents/system/house-burn-down.md) for fresh-Mac recovery.

## Installation

```ruby
# Gemfile — install from RubyGems (recommended)
gem "studio-engine", "~> 0.56"   # EXAMPLE — pin the floor YOUR app needs
```

Then `bundle install`. That number is an example, not a statement about the
current release: this README deliberately makes no such claim, because a
hand-written one rots silently — it read `v0.6.1` for fifty minors. For what is
live, see [RubyGems](https://rubygems.org/gems/studio-engine); for what changed,
[`CHANGELOG.md`](./CHANGELOG.md).

Pin the floor your app actually needs rather than copying the example. Each
consumer pins its own and records WHY beside it, and they differ on purpose. A
two-segment `~>` admits everything under `1.0`, so the pin documents the floor
rather than constraining the resolve — read the `Gemfile.lock` for what really
resolved.

> Published to RubyGems as of v0.4.0 (2026-05-17). New installs should use the
> RubyGems form, which all three consumer Rails apps (`mcritchie-studio`,
> `turf-monster`, `mcritchie-industries`) already use.

## What It Provides

- **Authentication**: Passwordless magic-link auth, optional password auth, Google OAuth via OmniAuth, Solana wallet sign-in, and optional one-way SSO patterns
- **Error handling**: `Studio::ErrorHandling` concern with `rescue_and_log`, `ErrorLog` model with `capture!`, error log viewer at `/error_logs`
- **Session drift**: every page carries a session stamp and loads `window.StudioSession`, which notices when another tab signs in or out, the session expires, or the server revokes it; `session:changed` / `session:mismatch` events, cross-tab sync, an identity-source plug-in interface, and `expectChange` holds for deliberate switches. The rehydrate endpoint (`GET /session/state`) is opt-in. See [`docs/SESSION_DRIFT.md`](docs/SESSION_DRIFT.md).
- **Theme system**: Dynamic CSS custom properties generated from 7 role colors (primary, dark, light, success, accent, warning, danger). Dark/light mode toggle. Admin theme editor at `/admin/theme`.
- **UI primitives**: Shared component partials and CSS primitives such as `components/emoji_swap` for nav/sidebar emoji hover transitions.
- **Operator tooling**: Shared `studio/banners/environment` banner with Dev Mode + email connector controls and `studio/banners/impersonation`.
- **Sluggable concern**: a human-readable slug written once at create (`to_param` returns it); `rename_slug!` changes it and cascades to every child column in one transaction, and a refused rename answers 422
- **ThemeSetting model**: Per-app DB overrides with fallback to config defaults
- **Geo**: `Studio::GeoDetection` places every visitor (IP → country + subdivision, session-cached), `Studio::GeoSetting` stores the operator's blocked countries and regions, `require_geo_allowed` locks whichever surfaces an app chooses, and the shared badge + `/admin/geo` manager ship with it. See [`docs/GEO.md`](docs/GEO.md).
- **Site identity and link previews**: `Studio::SiteIdentity` holds the app's title, description and image, edited at `/admin/link_preview` beside a live unfurl card and read anywhere through `Studio.site_identity`. Every page unfurls with it unless it calls `link_preview image:, title:, description:`, and `Studio::LinkPreviewBots` serves preview fetchers a slim page under iMessage's 1 MiB limit. Adopt with `bin/rails g studio:site_identity`. See [`docs/LINK_PREVIEW.md`](docs/LINK_PREVIEW.md).
- **Public user page**: `/u/:username` shows a user's avatar and username (nothing else), and unfurls with their avatar, falling back to the site image. Link any username to it with `link_to_user_profile(user)` or `studio_user_profile_path(user)`. Opt in with `config.draw_public_user_routes = true`. See [`docs/PUBLIC_USER_PAGE.md`](docs/PUBLIC_USER_PAGE.md).
- **Transactional emails**: `Studio::EmailCatalog` — every email an app sends, its type, a live preview, and its banner — plus the shared `/admin/emails` page. Every app inherits the standard emails and their artwork on day one, and can register its own workflows and upload its own banners. See [Transactional emails](#transactional-emails).
- **Site footer**: `<%= studio_site_footer %>` in the layout renders the public site's footer. It is on by default: with nothing configured it prints the app's name, logo and the legal links the app has routes for, and no address. `config.site_footer` declares the app's own facts (brand, social profiles, link columns, an address with a live map, legal links), every part optional; `config.site_footer_address` adds a location in one setting; `config.site_footer = false` turns the footer off. Leaflet is vendored and served by the engine. See [`docs/SITE_FOOTER.md`](docs/SITE_FOOTER.md).
- **Booking**: a simple scheduler on Google Calendar appointment schedules, with or without the footer. With `config.booking_url`, `studio_booking_frame` embeds Google's booking page, `studio_booking_link` opens it in a popup, and `config.draw_booking_routes = true` draws `/schedule` (or name the app's own page with `config.booking_path`). `config.booking_crop` crops the frame to the slot picker at rest, from numbers `bin/booking-crop-measure` reads off the app's own schedule. See [`docs/BOOKING.md`](docs/BOOKING.md).
- **Surveys**: define a survey in app code (`config/surveys/*.rb`, `Studio.define_survey`) with six question types — emoji scale, 1–5 rating, single and multiple choice, short and long text — and the engine serves it at `/surveys/:slug`: one question per screen, autosave, resume, keyboard shortcuts, and a no-JavaScript fallback. `config.on_survey_completed` and `config.survey_ref_resolver` let the app fire its own goals and attribute email arrivals. An admin panel at `/admin/surveys` breaks results down per question and exports CSV. Opt in with `config.draw_survey_routes = true` and `config.draw_admin_survey_routes = true`. See [`docs/SURVEYS.md`](docs/SURVEYS.md).

## Configuration

Each consuming app configures the engine in `config/initializers/studio.rb`:

```ruby
Studio.configure do |config|
  config.app_name = "My App"
  config.session_key = :my_app_user_id
  config.welcome_message = ->(user) { "Welcome, #{user.display_name}!" }
  config.auth_methods = %i[magic_link google]
  config.registration_params = [:name, :email]
  config.mailer_from = Studio.mailer_from_for_transport(
    ses_from: "My App <team@example.com>"
  )
  config.theme_primary = "#4BAF50"   # Override default violet
  config.theme_logos = ["logo.svg"]

  # Smooth-load convention (default OFF). Renders the view-transition +
  # no-preview metas: Turbo page swaps materialize behind the current page and
  # present with a view transition, exactly one render per navigation. Fix any
  # multi-second pages BEFORE opting in — no-preview holds the old page until
  # the fresh response arrives.
  config.smooth_load = true
  # Nav spinner minimum display (default 2500). Smooth-load apps typically
  # drop to ~300; keep the high floor if multi-second ops ride the spinner.
  config.nav_spinner_min_ms = 300
end
```

`auth_methods` draws both auth pages. `/login` and `/signup` render the password
form only when `:password` is enabled and the User has `authenticate`
(`Studio.password_login_available?`); otherwise they render the email-only
sign-in-link form when `:magic_link` is enabled, and the Google button only with
`:google`. A passwordless signup stores nothing from the form: it mails a link,
and using the link creates the account. So `registration_params`' `:name` shows a
Name field only on a password app.

`POST /login`, the password exchange, is drawn only when `auth_methods` includes
`:password`. A passwordless app answers it with 404 for every address, so it
cannot tell a member from a stranger. `GET /login` and `login_path` are drawn for
every app.

### Local log rotation (automatic — nothing to configure)

The engine caps the host app's **development** log at 16 MB and its **test** log
at 8 MB, keeping one rotated sibling each. There is nothing to install, run, or
remember: it rides the gem, so every checkout and every worktree is born with it.

It exists because Rails' own default is far too generous for a machine that
carries many worktrees. `config.load_defaults "7.1"` sets `log_file_size` to
**100 MB** for development *and* test, and each keeps a rotated sibling — up to
~400 MB of log per checkout.

**Production is untouched.** The cap applies only where `Rails.env.local?`, so
apps that hand their stream to STDOUT for the platform keep doing exactly that.
A host that names its own `config.logger` is never overridden.

To choose your own cap, or to opt out:

```ruby
# config/application.rb (after `require "studio"`) or config/environments/development.rb
Studio.local_log_max_bytes = 64.megabytes  # your own cap
Studio.local_log_max_bytes = false         # opt out; Rails' 100 MB default returns
```

**This one setting cannot go in `config/initializers/studio.rb`.** It is read
during boot — Rails builds the logger in a bootstrap initializer, long before
`config/initializers` is loaded — so an initializer would be too late and would
silently do nothing. Every *other* `Studio.*` setting belongs in the initializer
as usual.

Transactional mail transport is shared through `Studio::MailTransport`:

```ruby
# config/initializers/studio_mail_transport.rb
Studio::MailTransport.configure!
```

It selects SES SMTP when `MAIL_TRANSPORT=ses` and SES SMTP credentials are
present, otherwise falls back to Resend when `RESEND_API_KEY` is present.

## Routes

In the consuming app's `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  Studio.routes(self)
  # ... app routes
end
```

This draws the enabled auth routes (`/login`, `/signup`, `/logout`, `POST /magic_link` to request a link, `GET`/`POST /l/:token` for the link itself, Solana routes), OAuth callbacks, optional SSO routes, `/error_logs`, and `/admin/theme`. Set `Studio.draw_geo_routes = true` to add the geo manager (`/admin/geo`) and its public probe (`/geo/check`) — off by default because turf-monster owns those helper names until its adoption lands. Magic-link emails point at the inert `GET /l/:token` confirmation page; the single-use token is burned only by the CSRF-protected `POST` to `link_consume_path`.

Set `Studio.draw_session_routes = true` to add the session-drift rehydrate endpoint (`GET /session/state`) — off by default because it inherits the host's filters, which an app should check first ([`docs/SESSION_DRIFT.md`](docs/SESSION_DRIFT.md)).

Set `Studio.draw_booking_routes = true` to add the booking page (`GET /schedule`, helper `studio_booking_path`) — off by default because mcritchie-studio draws its own `/schedule` until it adopts this one. An app that keeps its own booking page names it with `Studio.booking_path` instead ([`docs/BOOKING.md`](docs/BOOKING.md)).

Set `Studio.draw_survey_routes = true` to add the public survey pages (`/surveys/:slug`, helper `studio_survey_path`) and `Studio.draw_admin_survey_routes = true` to add the admin results panel (`/admin/surveys`, helpers `admin_surveys_path` / `admin_survey_path`) — both off by default because an app may already own those paths. Both need the `studio_survey_responses` table ([`docs/SURVEYS.md`](docs/SURVEYS.md)).

**Magic links need the `studio_links` table.** Install it with `bin/rails studio_engine:install:migrations && bin/rails db:migrate` (install all of them) before enabling `:magic_link` — never by hand-copying the migration, which collides with the task's own copy on `class CreateStudioLinks`. Without the table, the first sign-in raises `Studio::Link::MissingTable`.

In non-production local requests, this also draws `/_studio/local_emails`, a local email inbox for agent/worktree proof flows. Set `LOCAL_EMAIL_CAPTURE=1` or run with `AGENT_WORKTREE=1` to record outbox rows without sending real email.

## Non-Production Banners

Consumer layouts can render the shared environment banner inside their sticky
header:

```erb
<%= render "studio/banners/environment", devnet: false %>
```

The environment banner includes:

- a Dev Mode toggle button backed by `Alpine.store("devMode")`
- an Email status button that links to `/_studio/local_emails`
- a send/capture signal plus SES/Resend/unknown connector icon

Apps with admin Act As / impersonation state can render the matching banner
with their own users and return route:

```erb
<%= render "studio/banners/impersonation",
           impersonated_user: current_user,
           admin_user: true_user,
           stop_path: admin_stop_impersonating_path %>
```

Each app owns its Act As session, authorization rule, audit log and enter/exit
actions; the engine supplies only the banner.

## UI Primitives

### The "at" time stamp — `at_time_tag`

Stamps WHEN something happened, on the reader's own clock: `at 3:53p`, gaining a
date only when the stamp is not today and the year only when it differs. A
country flag trails the clock when the reader's timezone is outside the US, and
inside the US there is no flag at all — it carries signal only because it is
unusual. The relative phrase ("7 minutes ago") moves to the hover title.

Render the re-stamper **once per page, near the end of the layout body**, then
use the helper anywhere:

```erb
<%# near the end of <body>, once %>
<%= render "studio/at_time_script" %>

<%# anywhere %>
<%= at_time_tag(release.shipped_at) %>
<%= at_time_tag(task.created_at, prefix: nil) %>
```

**Near the END of the body matters.** The script's first pass runs synchronously
as it parses, so rendering it in `head` finds zero stamps on that pass and leaves
them until the next one.

The server renders the app-timezone form as a no-JS fallback and never renders a
flag — it cannot know where the reader is sitting, so only the reader's machine
may assert one. A host that omits the script still gets working stamps, just
frozen in the app's timezone. Specimen: `/admin/style` → Tricks → Time stamps.

### Smooth-load header pin — `.vt-pinned-header`

When `Studio.smooth_load` is on, put `vt-pinned-header` on the app's sticky
header: it gets its own named view-transition group, so page content
transitions beneath a navbar that stays put (or smoothly morphs heights).
**Exactly one element per page** — a duplicate `view-transition-name` makes
the browser silently skip the whole transition, with no error and no animation.

```erb
<header class="sticky top-0 vt-pinned-header ...">
```

Render `components/emoji_swap` inside a link or button with the `group` class to
slide between two emoji on hover and keyboard focus. The CSS ships through
`studio_theme_css_tag`, including a reduced-motion fade fallback.

```erb
<%= link_to root_path, class: "group inline-flex items-center gap-2" do %>
  <%= render "components/emoji_swap", base: "📊", hover: "✨" %>
  <span>Dashboard</span>
<% end %>
```

### Modal host

`studio/modals/_host.html.erb` is the single shared shell for every modal. It
owns the backdrop, scroll lock, escape + click-outside dismissal, ARIA dialog
role, mount/unmount animations, and bfcache/Turbo snapshot cleanup. Animation
keyframes ship inline in the partial — consumers need no extra CSS.

Render it once near the end of the layout `<body>`, registering each modal in
the block:

```erb
<%= render "studio/modals/host" do %>
  <template x-if="$store.modals.current().id === 'crop-photo'">
    <%= render "studio/modals/crop_photo" %>
  </template>
<% end %>
```

#### Writing a modal's content partial — two rules the host imposes

Both rules let the card render and then do less than it looks like it does.
They differ in whether anything reaches the CONSOLE, which is the first thing
to check when a registered partial misbehaves.

**1. SINGLE ROOT — fails in total silence.** A content partial's outer `<div>`
is the host's required root. Alpine's `<template x-if>` clones only the FIRST
root element of its content, so a second top-level sibling — a stray `<span>`,
a trailing `<style>` block, a comment-turned-node — is dropped on the floor.
Nothing raises and nothing logs: `x-if` takes `.firstElementChild` and asks no
questions. (Alpine DOES warn on a multi-root `x-for` template — *"x-for
templates require a single root element, additional elements will be ignored"*
— which is exactly why this one catches people out. The modal host is `x-if`,
and `x-if` ships no such check.) Bake anything extra inside the wrapping
`<div>`.

**2. NO DOUBLE QUOTE INSIDE `x-data` — this one LOGS.** The attribute is
double-quoted, so an inner double quote CLOSES it. Alpine then mounts a
component whose expression is truncated mid-statement: every element still
renders and every handler does nothing. It is NOT silent. The truncation
leaves a JavaScript syntax error, Alpine's evaluator catches it, and the
default handler prints `Alpine Expression Error: …` together with the
offending expression — a `console.warn`, followed by an async rethrow. That
warning is the best clue this rule was broken, so send a debugging engineer to
the console rather than to the markup. Single-quote everything inside
`x-data`.

Interpolated values are the same rule arriving from the server, and Rails
already guards the ordinary case: `<%= value %>` inside `x-data` renders a
double quote as `&quot;`, and the HTML tokenizer never reads a character
reference as the closing quote — it decodes it straight into the value — so
the attribute survives. The vector is a value that SKIPS that escaping —
`raw`, `.html_safe`, or a helper returning a SafeBuffer — which puts a bare
`"` into the attribute and closes it exactly as a typed one would.
`escape_javascript` (`j`) is NOT the guard here: it escapes for a JavaScript
string literal (`\"`) and PRESERVES the html_safe flag, so the raw quote still
reaches the attribute. Let Rails escape it.

That settles the ATTRIBUTE, not the JavaScript inside it. A value spliced into
a single-quoted JS string — the shape rule 2 steers you to — has a second way
out: a `'`. ERB escapes it to `&#39;`, the parser decodes that straight back
into the value, and the bare `'` ends the string: the same
`Alpine Expression Error`. Route such a value through
`Studio::JsLiteral.in_attribute(value)`. It runs `escape_javascript` and
returns an UNMARKED String, so ERB's `<%= %>` does the HTML half on output —
both escapers, in the order that works, provided you never `raw` it; `lib/studio/js_literal.rb` carries the full contract, identifier
position (`Studio::JsIdentifier`) included.

These are properties of the HOST, not of any one card, and they apply to every
consumer partial an app registers — not only to the specimens in this gem.

They are recorded HERE because this is the host's CONTRACT, and nothing else
in the repo is. Plenty of files state one or both rules, but each of them is
describing ITSELF — a specimen header explaining its own markup, an asset
partial explaining its own root. Someone writing a NEW partial has no specimen
to read; they read the host's documentation, so that is where the rules have
to live.

And a specimen could not DEMONSTRATE rule 1 even in principle — many specimen
headers state it, but none can show it failing — which is what settles it: the style guide wraps EVERY registration's partial in a `<div>` of its own
— `<template x-if="…"><div><%= render … %></div></template>` — and that
wrapper supplies the single root the rule is about. A specimen that broke the
rule would still render correctly in the guide, so the specimens cannot
demonstrate the failure they would be documenting. Pinned by
`test/docs/modal_host_contract_docs_test.rb`.

#### Wallet modals moved to `solana-studio`

The Connect Wallet picker, the Web3 step-up card and the Phantom deep link used
to ship here as `studio/modals/wallet_connect`, `studio/modals/web3_step_up`
and `studio/solana/phantom_deeplink`. They now live in the **solana-studio**
gem as `solana_studio/modals/wallet_connect`, `solana_studio/modals/web3_step_up`
and `solana_studio/phantom_deeplink`; render them from those paths and read
that gem's README for their locals and hooks.

This is the two-template split: **BASE** is studio-engine + mcritchie-studio,
**WEB3 ADD** is solana-studio + turf-monster. The engine has no business
shipping wallet UI — as the call was made, *"the real op sec vector is managing
sessions safely. Anything wallet based should be in the app."*

What the engine **keeps** is the SESSION half of Solana sign-in:
`SolanaSessionsController`, `Solana::SessionAuth`, the `/auth/solana/nonce` and
`/auth/solana/verify` routes, the `solana_sessions/phantom_callback` view, and
`Studio.wallet_sign_in_statement` — the single source for the signed statement,
which the gem's deep link reads so the two cannot drift.

The callback view is also where a redirect-transport transaction waits while
the server cosigns and confirms, and it does not know what the user was doing.
The registered intent does, so the intent narrates: from its `complete()` it
dispatches `studio:wallet-progress` with `{ detail: { text: '…' } }`, and the
page writes that text into its status line. With nothing pushed the line reads
"Processing your wallet's response...", which names no wallet brand. On the
inline transport nothing listens, so the dispatch is a harmless no-op there.

#### The auth modal's credential slot

**This engine ships no sign-in card.** Each app owns its own and computes its
credential buttons itself: turf-monster's is `app/views/modals/_auth.html.erb`,
which is also the authority `lib/studio.rb` cites beside the Solana routes. The
engine's one auth card was the living style guide's MIRROR of turf's,
`style/modals/_auth`, and it was retired with the other mirrors on 2026-09-09
(PR #319). For sign-in the engine now ships fragments, not a card:
`studio/modals/shared/_email_field` and `studio/modals/auth/_resend_footer`,
each carded on the style guide.

**The wallet credential slot has no host today.** solana-studio still ships
`solana_studio/auth/_wallet_credential`, a Solana button written to be
*contributed* into a sign-in card rather than copied into one. The retired
mirror was its only renderer. Neither turf-monster nor mcritchie-studio names
the path; turf's card draws its wallet button directly. So bundling solana-studio
no longer puts a wallet button anywhere. Whether the engine should host the slot
again, or the convention should be retired, is an open call, not a fact this
README can settle.

**A card that does host it owns the gate.** The retired mirror's rules still
hold; they simply live in that app's view now. Two layers answer two different
questions, and they are not merged:

| Question | Answered by | Where it is decided |
|---|---|---|
| Is it **implemented**? | the picker is registered, **and** the credential partial resolves (`lookup_context.exists?`, the same three-term check as `modals/_host_extras`) | Ruby, in the hosting card — gates the render |
| Should it **show**? | `methodOn('wallet')`, falling back to `Studio.auth_method?(:wallet) && Studio.feature?(:web3)` | Alpine, inside the contributed partial — gates visibility |

Both terms of the Ruby gate are load-bearing, and they fail differently. Without
the **registration** term a layer that ships the credential but not the picker
draws a button that opens an empty panel — not hypothetical, solana-studio 0.5.2
shipped exactly that pair. Without the **existence** term a card whose picker
resolves but whose credential does not raises `Missing partial` in front of
someone signing in, instead of quietly rendering no button. Keep policy out of
the Ruby gate: folding `auth_method?(:wallet)` and `feature?(:web3)` into the
render deletes the button from the DOM, while an "or" divider that reads
`methodOn('wallet')` still draws above the gap.

The partial renders inside the hosting card's Alpine scope, so it may use
`methodOn(...)`, `attested()` (the legal-age gate — call it, or wallet becomes
the one credential that skips attestation) and `props.submitting`. It receives
one local, `modal_store`, the store backing that card's host. solana-studio's
own header for the partial still describes the engine as its renderer; that is
the same stale claim, one repo over.

**Name a store like a JavaScript identifier.** Partials splice this local in as a
bare name — `$store.<name>.current()` — rather than as a string, so a value
carrying a quote, a dot or a space is not a mangled store name: it is a
SyntaxError in the whole `x-data`, and Alpine mounts a component that renders
every element and does nothing. Escaping is not the repair (an escaped identifier
is a different SyntaxError); a name that matches `/\A[A-Za-z_$][A-Za-z0-9_$]*\z/`
is. `studio/modals/onboarding/_first_name` enforces exactly that and raises
`ArgumentError` on anything else, and every store-taking partial now does the
same through `Studio::JsIdentifier.validate!` — the shell, the blocks and the
templates alike. Note the shape decides the repair, not the
name of the local: `blocks/_birthday` passes `modal_store` in *string* position
(`store: '…'`) and correctly `escape_javascript`s it instead.

It also keeps two blocks the gem renders **by name** across the gem boundary:
`studio/modals/blocks/wallet_brand_sprite` and `studio/modals/blocks/card_header`.
Renaming either is a cross-repo change.

**Page-scoped hosts — `studio/modals/scoped_host`.** When a page must bring its
own modals (because not every consuming app renders a shared host, and the ones
that do register their own modal set), render a second host on its own Alpine
store:

```erb
<%= render "studio/modals/scoped_host", store: "emailModals" do %>
  <template x-if="$store.emailModals.current()?.id === 'crop-photo'">
    <%= render "studio/modals/crop_photo", store: "emailModals" %>
  </template>
<% end %>
```

`studio/modals/_crop_photo` and `_saving` take the same `store:` local, and
`imageUploadHost({ store: "emailModals", ... })` /
`submitFormWithProgress(form, { store: "emailModals" })` route through it — all
default to `"modals"`, so existing call sites are unchanged. The engine's
`/admin/emails` is the live example.

Two things that will bite you:

- **Render `scoped_host`, not `host`.** `scoped_host` mounts the page's modals
  on the page's OWN store, which is the point of a page-scoped host; `host` is
  the app's shared one. The path matters too: this is a non-isolated engine, so
  an app view at `app/views/studio/modals/_host.html.erb` would shadow the
  engine's. No consumer ships one today — mcritchie-studio and turf-monster
  deleted their forks on 2026-08-28 — but nothing stops the next app, and
  `scoped_host` has never been forked.
- **Guard registrations with `current()?.id`.** The outer template unmounts one
  tick *after* the stack empties, so a bare `.id` throws on every close.

The scoped host takes its animations from `engine-motion.css` rather than an
inline copy, so a consumer bundling that layer gets the same spring as the shared
host.

It carries the store API below with three deliberate differences: there is no
`advance()`; `swap()` replaces the top entry immediately rather than running the
shared host's directional slide — so no entry is ever left mid-transition; and it
does not read the `window.ModalAnimations` registry, so the `enterAnim` /
`exitAnim` props documented under the table are ignored and the exit always plays
the 220ms unmount from `engine-motion.css`. `isOpen` and `isLive` behave
identically on both.

Store API (`Alpine.store('modals')`):

| Call | Behavior |
|------|----------|
| `open(id, props, opts)` | Push a modal onto the stack. `opts.replace: true` swaps the top entry with a directional slide. |
| `swap(id, props, opts)` | Sugar for `open(id, props, { replace: true })`. `opts.direction: 'back'` mirrors the slide. |
| `advance(propsPatch, opts)` | Patch the current entry's props with the same directional slide, without replacing the stack entry — for steps inside one modal whose outer `x-data` scope must survive. |
| `close()` | Animated close of the current modal (no-op if already closing). |
| `closeAll()` | Instant, unanimated clear (used by navigation cleanup). |
| `closeAllDismissible()` | Clears all modals except those opened with `dismissible: false`. |
| `isOpen(id)` / `current()` | Introspection. `isOpen` is true while a card is ON THE STACK — including the whole exit animation, because `close()` flips `_closing` at once and splices only after it. |
| `isLive(id)` / `isLive([id, …])` | True when a card with that id is up and **not on its way out**. Pass an array to ask about a set of ids ("is any card of this flow still up?"). |

**`isOpen` or `isLive`?** A guard that means "don't open this twice" almost
always wants `isLive`. `isOpen` stays true for the ~220ms exit window, so an
idempotence check built on it refuses to reopen a card the user just dismissed.
The one asymmetry worth knowing: `advance()` slides the *same* card between
steps of its own flow and sets only `_swappingOut`, so a mid-advance card is
still **live** — only `close()` and the outgoing half of a `swap()` set
`_closing`. `isLive` tests `_closing` alone, deliberately; conflating it with
`_swappingOut` makes an in-flow hand-off look like a dismissal.

Recognized props: `dismissible: false` disables escape/click-outside dismissal
(e.g. an in-flight transaction); `enterAnim` / `exitAnim` pick a named
animation from the registry (`'pop'` default, `'shake'`, `'slide'`).

`window.ModalAnimations` is the animation registry — each key maps a CSS class
to its duration. To add a custom animation, define `window.ModalAnimations`
**before** the host renders with your extra keys (they merge over the engine
defaults) and ship the matching CSS class in the app stylesheet:

```html
<script>
  window.ModalAnimations = { enter: { wobble: { cls: 'my-modal-wobble', ms: 400 } } };
</script>
```

Prefer an inline script placed before the host render, as above. A module that
loads after the host (e.g. via importmap) and assigns `window.ModalAnimations`
**replaces** the merged registry rather than extending it — the host guards
against this (unknown keys and gutted registries fall back to the built-in
`'pop'`), but your other custom keys are lost unless the late script merges
into the existing object instead of assigning over it.

`window.StudioModals.CARD_WIDTHS` is the **card-width registry**, and it works
exactly like the animation one: define it **before** the host renders and your
entries merge over the engine defaults. Keys are modal ids, values are the
Tailwind `max-w-*` class that card should use. `DEFAULT_CARD_WIDTH` (default
`max-w-sm`) covers every id you don't name:

```html
<script>
  window.StudioModals = window.StudioModals || {};
  window.StudioModals.CARD_WIDTHS = { 'wallet-setup': 'max-w-md' };
</script>
```

By modal **id** rather than by prop on purpose: a card opened from several
places would have to carry the prop at every opener, and one miss renders the
same card at two widths depending on how the user got there. The width is
resolved inside `cardClasses()`, so the card element carries no static
`max-w-*` — don't add one, or the winner is left to stylesheet source order.

**App-wide registrations — `app/views/modals/_host_extras.html.erb`.** The
block above registers modals per *call site*. An app that renders the host from
more than one layout (a live one and, say, an `/admin` preview harness) would
have to repeat every registration in each. Define this optional partial instead
and the host renders it inside the card on **every** render path:

```erb
<%# app/views/modals/_host_extras.html.erb %>
<template x-if="$store.modals.current().id === 'cosign-rejected'">
  <%= render "modals/cosign_rejected" %>
</template>
```

It's a convention, not a local — an app that ships no such file renders nothing
and needs no call-site change. Use it for modals that belong to the *app*; keep
page-specific ones in the block where their call site can see them.

`window.StudioModals.holdAtLeast(ms)` returns a thenable that resolves no
sooner than `ms` after creation — stamp it when a processing view becomes
visible so fast operations don't flash the spinner.

**Behavioral deltas vs the previous engine host (0.12 and earlier).** The
store's API surface is a superset, but three behaviors changed, and a consumer
deleting its shadow copy inherits them — regression-test these paths rather
than assuming drop-in equivalence:

- `close()` is now **asynchronous**: the entry animates out and is spliced
  after its exit animation's registered duration (previously an immediate
  `pop()`).
- `close()` **no-ops while the current entry is already closing** — a double
  `close()` inside the animation window now pops ONE stacked entry, not two —
  and `close()` on an empty stack no longer runs `_sync()`.
- `open(id, props, { replace: true })` (and `swap()`) is now **asynchronous**:
  the replacement lands after the 220ms slide-out (previously an immediate
  top-of-stack assignment).

### Style guide — your app's own section

`/admin/style` is the engine's living style guide, and every section on it is
the engine's: Theme, Modals, Tricks, Tasks. An app grows a **fifth section, its
own**, by defining one partial:

```erb
<%# app/views/style/host/_modals.html.erb %>
<div class="card p-4 space-y-3">
  <p class="label-upper">Wallet setup</p>
  <button type="button" class="btn btn-primary btn-sm"
          @click="$store.modals.open('wallet-setup', { returnUrl: window.location.href })">
    Open
  </button>
</div>
```

That is the whole registration — the same optional-partial convention as
`modals/_host_extras`, resolved by the same three-term `lookup_context.exists?`.
An app that ships no such file gets no section, no heading, and no nav pill; its
page is byte-for-byte what it was.

**The gem keeps dictating the structure.** It renders the section element, the
`#host-modals` anchor, the heading (your `Studio.app_name`), the intro line, and
the sticky nav pill, and it places the section between Modals and Tricks. Your
partial supplies specimens only — no `<section>`, no `<h2>`, nothing to register
in a nav.

**Drive `$store.modals`, not `dsModals`.** The guide's own Modals section stands
up a page-scoped store because its specimens are the *engine's* ids, and pushing
an id your layout host has never registered opens that host onto an empty card.
Your own ids are already registered there, so
`$store.modals.open(id, props)` renders the **real** card, in production chrome,
with production behavior. There is nothing to mirror and no second registration
list to keep in sync — building one is the mistake this note exists to prevent.
This assumes your layout mounts the shared host. Not every consuming app does
(see "Page-scoped hosts" above); where none is mounted `$store.modals` is
undefined, so mount `studio/modals/host` before writing a trigger.

Full contract, including what the partial may assume: the doc comment at the top
of `app/views/style/_host.html.erb`.

### Navigation — `Studio.sidebar_sections` and `Studio.navbar_links`

Two seams, both empty by default, so the navbar is unchanged until an app opts in.

- `sidebar_sections` fills the slide-out link sidebar (the cog trigger in the icon
  rail). Rules: `lib/studio/sidebar_sections.rb`.
- `navbar_links` fills the navbar's own link slots: the desktop bar beside the
  logo and the phone row under it. Rules: `lib/studio/navbar_links.rb`.

```ruby
Studio.configure do |config|
  # An Array, or a callable receiving the view (so a badge can read current_user).
  config.navbar_links = ->(view) {
    [ { label: "Contests", href: view.contests_path, active: %r{\A/contests} },
      { label: "Rank", href: "/rank",
        badge: (view.logged_in? ? "##{view.current_user.rank}" : nil) } ]
  }
end
```

- `label:` and `href:` are required; both are escaped.
- `active:` is `true`/`false`, a Regexp, or a callable taking `request.path`.
  Omitted, a link is active when the path equals its href's path. The active
  link gets `aria-current="page"` and the primary tone.
- `badge:` is optional short text, such as `"#12"`, shown as a pill in the link.
- A bad entry raises `Studio::NavbarLinks::InvalidLink` naming its index: at
  assignment for a static Array, at render for a callable.

### Navbar identity — `Studio.navbar_user_name` and `Studio.sign_in_label`

Two words the navbar says about the viewer. Both defaults render the navbar
byte-identical to before, so an app that sets neither sees no change. Rules:
`lib/studio/navbar_identity.rb`.

```ruby
Studio.configure do |config|
  # The signed-in name in components/_user_nav. nil (the default) is display_name.
  config.navbar_user_name = :player_name                        # a method on the user
  # config.navbar_user_name = ->(user, view) { user.player_name } # or a callable

  # The signed-out button in layouts/_navbar and components/_user_nav, and the
  # sign-in wording on the engine's own auth pages (below).
  config.sign_in_label = "Sign in"                              # default "Log in"
end
```

- `navbar_user_name` is `nil`, a method name (Symbol or String), or a callable.
  A two-argument callable gets `(user, view)`; a one-argument callable gets the
  user alone.
- The name is always escaped, even when the method or callable returns an
  `html_safe` string.
- A method or callable that answers blank falls back to `display_name`. One
  that raises also falls back, and the error is reported once per process per
  error class (to `ErrorLog` when the app has it, else the Rails log), so a
  broken setting never 500s the layout.
- The engine has no I18n catalogue, so the label is plain config, not a locale
  key. A blank or non-String label, or a `navbar_user_name` of any other type,
  raises `Studio::NavbarIdentity::InvalidConfig` at assignment.
- The label also sets the sign-in words on the engine's own auth pages, so the
  navbar and `/login` never disagree. Rules: `lib/studio/auth_labels.rb`.

  | Where | `"Log in"` (default) | `"Sign in"` |
  |-------|----------------------|-------------|
  | `/login` prompt | Log in to continue | Sign in to continue |
  | `/login` password button | Log In | Sign In |
  | `/login` magic-link button | Send sign-in link | Send sign-in link |
  | `/login` SSO divider | or sign in below | or sign in below |
  | `/signup` link back to `/login` | Log in | Sign in |
  | Magic-link confirm page button | Sign in to *App* | Sign in to *App* |
  | Link-sent notice | …emailed you a sign-in link. | …emailed you a sign-in link. |

  The default reproduces the pages' earlier wording byte for byte, including the
  four places that already said "sign in". Any other label derives every form:
  `"Log on"` gives *Log On*, *Log on to continue*, *or log on below* and
  *log-on link*. The "Sign in with Google" and "Sign up" buttons are not
  sign-in labels and do not change.

### User nav slots

`components/_user_nav.html.erb` renders the right-side navbar user section.
Apps customize it through partial slots — each an optional local naming a
partial (String path, or `{ partial:, locals: }`):

- `balance_slot` — balance display at the start of the top row
- `extra_icons_slot` — app icon buttons before the admin gear + theme toggle
- `div2_slot` — replaces the default second row (wallet address + level bar)

```erb
<%= render "components/user_nav",
      balance_slot: "components/wallet_balance",
      div2_slot: { partial: "components/seeds_bar", locals: { compact: true } } %>
```

The legacy string locals (`balance_html`, `extra_icons_html`, `div2_html` —
pre-rendered HTML injected via `raw`) are deprecated but still honored when the
matching slot is absent, so existing call sites render unchanged.

## Transactional emails

Every consuming app can render the same admin page — **`/admin/emails`** —
listing each transactional email it sends with the banner riding at the top of
that email, and whether that banner is the **inherited default** or an
**app-owned override**.

**The page is opt-in:**

```ruby
# config/initializers/studio.rb
config.draw_admin_emails_routes = true
```

Off by default because `turf-monster` already owns `/admin/emails` and both of
its helper names; drawing them there raises at route-load and kills every route
in the app. The gate covers only the page — the registry and the inherited
defaults are always on.

### The image generator link

An app can put a link to its own banner generator at the top of the page: a
short line and a button that opens the generator in a new tab. Unset (the
default), nil or blank draws nothing, and the page renders exactly as it did
before the setting existed.

```ruby
# config/initializers/studio.rb
config.email_manager_generator_url = "https://example.com/email-art"
# or worked out per request; the callable receives the request:
config.email_manager_generator_url = ->(request) { "#{request.base_url}/admin/email-art" }

config.email_manager_generator_label       = "Header generator"   # default "Email image generator"
config.email_manager_generator_description = "Open it, copy the prompt, paste it into Claude Code."
```

The default line reads "Make a new header with <app name>'s character model:
open the generator, copy the prompt, paste it into Claude Code." The URL must be
an absolute `http`/`https` URL with a host: any other String (a `javascript:`
URL, a relative path) raises `ArgumentError` at boot, and a callable that
answers one draws no link. Every value is escaped.

### The catalog

A registered email carries a key, a label, a description, what **type** it is,
how to build a **live preview** of it, and its banner image. The engine
pre-registers the two every Studio app sends, so a new app inherits both without
declaring anything:

| Key | Label |
|-----|-------|
| `magic_link` | Magic-link sign-in |
| `newsletter_subscribed` | Newsletter subscribed |

A host adds its own workflows from an initializer, mirroring
`Studio::ModelPage.register`:

```ruby
# config/initializers/studio_emails.rb
Rails.application.config.to_prepare do
  Studio::EmailCatalog.register("winnings",
    label: "Contest winnings",
    description: "Sent when a player wins a contest.",
    type: :transactional,                                  # or :marketing
    preview: -> { ContestMailer.winnings(Entry.where.not(rank: nil).first) })

  Studio::EmailCatalog.register("wallet_export", label: "Wallet export")
end
```

Every keyword is optional, and omitting one on a re-register **keeps** the
existing value — attach a preview to an inherited email, or relabel it, without
restating its artwork. An unknown `type` falls back to `:transactional` rather
than raising.

> `Studio::EmailImage` is the old name for this module and still works as a
> delegating shim. It is deprecated; prefer `Studio::EmailCatalog`.

### Layered banners — a background image with live text on it

An email's banner can be a picture with the header, sub-text and logo rendered
as HTML **on top**, rather than drawn into the image:

```ruby
def magic_link(email, token)
  # The mailer supplies WHO the recipient is. What the banner SAYS about them —
  # the greeting, the sub-text, whether the name is used at all — belongs to the
  # operator, editable on /admin/emails. Pass a finished `header:` here and those
  # fields still accept edits no inbox ever sees.
  @banner = Studio::Banner.for(:magic_link, name: recipient_name(email))
  # ...
end
```

`layouts/branded_mailer` renders it. The engine's own `UserMailer#magic_link`
does exactly the above, and /admin/emails builds its preview from the same
`Studio::Banner.for` call — so preview and send cannot disagree.

A mailer that sets `@banner_url` instead still renders a plain `<img>` exactly
as before, and `Studio::Banner.for` returns `nil` when the app has registered no
layered artwork, so the flat path is what an unadopted app keeps getting —
layered is opt-in, never a migration.

Register the artwork once and every app inherits it:

```ruby
Studio::EmailCatalog.register("magic_link",
  background: "emails/magic-link-background.gif",
  logo: "emails/our-own-mark.png",   # a path THIS app ships — see below
  scrim: 0.40)
```

**A background is shareable; a logo is not.** Artwork rides the gem on purpose,
so a brand-new app sends good-looking mail on day one. A wordmark is somebody's
identity, so `logo:` must name a file **your app** ships. Two traps make getting
this wrong silent:

- **A logical path that your app does not ship resolves to the ENGINE's copy.**
  turf-monster registered `"emails/logo-horizontal.png"`, shipped no such file,
  and Sprockets served studio-engine's — its sign-in email went out carrying the
  McRITCHIE STUDIO wordmark. Nothing raised.
- **The alt text agrees with you, not with the pixels.** `Studio::Banner` sets it
  from `Studio.app_name`, so it reads as your app's name over whatever picture
  actually loaded.

`logo:` merges three ways: omitted or `nil` **inherits** whatever the entry
already had, `""` **clears** it, and a path **sets** it. So deleting a `logo: ""`
line does not remove the logo — it restores the inherited one.

**No `STANDARD` entry seeds a logo** — not `magic_link`, not
`newsletter_subscribed`, and not the next one added. A host that names no mark
sends no mark, and there is nothing to opt out of.

That is an invariant, not a coincidence: `test/lib/studio/email_catalog_test.rb`
reads `STANDARD` and fails on any entry carrying a logo, because this mechanism
was fixed three times as an instance before it was fixed as a rule. Artwork still
rides the gem, which is what gives a new app good-looking mail on day one.

**Adopting a mark** is one line, in an initializer or on `/admin/emails`:

```ruby
Studio::EmailCatalog.register("magic_link", logo: "emails/our-mark.png")
```

If you are **bumping this gem** ACROSS this change — that is, from any release
that still seeded the mark, which is **every version up to and including
0.47.0** — note what CHANGED rather than what to fear: `magic_link` used to seed
the Studio wordmark, so an app that registered no logo inherited it. If your app
WANTED that mark, it now has to name it — see the CHANGELOG entry, which lists
who that affects.

**Why layered rather than composited.** Drawing the text into the image gives
pixel-exact brand typography everywhere, but it cannot have an ANIMATED
background AND per-recipient text — composing a greeting into sixty frames means
a multi-megabyte GIF per recipient, per send. Layering separates them.

**What it costs.** Gmail and Outlook strip webfonts, so the heading falls back to
a system face rather than the brand font. In exchange the text survives blocked
images (Outlook desktop blocks by default), stays selectable, and nothing is
generated at send time.

**The scrim** is a wash between artwork and type, on by default at 0.40.
Background art is chosen to look good, not to guarantee contrast, and white text
over a pale sky cannot be read. Pass `scrim: 0` for artwork dark enough to carry
the type itself.

**The markup is deliberately old-fashioned.** Outlook on Windows renders through
Word and ignores `background-image`, so the picture is carried by the `<td
background>` attribute, by CSS, and by a VML block inside an `mso` conditional.
Remove any one of the three and a client loses the banner.

### Live preview

`preview:` is any callable returning a `Mail`. It powers `/admin/emails/:key`,
which renders the real email in an iframe from `/admin/emails/:key/raw`.

Builders run **only** on that page — listing the emails never executes one — and
every call is contained. A builder that raises yields no preview, records why,
and shows the reason in the frame. One broken builder costs one preview, not the
manager. That matters because a builder runs against whatever sample data an
environment happens to hold, which is exactly the thing that rots.

Re-registering an inherited key updates it in place and keeps its position, so
relabeling `magic_link` does not reorder the page or drop its default artwork.

### Resolution — inherit, then own

```
Studio::EmailCatalog.resolved_url(:magic_link)
  1. this app's ImageCache row  (its own S3 bucket)   -> uploaded here
  2. the registered default_asset                     -> a committed file
  3. nil                                              -> sends bannerless
```

`source(key)` says WHOSE the live banner is — `:app` (uploaded here, revertible),
`:app_asset` (registered by this app, committed in its repo), `:engine_default`
(the shared artwork in the gem), or `:none`. The origin is recorded when the
email is registered, because a resolved asset path looks identical either way by
the time the page asks. Passing `default_asset:` makes that artwork the host's;
relabelling an inherited email leaves it the engine's.

Note the method: **`resolved_url` walks all three layers; `url` returns only
layer 1** (this app's own image, or nil). That split is deliberate — it keeps
every caller written before the registry behaving exactly as it did. A mailer
that already falls back on its own, `url(:magic_link) || own_banner`, must stay
on `url`; moving it to `resolved_url` makes that fallback unreachable and swaps
the app's committed artwork for the engine's default.

Defaults **ride the gem** (`app/assets/images/emails/*`), so a brand-new app with
an empty bucket sends branded email on day one and needs no cross-app S3
permission. Uploading on an app's `/admin/emails` writes to **that** app's bucket
and **that** app's `image_caches` row — which is exactly "the asset now belongs
to this app". Every app has its own bucket and table, so an override never leaks
between apps.

Three accessors, and picking the wrong one changes what real people receive:

| Call | Returns | Use for |
|---|---|---|
| `url(key)` | this app's **own** image, or `nil` | the pre-registry contract; a host doing its own `\|\| fallback` |
| `resolved_url(key)` | own → inherited default → `nil`, **absolute** | mailers |
| `preview_url(key)` | own → inherited default (root-relative) | the admin page |

`url` deliberately does **not** resolve to the default. `turf-monster`'s mailer
reads `Studio::EmailCatalog.url(:magic_link) || email_banner_url("magic-link-banner.jpg")`
— making `url` resolve would turn that `||` into dead code and swap its committed
branded banner for the engine placeholder in live email.

```ruby
class UserMailer < ApplicationMailer
  layout "branded_mailer"

  def magic_link(email, token)
    @banner_url = Studio::EmailCatalog.resolved_url(:magic_link) # nil renders bannerless
    # ...
  end
end
```

Do **not** fork `layouts/branded_mailer.html.erb` — the engine's copy is
app-name-aware through `Studio.app_name`.

### Sharing a bucket — `s3_key_prefix`

Uploads need `Studio.s3_bucket_prefix`. A satellite app that has no bucket of its
own can share an existing one under its own key namespace:

```ruby
config.s3_bucket_prefix = "mcritchie-studio"
config.s3_key_prefix    = "mcritchie-industries/"
# -> s3://mcritchie-studio-dev/mcritchie-industries/email_banners/...
```

`Studio::S3` applies the prefix to every operation, so callers keep passing
logical keys and never see it. Unset (the default) leaves keys byte-identical to
what every already-shipped app wrote.

### S3-compatible storage (Cloudflare R2)

`Studio::S3` talks to any S3-compatible endpoint. The McRitchie fleet is moving
to R2 (one account, McRitchie Studio's); an app switches in its initializer:

```ruby
config.s3_endpoint          = ENV["R2_ENDPOINT"]   # https://<account>.r2.cloudflarestorage.com
config.s3_region            = "auto"
config.s3_access_key_id     = ENV["R2_ACCESS_KEY_ID"]
config.s3_secret_access_key = ENV["R2_SECRET_ACCESS_KEY"]
config.s3_public_url        = ENV["R2_PUBLIC_URL"] # custom domain on this env's bucket
```

All four are nil by default, and nil is AWS exactly as before. The keys must be
set as a pair. R2 serves nothing anonymously from its S3 endpoint, so with an
endpoint and no `s3_public_url`, `Studio::S3.url` raises `NotConfigured` and
`upload` writes but returns `nil`; serve private objects with `signed_url`.

`Studio::S3.delete` moves the object to `trash/` for three days rather than
deleting it; see [Trash and restore](#trash-and-restore).

An app with **no** bucket configured does not error — `/admin/emails` renders
read-only, showing the inherited defaults it is genuinely sending and naming the
one setting that turns uploads on.

### Linking it

Add it to the app's admin sidebar section:

```ruby
{ label: "Emails", href: admin_emails_path, emoji: "✉️", desc: "Transactional email banners" }
```

## Trash and restore

A delete through the engine is recoverable for three days. R2 has no object
versioning, so instead of deleting, the engine **moves** the object under
`trash/` in the same bucket, and a lifecycle rule on the bucket expires
`trash/` after three days:

```text
avatars/abc.png  ->  trash/2026-10-01/1759302000123/avatars/abc.png
                     trash/<UTC date>/<epoch ms>/<original key>
```

The copy goes first and the delete second. A copy that fails raises and the
delete is never sent, so a failure leaves the original in place. The trash copy
keeps the object's content type, cache headers and metadata, and adds
`original-key`, `deleted-at`, `deleted-env`, and what an Active Storage blob row
needs to be rebuilt (`blob-content-type`, `blob-byte-size`, `blob-checksum`
from a single-part ETag, and `blob-filename` when the upload carried a
Content-Disposition). A single CopyObject moves at most 5 GiB, so a larger
object raises `Studio::S3::Trash::TooLarge` and stays where it is.

`trash/` always sits at the bucket **root**, even for an app under a
`s3_key_prefix` in a shared bucket, so one lifecycle rule and one Cloudflare
rule cover every app in the bucket.

### What deletes, and what purges

| Call | Effect |
|------|--------|
| `Studio::S3.delete(key:)` | Moves to trash; returns the trash key (nil if nothing was there) |
| `Studio::S3.purge!(key:)` | Hard delete, gone at once |
| `Studio::S3.list` | Leaves `trash/` keys out; `include_trash: true` keeps them |
| Active Storage `service: StudioTrashS3`, `delete` | Moves the blob's object to trash (`Blob#purge`, a replaced attachment) |
| Active Storage `service: StudioTrashS3`, `delete_prefixed` | Hard delete: Active Storage calls it for `variants/<key>/`, which regenerate from the original |

**The production guard.** All four destructive paths refuse a bucket whose name
ends in `-production` when the process is not production, by `Studio::S3`'s own
resolution (`QA_ENV` first, so a QA app running Rails as production is NOT
production, then `Rails.env`). They raise
`Studio::S3::Trash::ProductionBucketRefused` before sending any request. The
guard reads the bucket NAME, so it protects only buckets that follow the
`<app>-production` convention.

### Set up the bucket (once per bucket, before an app adopts)

Without the lifecycle rule, trash never expires. In the Cloudflare dashboard:
R2 → the bucket → Settings → Object lifecycle rules → add a rule for prefix
`trash/` that deletes objects 3 days after upload. A trash copy is a new object,
so "uploaded" is the moment it was deleted. The same rule as S3 lifecycle JSON
(R2's S3 API and AWS both take it). `aws s3api
put-bucket-lifecycle-configuration` REPLACES the bucket's whole lifecycle
configuration, R2's default abort-incomplete-multipart rule included, so read
the current rules first (`get-bucket-lifecycle-configuration`) and send them
together with this one, or use the dashboard:

```json
{
  "Rules": [
    {
      "ID": "expire-trash-3d",
      "Status": "Enabled",
      "Filter": { "Prefix": "trash/" },
      "Expiration": { "Days": 3 }
    }
  ]
}
```

A public bucket also serves `trash/` from its custom domain unless it is
blocked, which would keep a "deleted" profile picture reachable by URL for three
days. Add a Cloudflare WAF custom rule on the zone, action **Block**:

```text
(http.host in {"assets.example.com"} and starts_with(http.request.uri.path, "/trash/"))
```

Name every `assets.<domain>` host the bucket answers on. If the bucket has the
`r2.dev` public URL enabled, turn it off; a WAF rule cannot cover it.

### Adopt it in an app

Active Storage: change the R2 service in `config/storage.yml` from `service: S3`
to `service: StudioTrashS3`. Every other key stays as it is:

```yaml
r2:
  service: StudioTrashS3
  bucket: my-app-production
  endpoint: <%= ENV["R2_ENDPOINT"] %>
  region: auto
  access_key_id: <%= ENV["R2_ACCESS_KEY_ID"] %>
  secret_access_key: <%= ENV["R2_SECRET_ACCESS_KEY"] %>
```

An app with its own S3 service subclass (turf-monster's
`ActiveStorage::Service::R2PublicService`) inherits from the trash service
instead:

```ruby
require "active_storage/service/studio_trash_s3_service"

module ActiveStorage
  class Service::R2PublicService < Service::StudioTrashS3Service
    # ...
  end
end
```

`Studio::S3` callers need no change: `delete` trashes from this release on. Call
`purge!` where an object truly has no value after deletion.

### Find and restore a deleted object

```bash
bin/rails "studio:trash:list"                      # everything in trash
bin/rails "studio:trash:list[avatars/abc.png]"     # one key's trash copies
bin/rails "studio:trash:restore[trash/2026-10-01/1759302000123/avatars/abc.png]"
```

Both read `Studio::S3`'s bucket. `SERVICE=<storage.yml service name>` reads an
Active Storage service's bucket instead, e.g. `SERVICE=r2`. A restore copies the
object back to its original key and leaves the trash copy for the lifecycle rule
to expire. It refuses to overwrite an object already at the original key unless
`FORCE=1`.

Restoring an Active Storage object restores its **bytes only**. The blob row was
destroyed before the object was trashed, so the task prints the
`ActiveStorage::Blob.create!(...)` to run, filled from the trash copy's metadata,
and the record must be re-attached by hand. `filename` is known only when the
upload carried a Content-Disposition; supply it otherwise.

## Remote image URLs

`Studio::ImageCache.validate_source_url!(url)` is the check to run before the
server fetches a URL someone else supplied. It returns the parsed URI or raises
`Studio::ImageCache::InvalidSourceURL`.

It refuses anything but `http`/`https`, and any host that is not public:

- **An address, however it is written.** Loopback, private (`10/8`,
  `172.16/12`, `192.168/16`), link-local (`169.254/16`, `fe80::/10`),
  unique-local (`fc00::/7`), carrier-grade NAT (`100.64/10`), unspecified,
  multicast and reserved ranges. IPv4 inside IPv6 (`[::ffff:127.0.0.1]`) is
  unwrapped. Numeric IPv4 is decoded as `inet_aton` decodes it (`127.1`,
  `2130706433`, `0x7f.1`, `017700000001`), and a numeric host that is not a
  plain dotted quad is refused whatever it decodes to.
- **An internal name.** `localhost`, `*.localhost`, `*.local`, `*.internal`,
  `*.lan`, with or without a trailing dot, in any case.
- **A name that resolves to a non-public address.** The hosts file is read,
  then every A and AAAA record; one non-public address refuses the URL. A name
  that cannot be resolved raises `UnresolvedSourceHost` (a subclass).

### The check and the fetch are two moments

A name can resolve differently a moment after it was checked. What that means
depends on who fetches:

| Who fetches | What to call | The gap |
|-------------|--------------|---------|
| The engine | `Studio::ImageCache.cache!`, `fetch_remote` or `fetch_response` | None. Each hop, redirects included, is vetted and the connection goes to the vetted address |
| Your own HTTP client | `vet_source_url!`, then `pinned_http` | None, when you connect through `pinned_http` and vet each redirect yourself |
| Your own client, by name | `validate_source_url!`, then a fetch of the URL | Open. The socket resolves the name again |
| A third party you hand the URL to | `validate_source_url!` | Open, and theirs to close. The check says where the name pointed for us |

```ruby
vetted = Studio::ImageCache.vet_source_url!(url)        # raises InvalidSourceURL
http   = Studio::ImageCache.pinned_http(vetted.uri, vetted.addresses.first)
http.start { |h| h.request(Net::HTTP::Get.new(vetted.uri.request_uri)) { |response| … } }
```

`pinned_http` keeps the name for the `Host` header and the TLS certificate, sets
the timeouts, and uses no proxy. It does not follow redirects: vet the
`Location` the same way before you request it.

### Tests, and choosing the resolver

Under `Rails.env.test?` the default is **no resolution**: names are judged on
their text, so a suite that passes `https://cdn.example.com/a.png` through the
guard needs no network and gets a stable answer. Addresses and internal names
are judged the same in every environment. To test what a name resolves to,
pass a resolver, a callable from a host to its addresses:

```ruby
Studio::ImageCache.validate_source_url!(url, resolver: ->(host) { ["10.0.0.5"] })   # raises
Studio::ImageCache.resolver = ->(host) { my_lookup(host) }                           # app-wide
```

`resolver: nil` on a call checks the text only.

## Overriding Views

This is a non-isolated engine -- app views at the same path automatically override engine views. For example, placing `app/views/sessions/new.html.erb` in the consuming app replaces the engine's login page.

## Releasing

Engine releases use semantic versions and are published to RubyGems. The full
checklist — split by whether you are building or conducting the release — lives
in [`docs/RELEASE.md`](./docs/RELEASE.md).

**Building an engine change?** Do **not** edit `lib/studio/version.rb`. The
release owns the version, and McRitchie Studio's `bin/dor-check` refuses any PR
that touches that file. Update [`CHANGELOG.md`](./CHANGELOG.md) under
`Unreleased` (that is *not* gated), run `bin/release-check --build`, and open
your PR into `accepted`. That is the whole of your part.

**Conducting the release?** Run `bin/release prepare` from mcritchie-studio and
let it allocate the version — it derives the bump, commits `lib/studio/version.rb`
with its `Gemfile.lock` onto **`origin/release`**, then publishes, tags, and bumps
each consumer's lock. **Do not set the version by hand.** A hand-set number makes
the allocation read the current version as already past the last tag and skip, so
the hand number silently wins over the derived one, and the skip rolls no
changelog. **When it allocates, `prepare` also rolls
[`CHANGELOG.md`](./CHANGELOG.md)** in the same commit: everything under
`## Unreleased` moves beneath the new version's heading, written even when the
bucket is empty, and `## Unreleased` stays first and empty. It refuses the sweep,
with nothing published, when the roll would lie or it cannot read the file.
[`docs/RELEASE.md`](./docs/RELEASE.md), *Rolling `Unreleased` into a version*,
says exactly when it rolls, refuses or skips, and what to do by hand.

**Semver guide** — the release *derives* the bump from its members (a `breaking`
risk tag → major, a `feature` → minor, otherwise patch), so this is what those
levels mean, not a menu to pick from:
- **PATCH**: bug fix; no API change. Consumers can update the gem with zero diff elsewhere.
- **MINOR**: backward-compatible feature add. Consumers may opt in to new APIs.
- **MAJOR**: breaking change. Consumers will need code changes alongside the tag bump.

## Local development (against an unreleased engine)

When iterating on engine code from a consumer app, point bundler at the local path so you don't need to push + tag for every edit:

```bash
# in the consumer app
bundle config set --local local.studio /Users/alex/projects/studio-engine
bundle install
# ... iterate in both repos ...
bundle config unset --local local.studio  # restore RubyGems resolution
```

For short local experiments, temporarily point a consumer Gemfile at `path: "../studio-engine"` and restore the RubyGems dependency before merging.

## Development Notes

Use the docs in [`docs/`](./docs) for engine setup, release, email transport,
and host-app contracts. Current cross-repo setup, ports, credentials, and
workflow guidance live in McRitchie Studio's
[`docs/agents/`](https://github.com/McRitchie-Studio/mcritchie-studio/tree/main/docs/agents).
