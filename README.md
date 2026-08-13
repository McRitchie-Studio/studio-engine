# Studio Engine

Shared Rails engine for McRitchie apps. Provides authentication, error handling, dynamic theming, and common concerns used by [McRitchie Studio](https://app.mcritchie.studio) and [Turf Monster](https://app.turfmonster.media).

> **Part of the McRitchie ecosystem** — see [`ECOSYSTEM.md`](https://github.com/McRitchie-Studio/mcritchie-studio/blob/main/docs/ECOSYSTEM.md) for the 5-repo map; [`house-burn-down.md`](https://github.com/McRitchie-Studio/mcritchie-studio/blob/main/docs/agents/system/house-burn-down.md) for fresh-Mac recovery.

## Installation

```ruby
# Gemfile — install from RubyGems (recommended)
gem "studio-engine", "~> 0.6"
```

Then `bundle install`. The current release is **v0.6.1**; see [`CHANGELOG.md`](./CHANGELOG.md) for the history.

> Published to RubyGems as of v0.4.0 (2026-05-17). New installs should use the RubyGems form, which the consumer Rails apps (`mcritchie-studio`, `turf-monster`) already use.

## What It Provides

- **Authentication**: Passwordless magic-link auth, optional password auth, Google OAuth via OmniAuth, Solana wallet sign-in, and optional one-way SSO patterns
- **Error handling**: `Studio::ErrorHandling` concern with `rescue_and_log`, `ErrorLog` model with `capture!`, error log viewer at `/error_logs`
- **Theme system**: Dynamic CSS custom properties generated from 7 role colors (primary, dark, light, success, accent, warning, danger). Dark/light mode toggle. Admin theme editor at `/admin/theme`.
- **UI primitives**: Shared component partials and CSS primitives such as `components/emoji_swap` for nav/sidebar emoji hover transitions.
- **Operator tooling**: Shared `studio/banners/environment` banner with Dev Mode + email connector controls, `studio/banners/impersonation`, and an opt-in `Studio::Impersonation` concern for Act As session conventions.
- **Sluggable concern**: `before_save :set_slug` with `to_param` for human-readable URLs
- **ThemeSetting model**: Per-app DB overrides with fallback to config defaults
- **Transactional emails**: `Studio::EmailCatalog` — every email an app sends, its type, a live preview, and its banner — plus the shared `/admin/emails` page. Every app inherits the standard emails and their artwork on day one, and can register its own workflows and upload its own banners. See [Transactional emails](#transactional-emails).

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

This draws the enabled auth routes (`/login`, `/signup`, `/logout`, `POST /magic_link` to request a link, `GET`/`POST /l/:token` for the link itself, Solana routes), OAuth callbacks, optional SSO routes, `/error_logs`, and `/admin/theme`. Magic-link emails point at the inert `GET /l/:token` confirmation page; the single-use token is burned only by the CSRF-protected `POST` to `link_consume_path`.

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

The engine also provides an optional `Studio::Impersonation` concern for the
session convention:

```ruby
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
  include Studio::Impersonation
end
```

The concern adds `true_user`, `impersonated_user`, `impersonating?`,
`start_impersonation_session(target_user, actor:)`, and
`clear_impersonation_session`. Consumer apps still own the authorization rule,
audit log, enter/exit controller actions, and any app-specific safeguards such
as binding session-token checks to `true_user` or disabling wallet-only
privileges while impersonating.

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

- **Render `scoped_host`, not `host`.** This is a non-isolated engine, so an app
  view at the same path shadows the engine's — and `mcritchie-studio` and
  `turf-monster` both ship their own `app/views/studio/modals/_host.html.erb`.
  A page rendering `studio/modals/host` in those apps silently gets the app's
  fork. `scoped_host` is unforked everywhere.
- **Guard registrations with `current()?.id`.** The outer template unmounts one
  tick *after* the stack empties, so a bare `.id` throws on every close.

The scoped host takes its animations from `engine-motion.css` rather than an
inline copy, so a consumer bundling that layer gets the same spring as the shared
host.

Store API (`Alpine.store('modals')`):

| Call | Behavior |
|------|----------|
| `open(id, props, opts)` | Push a modal onto the stack. `opts.replace: true` swaps the top entry with a directional slide. |
| `swap(id, props, opts)` | Sugar for `open(id, props, { replace: true })`. `opts.direction: 'back'` mirrors the slide. |
| `advance(propsPatch, opts)` | Patch the current entry's props with the same directional slide, without replacing the stack entry — for steps inside one modal whose outer `x-data` scope must survive. |
| `close()` | Animated close of the current modal (no-op if already closing). |
| `closeAll()` | Instant, unanimated clear (used by navigation cleanup). |
| `closeAllDismissible()` | Clears all modals except those opened with `dismissible: false`. |
| `isOpen(id)` / `current()` | Introspection. |

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
**app-owned override**. Supersedes the old `/admin/email_images`, which is
deprecated but still renders for one release.

**The page is opt-in:**

```ruby
# config/initializers/studio.rb
config.draw_admin_emails_routes = true
```

Off by default because `turf-monster` already owns `/admin/emails` and both of
its helper names; drawing them there raises at route-load and kills every route
in the app. The gate covers only the page — the registry and the inherited
defaults are always on.

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
  logo: "emails/logo-horizontal.png",
  scrim: 0.40)
```

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

An app with **no** bucket configured does not error — `/admin/emails` renders
read-only, showing the inherited defaults it is genuinely sending and naming the
one setting that turns uploads on.

### Linking it

Add it to the app's admin sidebar section:

```ruby
{ label: "Emails", href: admin_emails_path, emoji: "✉️", desc: "Transactional email banners" }
```

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

**Conducting the release?** Commit the computed version — with `Gemfile.lock`,
which pins the engine's own path-gem version — directly onto `accepted`, then
run `bin/release prepare` from mcritchie-studio; it publishes, tags, and bumps
each consumer's lock. Details and the exact commands are in
[`docs/RELEASE.md`](./docs/RELEASE.md).

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
