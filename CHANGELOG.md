# Changelog

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) — `MAJOR.MINOR.PATCH`. Consumer Rails apps install the released RubyGems package with `gem "studio-engine", "~> 0.6"`; bumping the gem version and updating consumer lockfiles is a release.

## 0.39.0 — 2026-08-11

### Removed

- **`--studio-bars-h` is gone.** 0.33 advertised this CSS custom property as the
  contract between the bar stack and a consumer's navbar, and the navbar's
  sticky `top` read it. It no longer exists: the stack now sits in normal flow
  directly above the navbar and simply occupies its own height, so a navbar
  sticky at `top: 0` starts underneath the bars with nothing to compute.

  **No consumer breaks.** A navbar still spelling `top: var(--studio-bars-h,
  0px)` resolves to its `0px` fallback — exactly where the new layout wants it —
  so an adopting app self-heals with no change. Verified against
  `mcritchie-studio` (which carries that spelling) and `turf-monster` (which
  never adopted the stack).

### Fixed

- **The navbar no longer jumps on load or navigation.** The removed property was
  published twice and the two publishers could disagree: the server rendered an
  ESTIMATE (bar count × a fixed unit) and a `ResizeObserver` then MEASURED the
  real height and overwrote it. The header painted at the estimate and moved
  when the measurement landed, moved again whenever a webfont changed a bar's
  real height, and during a view transition the outgoing and incoming headers
  composited at two different tops — so the navbar visibly drew twice. A
  position only CSS can set cannot disagree with itself.

  The estimate, the `ResizeObserver`, and the inline `<style>`/`<script>` the
  stack used to emit are all gone. Reported from QA by the operator.

  **Trade, recorded deliberately:** the bars now scroll away rather than
  pinning. Two pinned siblings of unknown height cannot stack in CSS alone —
  one must measure the other, and that measurement *is* the defect.

## 0.38.0 — 2026-08-10

**The email registry becomes the email catalog.** 0.37 gave every app a shared
page for its transactional email banners. This folds in the rest — **what each
email is, and what it actually looks like** — so an app has ONE email manager
instead of two.

**`Studio::EmailImage` is now `Studio::EmailCatalog`.** The old name is a
**delegating shim** with its full surface intact (`url`, `store`, `record`,
`register`, `label`, `known?`, `variants`, `resolved_url`, `preview_url`,
`source`, and the constants), so nothing that names it breaks. It is deprecated
and will be deleted once no consumer's `main` references it.

Named for the prior art it absorbs: `turf-monster` built `::EmailCatalog` +
`Admin::EmailsController` first, and left a note on both saying this manager
*"moves into the shared studio-engine email framework (Phase 2)"*. This is
Phase 2. turf-monster deletes its copy in its adoption task rather than running a
second email page.

**Registry entries carry a type and a preview builder:**

```ruby
Studio::EmailCatalog.register("winnings",
  label: "Contest winnings",
  description: "Sent when a player wins a contest.",
  type: :marketing,                                   # or :transactional (default)
  preview: -> { ContestMailer.winnings(sample_entry) })
```

Every keyword is optional, and omitting one on a re-register **keeps** the
existing value — so a host can attach a preview to an inherited email, or
relabel it, without restating its artwork. An unknown `type` falls back to
`:transactional` rather than raising: a typo in an initializer must not take a
host's boot down over a badge.

**New: `/admin/emails/:key`** — one email's own page: its banner, its type, its
subject, and a **live preview** of the real rendered email in an iframe
(`/admin/emails/:key/raw`). The emails list links each row to it.

**A preview can never take the manager down.** A `preview:` builder is host code
run against whatever sample data an environment happens to hold — an empty table,
a moved fixture, a mailer whose signature changed. Every call is contained: a
raising builder yields `nil`, records why, and renders the reason inside the
iframe. One broken builder costs one preview, not the page. Builders run **only**
on that page — listing the emails never executes one.

**Consumer note.** Nothing is required to upgrade; the shim keeps 0.37 call sites
working. To adopt the preview: pass `preview:` when registering, and switch any
`Studio::EmailImage` reference to `Studio::EmailCatalog`.

### Added

- **`Studio::EmailCatalog`** — the email registry, renamed from
  `Studio::EmailImage` and now carrying each entry's `type:` and `preview:`
  callable. The old name stays as a delegating shim.
- **`/admin/emails/:key`** — one email's own page: its banner, its type, its
  subject, and a live preview of the real rendered email in an iframe.

## 0.37.0 — 2026-08-10

### Added
- Standard transactional email primitive with a registry-backed catalog.

### Fixed
- The crop confirm is guarded by owner, so one confirmed crop can no longer fan out
  and overwrite every row's banner on /admin/emails.

## 0.36.0 — 2026-08-10

**Transactional emails become an engine primitive.** Every consuming app now
ships working, branded transactional email the moment it boots, and can grow its
own workflows and artwork. Additive — no host change is required to take this
release.

**`Studio::EmailImage` is now a registry.** It was a one-entry `VARIANTS` hash;
it is now a host-declared registry following the `Studio::ModelPage.register`
precedent. A registered email is mostly symbolic of a workflow — a key, a label,
a description — and its only real asset is its banner image.

- The engine **pre-registers the two every Studio app sends**, `magic_link` and
  `email_change_confirmation`, so a host inherits both without declaring
  anything.
- A host registers its own from an initializer:
  `Studio::EmailImage.register("winnings", label: "Contest winnings")`.
  Re-registering an inherited key **updates it in place**, keeping its page
  position and its inherited artwork.
- `variants`, `label`, `known?`, `record`, `url`, and `store` keep their old
  shapes, so `Studio::EmailImage.url(:magic_link)` — the only external caller
  today — is untouched.

**Inheritance with per-app override.** Resolution is now two-layered:

```
resolved_url(:magic_link)  ->  this app's ImageCache row (its own S3 bucket)  app-owned
                           ->  the engine's default gem asset                 inherited
                           ->  nil                                            bannerless
```

`resolved_url`, **not** `url`. `url` deliberately keeps its pre-registry meaning —
this app's own image, or nil — so a caller written before the registry keeps the
behavior it was built against. A mailer that falls back itself
(`url(...) || own_banner`) must stay on `url`; switching it to `resolved_url`
would make that fallback dead code and replace the app's own artwork with the
engine default.

Defaults **ride the gem** (`app/assets/images/emails/*`), so a brand-new app with
an empty bucket sends good-looking email on day one with no cross-app S3
permission. Uploading writes to that app's own bucket and its own `image_caches`
row — which is exactly "the asset now belongs to this app". Placeholder artwork
ships for both standard emails; real artwork lands in a later release.

**New: `/admin/emails`**, modelled on the living style guide — one shared engine
page, admin-gated, rendering inside each host's layout.

**It is OPT-IN, and must be.** Add to `config/initializers/studio.rb`:

```ruby
config.draw_admin_emails_routes = true
```

`turf-monster` already owns `/admin/emails` (its `EmailCatalog` manager:
`namespace :admin { get "emails", as: :emails }`) and therefore both helper
names, `admin_emails_path` and `admin_email_path`. Drawing the engine's page
unconditionally raises `ArgumentError: Invalid route name, already in use:
'admin_emails'` *while turf-monster's own routes are loading*, which takes down
its **entire** route set — every `admin_*_path` in the app goes undefined. A host
cannot opt out of a failure that happens before its config is read, so the
default is off until no consumer owns the name.

The gate covers only the **page**. The registry and the inherited-default
resolution are always on, and the engine's `UserMailer` already calls
`resolved_url`, so an app sends branded email whether or not it draws the page.

**`/admin/email_images` is deprecated, not deleted.** It still renders, and its
`admin_email_images_path` / `admin_email_image_path` helpers still resolve —
`mcritchie-studio` and `turf-monster` both have tests on `main` that drive it,
and consumer CI runs each consumer's default branch. A later engine minor deletes
the controller, view, and routes once no consumer references them. In the
meantime the old page had its own reporting bug fixed too: it now reads
`preview_url`, so it no longer claims "No image yet" about an email that is
visibly sending one.

- The table is the primary view: **name + live image on every row**, so an email
  is identifiable at a glance.
- Each row says whether the live image is the **inherited default** or
  **app-owned**, and an app-owned image can be reverted back to the default.
- Uploading goes through the **standard crop modal**, not a bare file input.

**Fix — the page misreported what was actually shipping.** It read only the S3
override, so it announced *"No image yet — emails send without a banner until you
upload one"* for an email that was visibly sending a banner from a committed repo
asset. `current_url` now resolves what really ships, and the copy distinguishes
"inherited default" from "no image at all".

**New: `Studio.s3_key_prefix`** — an optional key namespace inside the bucket, so
a satellite app can share an already-provisioned bucket instead of standing up
its own pair:

```ruby
config.s3_bucket_prefix = "mcritchie-studio"
config.s3_key_prefix    = "mcritchie-industries/"
# -> s3://mcritchie-studio-dev/mcritchie-industries/email_banners/...
```

`Studio::S3` applies it to `upload`, `download`, `url`, `signed_url`, `exists?`,
`delete`, and `list` — callers keep passing logical keys and never see it, and
`list` strips it back off so a result feeds straight into `download`/`url`.
**Unset by default, so every already-shipped app's keys are byte-identical.**
Also new: `Studio::S3.configured?`, for callers that must degrade rather than
rescue `NotConfigured`.

**Honest degradation.** An app whose host never set `s3_bucket_prefix` renders
`/admin/emails` **read-only** — showing the inherited defaults it is genuinely
sending, naming the one setting that turns uploads on — instead of 500ing on the
first upload.

**New partial: `studio/modals/scoped_host`** — a self-contained modal host on its
own Alpine store, for a page that must bring its own modals. `/admin/emails` uses
it (`store: "emailModals"`) to ship its crop + saving modals, so the page works
identically in an app that renders a shared modal host and one that renders none
at all. `imageUploadHost` and `submitFormWithProgress` gained a matching `store`
option (default `"modals"`, so existing call sites are unchanged); the crop-photo
and saving partials already had one.

It is a **separate partial rather than a local on `studio/modals/_host`** for a
reason worth knowing: this is a non-isolated engine, so an app view at the same
path shadows the engine's — and `mcritchie-studio` and `turf-monster` both ship
their own `app/views/studio/modals/_host.html.erb`. A page rendering
`studio/modals/host` in those apps silently gets the app's fork, which knows
nothing of a `store:` local, so the page-scoped store is never registered and
every modal trigger on the page does nothing. `scoped_host` is unforked in every
app. The living style guide's hand-rolled `dsModals` host can rebase onto it.

Register modals with `current()?.id`, not `current().id` — the outer template
unmounts one tick after the stack empties, so a bare `.id` throws on close.

**Compatibility.** `Studio::EmailImage.url(key)` keeps its **pre-registry
contract** — this app's own uploaded image, or `nil`. The two-layer resolution
lives in the new `resolved_url(key)`. This matters: `turf-monster`'s mailer is
`Studio::EmailImage.url(:magic_link) || email_banner_url("magic-link-banner.jpg")`,
and making `url` resolve to the engine default would have turned that `||` into
dead code and silently replaced turf-monster's committed branded banner with the
engine's **placeholder** in live sign-in email. A method whose signature is
unchanged but whose return value flips from `nil` to a value is not additive.

**Consumer note.** Nothing here is required to upgrade. To adopt: set
`config.draw_admin_emails_routes = true`, link `admin_emails_path` from the app's
admin sidebar, register any extra workflows, switch mailers from `url` to
`resolved_url` where you want the inherited default, and drop any local
`branded_mailer.html.erb` fork — the engine's copy is app-name-aware through
`Studio.app_name`.

**The local-review link now signs the reviewer in as someone who can SEE the
page.** `/_studio/local_review` — the local half of the task board's WAITING
APPROVAL button — provisions the account before it mints, at the new
`Studio.local_review_role` (default `"admin"`).

The board hands this endpoint the operator's **production** email address. A
fresh worktree database has never seen it, so consuming the link took
`Studio::LinkConsumption#sign_up_new` and created the account at the default
role, `viewer`. `require_admin` on the page under review then redirected it to
`/`. The sign-in **succeeded** every time, which is what kept this quiet: the
button worked, the token was valid, and the operator simply arrived on the home
page having never seen the thing he was asked to review. A seeded admin
(`alex@mcritchie.studio`) worked fine, so only his real address ever hit it.

The endpoint now find-or-creates the reviewer and ensures the role BEFORE
minting, so the consume takes `sign_in_existing` onto an account that already
has rights. An existing account is promoted, never duplicated; an already-correct
one is not rewritten.

New public config:

```ruby
Studio.configure do |config|
  config.local_review_role = "admin" # default; nil provisions without a role
end
```

Set it to `nil` for an app whose review pages are not admin-gated — the account
is still provisioned (that is what avoids `sign_up_new`), but its role is left
to the host's own `configure_new_user`.

**The endpoint also answers "who is sitting at this desk?" when the caller names
nobody.** `?email=` is now optional, and an explicit one still wins. With none,
the reviewer resolves to `Studio.local_review_email`, and failing that to the
**first user already holding `Studio.local_review_role`, by id** (that query
falls back to `"admin"` when the setting is `nil`):

```ruby
config.local_review_email = "someone@example.com" # nil (default) = derive
```

This exists so the board's WAITING APPROVAL CTA can be a **public, sign-in-free
redirect**. Requiring a board session to click it is what broke one-click review
in the first place; sending an email in that public URL would publish the
operator's address. The local stack is the machine the reviewer is sitting at,
so it is the right place to decide. A desk with nobody at that role mints
nothing and says so, rather than guessing: the derive only ever picks someone
who ALREADY holds the role, so it never promotes a stranger into it. (The
`?email=` path does promote the account it is handed — that is the point of it.)

**The floor is unchanged, and now asserted rather than assumed.** The endpoint
grants a role, so both gates in front of it are tested directly: the
developer-desk routes are drawn only outside production (proved by drawing
`Studio.routes` into a throwaway route set under a production env), and a
non-loopback request 404s **before** provisioning or minting anything.
Provisioning is best-effort: a host whose `User` rejects the write gets a logged
warning and a working link, never a 500.

### Added

- **`Studio.local_review_role`** — the role `/_studio/local_review` stamps on the
  account it provisions before minting. Defaults to `"admin"`; `nil` provisions
  the account without touching its role.
- **`Studio.local_review_email`** — who the local-review mint signs in when the
  caller sends no `?email=`. `nil` (the default) derives the first admin in this
  database, by id.

## 0.33.0 — 2026-08-10

Two changes ship together in this release: local log files are now capped, and
the pinned bars above the navbar become a composable **stack** that sits beside
the navbar rather than inside it.

**Local log files are now capped — 16 MB development, 8 MB test.** New
`studio.logger` initializer. Nothing to install, run, or remember: it rides the
gem, so every app, every future app, every worktree, and a freshly rebuilt Mac
all get it by construction.

Rails' own default is the reason this was needed. `config.load_defaults "7.1"`
sets `log_file_size` to **100 MB** for development *and* test, and each keeps one
rotated sibling — up to ~400 MB of log per checkout, times every worktree on the
machine. The logs were never unbounded; the ceiling was just far too high for a
machine that carries many desks. New ceiling: ~48 MB per checkout.

**Production is untouched.** The cap applies only where `Rails.env.local?`, so
every `production.rb` that hands its stream to STDOUT keeps doing exactly that,
and a host that names its own `config.logger` is never overridden.

**Ordering is the load-bearing part of this change.** Rails' `:initialize_logger`
is a *bootstrap* initializer — it runs before every railtie and engine
initializer and does `Rails.logger ||= config.logger || <default>`. An engine
that assigns `app.config.logger` from an ordinary initializer is therefore a
silent no-op: Rails has already built the logger. So `studio.logger` declares
`before: :initialize_logger` and sets `config.log_file_size`, the knob Rails
itself reads one moment later, leaving Rails owning the path, formatter, level,
and tagging. `after: :load_environment_hook` pins the other edge of the window,
which also keeps Railtie's implicit initializer chaining from dragging
`studio.assets` forward.

`test/integration/log_rotation_test.rb` asserts the **behavior**, not the
config: it boots real Rails apps and checks that the log file actually rotates
on disk once it passes the cap. It carries a mutation control — the same 17 MB
log with the cap switched off must *not* rotate — so the suite cannot be
satisfied by Rails' 100 MB default. Dropping the `before:` ordering reds it.

**New setting — `Studio.local_log_max_bytes`.** `false` opts out; an Integer
sets your own cap. Unlike every other `Studio.*` setting, it must be set in
`config/application.rb` (after `require "studio"`) or `config/environments/*.rb`
— `config/initializers/studio.rb` loads too late to be read.

---

**The environment banner is now the navbar's SIBLING, not its child, and the
navbar sizes itself to whatever bars are actually there.** Nesting the banner
inside the navbar coupled two unrelated components: every new bar meant editing
the navbar, and there is already a second bar (impersonation), so this was never
a 0-or-1 problem.

Render the stack immediately before the navbar:

```erb
<%= render "studio/banners/stack" %>
<%= render "layouts/navbar" %>
```

The bars do not know the navbar exists; the navbar does not know which bars
rendered — only how tall they are, via `--studio-bars-h`.

**The height is MEASURED, not assumed.** A `ResizeObserver` on the stack
publishes its real height, so a bar that needs to be taller, a second bar, or one
that wraps on a narrow screen all work with **no change to any consuming app**.
A server-rendered estimate paints first so the common case never flashes, then the
observer replaces it with the truth. Verified in a real browser: growing the bar
32px moved the stack, the published property and the header's `top` together, on
the same frame.

**Backward-compatible.** An app that renders no stack gets
`var(--studio-bars-h, 0px)` — identical to the old `top-0`. Adoption is opt-in.

### Added

- **`studio/banners/stack`** — renders whichever bars apply (environment via
  `Studio.show_environment_banner?`, impersonation when the host passes
  `impersonated_user` / `admin_user` / `stop_path`) and publishes their measured
  height. Takes `preview:` and forwards `devnet:` / `extra:` to the environment bar.
  A preview render emits nothing at all, so a navbar-preview copy cannot duplicate
  live chrome or publish a height.
- **`Studio.local_log_max_bytes`** — the opt-out (`false`) or override (an
  Integer) for the new local log cap. Set it in `config/application.rb` or
  `config/environments/*.rb`, never `config/initializers/studio.rb`.

### Changed

- **The navbar's sticky `top` reads `--studio-bars-h`** instead of hardcoding
  `top-0`. It never branches on which bars rendered.
- **Banners are branded off the app's own theme tokens** — the environment bar
  derives from `--color-warning` and impersonation from `--color-danger`, each
  under a translucent gradient wash, replacing hardcoded hex stops. An app that
  retunes its theme now gets a banner that follows it.
- **Local `development` and `test` logs rotate at 16 MB / 8 MB** via the new
  `studio.logger` initializer, down from Rails' 100 MB default. Production is
  untouched.

## 0.32.3 — 2026-08-09

**New public CSS custom property: `--nav-bottom`.** `_head.html.erb` now
publishes the page header's **bottom edge** in viewport coordinates alongside
the existing `--nav-h`, which stays the header's **height**. Use them for
different jobs:

- `var(--nav-h)` — to size something as tall as the header.
- `var(--nav-bottom)` — to **start** something underneath it.

They are equal only when the header sits at the top of the viewport, which is
why one was long used for the other. An app that renders chrome **above** the
navbar — an environment banner before the `<header>` — pushes the header down,
and a `fixed` overlay offset by `--nav-h` then rides up over the header by
exactly the height of that chrome.

**Fix — `components/_sidebar_panel` offsets from `--nav-bottom`.** The open
sidebar panel overlapped the header by 47px on `mcritchie-industries`, covering
the Log in button. Falls back to `var(--nav-h)` (then `6rem`), so a host that
overrides `layouts/studio/_head` keeps today's geometry rather than collapsing.
**No change for a consumer whose header already starts at the viewport top** —
the two values converge there.

Unlike `--nav-h`, `--nav-bottom` is **scroll-dependent**: chrome above the
header scrolls away while a panel is open, and nothing locks body scroll. It
republishes on a passive `scroll` listener behind a `requestAnimationFrame`
throttle, bound once at script eval rather than per Turbo visit. A page with no
`<header>` now releases the observed node, so a Turbo visit to a headerless page
can no longer publish an all-zero rect from a detached element.

**Note for hosts that override `components/_sidebar_panel`** — an app copy of
that partial shadows the engine's, so it keeps the old `top:var(--nav-h, 6rem)`
until updated. `mcritchie-studio` and `turf-monster` both carry such an override.

## 0.32.2 — 2026-08-09

**Two public-page navigation fixes** (found by the industries sidebar-adoption
review on the app's one public page): `components/_admin_dropdown` now renders
only for `admin?` viewers — it used to offer `/admin/theme` and `/error_logs`
links to signed-out strangers wherever the navbar mounted it; and
`components/_link_sidebar_trigger` no longer hardcodes `inline-flex` after the
caller's `class_name`, which beat `hidden md:inline-flex` in the cascade and
rendered the desktop trigger on mobile beside the real one. Callers now own
the display class (bare renders default to `inline-flex`). Regression view
tests pin both.

## 0.32.1 — 2026-08-09

**Setup-guide corrections.** Docs only — no code, no behavior change.

### Docs

- **`NEW_APP_SETUP.md` § 15 "Lint And CI" — the two things a fresh app gets wrong
  by default.** Both surface as a red CI lane on the app's first push and both
  read like code defects when they aren't.

  *Lint:* the generated `.rubocop.yml` inherits `rubocop-rails-omakase`, which
  enforces `[ a, b ]`, while scaffolded code routinely writes `[a, b]` — so a new
  app is usually born with a red `lint` lane. Run `bin/rubocop -a` before the
  first commit, and either format to the cop or disable it deliberately. The
  section tabulates which apps did which, stamped with the `origin/main` ref it
  was surveyed at; that table lives in the guide rather than here because
  `studio-engine.gemspec:21` packages this CHANGELOG but excludes `docs/`, so the
  guide can be corrected without an erratum and this file cannot.

  *CI:* the generated workflow installs a short fixed list and nothing else, so an
  app that shells out to any other binary must add it to the install step in EVERY
  test-running job. How many jobs that is depends on your Rails version — 8.1
  generates separate `test` and `system-test` jobs with separate install steps,
  7.2 a single job running both suites — and the guide tabulates both. The
  failure is misleading: the test raises inside its own setup, so the lane reads
  as a code defect rather than a missing package. moms-app's `BookStitcher` shells
  out to `ffmpeg`, its README had listed `ffmpeg` as a requirement all along, and
  the requirement was simply never told to CI.
- **`NEW_APP_SETUP.md` § 15 also covers the system-test lane that tests nothing.**
  `rails new` wires a `test:system` CI invocation and the capybara/selenium gems,
  and what you get behind it depends on your Rails version. On **7.2**
  (`app_generator.rb:254-258`, called at `:459` under `depends_on_system_test?` —
  true for a plain `rails new`) `test/system/.keep` and
  `application_system_test_case.rb` are created, so the lane
  runs, finds zero tests, and reports **GREEN** — a pass that means nothing. On
  **8.1** (`:257-262`) that scaffolding sits behind a
  `devcontainer? && depends_on_system_test?` guard, so a plain `rails new` gets the
  invocation without the directory and the lane goes **RED** on
  `cannot load such file -- test/system`. Either way the lane is not testing your
  app; the green one is the harder to notice. The section tabulates where each
  house app actually stands.
- **§ 16 Verify** no longer asks you to confirm a "yellow Development Environment
  bar" — that hand-rolled strip was replaced by the shared environment banner in
  0.30.0, so the checklist now names the banner, DEV MODE, and the Local Inbox link.


## 0.32.0 — 2026-08-09

**Readable ink on every theme, and the `btn-primary` label joins the token
contract.** (The token work merged after 0.31.0 was cut, so both land here.)

Dark- and light-mode `--color-text-muted` / `--color-text-secondary` no longer
hardcode slate grays: they derive from the theme base by a bounded contrast
search (`ColorScale.contrast_ratio` is new public API) that walks the blend
until the ink clears 3:1 / 4.5:1 on every emitted background — for any
operator-picked base, not just the fleet's. Fixed grays measured as low as
2.05:1 on themed surfaces.

Consumers can now also set `--btn-primary-fg` (and `--btn-primary-fg-hover`
for the darker hover fill) on `:root` exactly like the existing
`--btn-secondary-*` tokens; a light brand primary (McRitchie Industries'
furnace orange) fails WCAG under the hardcoded white label. Defaults resolve
to the same white as before, so tokenless consumers are unchanged.

## 0.31.0 — 2026-08-08

**One magic-link token format, one door, and a click that stops breaking your
session.** Two operator-reported faults, one root: the engine shipped two
magic-link stores side by side, and the legacy one could not support the
behavior the other needed.

The links themselves were the visible half — a `:signed` app mailed a
~350-character `MessageVerifier` blob at `/magic_link/<token>`, wrapping four
lines of an email. The invisible half was worse: **clicking a link a second time
dumped a signed-in visitor on the login page.** Their cookie survived, but the
destination said otherwise, and the destination is what people believe. Every
dead token — used, expired, or unrecognized — funnelled into the same
`redirect_to login_path, alert:` no matter who was holding a session.

Fixing the second required retiring the first. An EXPIRED `MessageVerifier`
token cannot be decoded, so a `:signed` app could not tell whose dead link it
was holding — and "is this the visitor's own link?" is the question the whole
new behavior turns on. A `Studio::Link` row keeps the email past expiry.

### Added

- **`Studio::LinkResolution`** — the click decision table as one pure,
  dependency-free module (`lib/studio/link_resolution.rb`), so every cell is
  unit-testable without a controller or a database. Three inputs (did this
  caller burn the link, whose email it carries, who is signed in) resolve to one
  of three actions:

  |                  | nobody signed in | the link's own user | somebody else    |
  |------------------|------------------|---------------------|------------------|
  | **live** (burned)| `:authenticate`  | `:continue`         | `:authenticate`  |
  | **used/expired** | `:dead` → login  | `:dead` → return_to | `:dead` → home   |
  | **unknown token**| `:dead` → login  | —                   | `:dead` → home   |

  The invariant running through it: **a dead link never touches the session.**
- **`:continue`** — a second click on your own still-live link burns the token
  (so a forwarded email stays unusable) and then does nothing else. It
  deliberately does NOT re-authenticate: a host that rotates the session on
  sign-in would otherwise charge a re-click every scrap of session state the
  visitor had built up. From their side it is indistinguishable from following a
  plain link, which is the point.
- **Dead-link notices name the address and the reason** ("That sign-in link for
  x@y.com has expired.") and, when a session is open, say so plainly ("You are
  still signed in as a@b.com") instead of implying a logout that never happened.
- **`Studio::Link#burn`** — the non-raising sibling of `#consume!`, returning
  whether THIS caller won the atomic single-use race, plus `#dead_status`
  (`:used` / `:expired`) for the message. Winning the burn IS the proof the link
  was live; a prior `live?` read is not.
- **`Studio::Link::MissingTable`** — a named error, pointing at the migration to
  copy, in place of a bare `PG::UndefinedTable`. Every consumer pins the engine
  `~> 0.x`, which admits any release below 1.0, so an app that never installed
  the table picks up the row store on its next `bundle update` with nobody
  having adopted anything deliberately. Its boot stays clean (nothing touches
  the table until someone signs in), so without this the failure lands as an
  unreadable adapter error on a real person's sign-in. Guarded by
  `table_exists?`, not a message match, so it holds on any adapter and never
  swallows an unrelated statement failure.
- **`Studio::LinkToken::TOKEN_LENGTH` / `TOKEN_LENGTH_BOUNDS` / `TOKEN_FORMAT`** —
  the house standard, now asserted rather than described: every token is exactly
  16 URL-safe characters, inside a 10-20 character bound.
- **`Studio::LinkConsumption`** gains the whole flow (`preview_magic_link` for
  the inert GET, `consume_magic_link` for the burning POST) plus overridable
  hooks: `link_continue`, `link_dead`, `link_login_path`, `link_home_path`.
  Apps customize by overriding a hook, never by re-deciding.
- **Two new suites**: `test/lib/studio/link_resolution_test.rb` (the table, cell
  by cell, with the dead-link invariant swept across all nine cells) and
  `test/integration/magic_link_flow_test.rb` (the same flow through a real HTTP
  round trip against a real database — token burn, session cookie, scanner
  prefetch, account switch, open-redirect refusal, and the burn race).

### Changed

- **`Studio.magic_link_store` now reads `:database` and nothing else.** Assigning
  `:signed` **raises at boot** with the migration to install, rather than
  silently downgrading — an app that booted anyway would mint rows against a
  table it never migrated and 500 on a real person's sign-in.
- **`Studio.magic_link_via_l_route?`** follows `draw_link_routes` alone.
- **`RegistrationsController`** mints through `Studio::MagicLinkIssuing` like
  every other issuer, instead of calling the store directly.

### Removed

- **`MagicLink`** (`app/services/magic_link.rb`), the stateless MessageVerifier
  service, and its jti-in-Rails.cache replay guard.
- **`GET`/`POST /magic_link/:token`** and `MagicLinksController#confirm` /
  `#consume`. `POST /magic_link` (request a link) stays. The token-bearing door
  is `/l/<token>`, and only that.
- **`app/views/magic_links/confirm.html.erb`** — the `/l` interstitial
  (`studio/links/confirm`) renders the same shared body.
- **`Studio.magic_link_token_name`** is vestigial: the accessor remains so an
  un-updated initializer still boots, but nothing reads it. Delete the line.

### Consumer migration (required)

**Until step 2 lands, the app's magic-link sign-in is broken** — no
`studio_links` table means the first mint raises `Studio::Link::MissingTable`.
Do these two in this order; they do not commute.

1. Delete `config.magic_link_store` and `config.magic_link_token_name` from
   `config/initializers/studio.rb`. **First**, because a leftover `= :signed`
   raises while the initializer loads — and `Studio.configure` yields during
   boot, so no rake task (including the migration install below) can run until
   the line is gone.
2. Install the `studio_links` table with `bin/rails
   studio_engine:install:migrations && bin/rails db:migrate` — install ALL of
   them, per `docs/NEW_APP_SETUP.md` § 5. Do **not** hand-copy the migration:
   the task installs it as `<timestamp>_create_studio_links.studio_engine.rb`, a
   hand copy keeps its own name, and both declare `class CreateStudioLinks`, so
   `db:migrate` dies on `ActiveRecord::DuplicateMigrationNameError`.
3. Replace any `MagicLink.generate` / `MagicLink.consume` call (including in
   test helpers) with `Studio::Link.create_magic_link` / `Studio::Link#burn`.
4. An app overriding the link controllers gets the new behavior by calling
   `consume_magic_link` / `preview_magic_link` and overriding hooks. In
   particular, move any `reset_session` into `sign_in_existing` only — the
   `:continue` path must not reach it.

## 0.30.1 — 2026-08-08

**`NEW_APP_SETUP.md` § 5 gave a command that does not exist.** 0.30.0 documented
the engine migration install as `bin/rails studio:install:migrations`; the real
task is **`studio_engine:install:migrations`**, and the copied files land with a
`.studio_engine.rb` suffix, not `.studio.rb`. The wrong spelling was inferred
from a consumer file that had been hand-copied rather than generated, and it
fails loudly (`Unrecognized command`) for anyone who follows the guide.

**And one of the copied migrations could fail the whole run.** The task copies
FOUR *reference* migrations, and `allow_null_image_cache_owner` runs
`change_column_null :image_caches` — which raised on any app without that table,
taking the entire `db:migrate` down with it. moms-app hit exactly that.

The obvious answer — "review what was copied and delete what doesn't apply" — is
wrong, and this release does NOT tell you to do it. `install:migrations` builds
its skip-list from the files **present**, so a deleted copy comes back with a
fresh timestamp on your next upgrade and fails again. The guard therefore lives
in the migration, and § 5 now says the simple thing: **install all of them.**

### Fixed

- **`allow_null_image_cache_owner` no longer fails `db:migrate` on an app without
  an `image_caches` table.** It ALTERS an app-owned table the engine cannot assume
  exists, and unguarded it raised and took the whole migration run down with it.
  It now no-ops when the table is absent, and still relaxes the owner columns when
  it is present — both halves pinned by
  `test/integration/image_cache_migration_guard_test.rb`.

  Deleting the copied migration was never a workaround: `install:migrations`
  builds its skip-list from the files **present**, so a deleted copy is re-copied
  with a fresh timestamp on the next upgrade and fails again. Verified by
  re-running the task against a real consumer.
- `NEW_APP_SETUP.md` § 5: correct task name, correct file suffix, and — now that
  the migration guards itself — the simple instruction to install ALL of them and
  re-run after each upgrade.
- `EMAIL_TRANSPORT.md`: was pointing at `railties:install:migrations`, which
  copies the migrations of EVERY railtie in the bundle. Scoped to `studio_engine:`.

## 0.30.0 — 2026-08-08

**The hub's link sidebar becomes the engine's out-of-the-box navigation.** New
apps get a default navigation surface without forking the navbar: declare
`Studio.sidebar_sections` (a static Array or a callable receiving the view
context; sections flagged `admin: true` show to admins only) and the engine
navbar mounts a trigger in its desktop icon rail and mobile sub-navbar, then
renders the slide-out link panels after the header. The family ships as
`components/_link_sidebar` (dual desktop/mobile panels + the engine-owned
Alpine `sidebars` store bridge, Turbo- and bfcache-safe), the generic
`components/_sidebar_panel` shell, and `components/_link_sidebar_trigger` —
all lifted from the mcritchie-studio hub. `engine.css` gains the
`studio-link-sidebar-layer` stacking utility and the Alpine `[x-cloak]`
pre-init rule. **Upgrade-safe by default:** `sidebar_sections` defaults to
`[]`, which renders nothing — existing consumers see zero change until they
opt in (pinned by `test/integration/sidebar_navbar_render_test.rb`). The
`html { overflow-x: clip }` slide guard ships inside the sidebar partial, not
globally. When the viewer's resolved sections carry an `admin: true` entry,
the sidebar replaces the engine admin dropdown (both use the cog glyph — one
gear, not two); public-only sections keep the dropdown. Resolution rules live
in `lib/studio/sidebar_sections.rb` (pure Ruby, unit-tested); docs in
`NEW_APP_SETUP.md` §4/§13 and `NAVBAR_SETUP.md`.

**Off-chain apps lose the user nav's dead space.** The default second row
(wallet address + level progress bar) renders only when it has something to
show — a wallet, a server level, or the `show_logout_link` link. A plain
app's signed-in nav collapses to one line instead of an empty progress strip.
The engine navbar's fixed-width `.user-nav-col` (reserved to seat a balance)
likewise applies only when `balance_html` is passed; without one the column
becomes `.user-nav-fit` (shrink-to-fit, `max-width` capped for username
truncation). turf-monster's dense nav is untouched: its users carry wallet +
level, and it ships its own navbar. Pinned by
`test/integration/user_nav_collapse_render_test.rb` and the user_nav view
tests.

**The dev/QA environment banner is now an engine standard a host adopts with ONE
render call, and it carries the Local Inbox link.** Every app hand-rolled its own
yellow "&lt;Env&gt; Environment" strip — this gem's own `NEW_APP_SETUP.md` § 9 shipped
the `<div>` to copy — so no two apps agreed on when it showed or what it said, and
none of them linked `/_studio/local_emails`. The engine already had the pieces
(`studio/banners/_environment` and friends); it just could not decide *whether* to
render, so no host could use it. It can now:

```erb
<%= render "studio/banners/environment" %>
```

No `unless Rails.env.production?` around it, no host `show_environment_banner?`,
no forked buttons. The partial owns all three decisions — whether it appears
(everywhere except real production; a QA app is Rails-production but a review
target, so `QA_ENV=true` re-opens it), what it says (`"QA Environment ·
Non-production"` on QA), and whether the inbox is linkable.

**The inbox link tells the truth.** `Studio.local_inbox_reachable?` consults the
SAME gate `Studio::LocalEmailsController` enforces, so the banner can never
advertise a page that answers 404. Where the viewer resolves (a developer desk)
you get a link; where it does not (QA — Rails-production, remote requests) the
button degrades to an inert `role="status"` chip that still reports the connector
and whether mail is sending or captured. This generalizes the degradation
turf-monster had already built for itself.

Purely additive. `Studio.local_tool_enabled?` and `Studio.local_email_capture?`
are **unchanged** — their production hard-close still stands, which is also why
`LOCAL_EMAIL_CAPTURE=1` on a QA dyno does nothing and QA still sends real mail.

### Added

- **`studio/banners/environment` self-gates** and accepts `preview:` (suppress
  inside a navbar-preview render — a duplicate `vt-pinned-header` silently kills
  view transitions), `extra:` (message segments), `devnet:`, and
  `environment_label:`.
- **`Studio::EnvironmentBanner`** — the show/label rules as dependency-free Ruby,
  unit-tested directly so the suite exercises the shipped code, not a copy.
- **`Studio.qa_environment?` / `.show_environment_banner?` /
  `.environment_banner_message` / `.local_inbox_reachable?` / `.rails_env_name`.**
  `qa_environment?` reads the existing `QA_ENV` the release conductor already sets
  on every QA app — no new variable.
- **`studio/banners/button` gained `as: :status`** — the same chrome, inert, for a
  fact we can report but not navigate to.

### Fixed

- **`studio/banners/button` dropped every attribute on a block render.**
  `tag.span(hash) { }` reads the hash as CONTENT, so the options never reached the
  tag. Splatted as keywords now. Latent until `as: :status` became the first block
  path to use it.

### Docs

- **`NEW_APP_SETUP.md` § 9 no longer ships a hand-rolled banner to copy** — it
  renders the shared partial, and documents the QA/email reality.
- **`NEW_APP_SETUP.md` § 5 now installs the engine migrations FIRST**
  (~~`bin/rails studio:install:migrations`~~ — **erratum, 0.30.1:** that command
  does not exist; the correct task is `studio_engine:install:migrations`).
  Omitting them is silent:
  `Studio::Email.deliver` records mail only when `studio_email_deliveries` exists
  and otherwise falls back to a plain `deliver_later`, so the app drops every
  captured email and shows an empty inbox. Exactly the mcritchie-industries bug,
  fixed 2026-08-08.

## 0.29.1 — 2026-07-29

**`Studio::Board::Rankable#reposition!` is now atomic — a mid-loop failure can no
longer strand a partial restamp.** The per-id `update_all` restamp loop ran with no
transaction, so if any one write raised (a constraint violation, a dropped
connection) the cards already stamped kept their new rank while the rest kept the
old — the read model left half-reordered. The loop body now runs inside a single
`transaction`, so a failure rolls back every rank write in the pass. Purely
additive: the success path is byte-identical, and `skip_locked` / `rank_attr` /
`gap` / `direction` semantics are unchanged, so all four boards (tasks / news /
content / depth-chart) reorder exactly as before.

### Fixed

- **`Studio::Board::Rankable#reposition!` wraps its restamp loop in a transaction**
  so a mid-loop `update_all` failure rolls back the whole column instead of leaving
  a partial restamp. No behavior change on the clean path.

## 0.29.0 — 2026-07-29

**The four depth-chart gaps folded into the `studio/board` primitive (Phase D), so
the MS depth chart can rebase onto it like `/tasks`, news, and content did.** The
0.28.0 primitive fit the near-identical kanban boards; the depth chart is more
custom — it ranks by a `depth` column (1 = starter) while its `position` column
holds a lane-code string, lays its lanes out in a two-level side→position grid, and
pins locked starters. Each capability is **additive and opt-in — every hook omitted
renders and ranks exactly as 0.28.0**, so `/tasks`, news, and content are untouched.

### Added

- **DG1 — configurable rank column + sort direction** (`Studio::Board::Rankable`):
  `board_rank_attr` (default `:position`) and `board_rank_order` (default `:desc`)
  thread through `board_ordered`, `board_next_position`, `set_initial_position`, and
  `reposition!`. A depth chart sets `board_rank_attr = :depth`, `board_rank_order =
  :asc` (depth 1 on top). The order fragment quotes the column and whitelists the
  ASC/DESC literal — never user input.
- **DG2 — sequential 1..N ranks**: `reposition!(ids, gap: 1, direction: :asc)` stamps
  `1, 2, 3, … N` (the depth numbers) instead of the 100-gapped default.
- **DG3 — two-level side→position grid**: `studio/board/_board` accepts `groups:`
  (`[{ key:, label:, cols_class:, columns: [...] }]`) and renders each group as a
  labelled section whose lanes lay out in a responsive grid; `studio/board/_column`
  gains `layout: "grid"` (drops the flex-row width utilities so the grid cell sizes
  the column). Omit `groups:` for the unchanged flat row.
- **DG4 — per-card lock/pin**: `reposition!(skip_locked: true, lock_attr: :locked)`
  leaves a pinned entry's rank untouched; `Studio::Board::Reorderable` gains the
  matching `board_reorderable(rank_attr:, skip_locked:, lock_attr:)` config plus a
  `board_toggle_lock` action (config-gated, `rescue_and_log(target:)` discipline,
  `{ ok:, locked: }`); `studio/board/_card_shell` accepts `locked: true` (adds
  `.kanban-locked` + `data-locked`); the `studioBoard` factory takes a
  `lockedSelector` opt that filters locked cards from dragging and refuses a move
  that would cross one, so a pinned starter keeps its slot while the rest reflow.
- **`/admin/style`** gains a third live board specimen — the depth-chart shape:
  Offense/Defense sections, position lanes in a grid, within-lane reorder, and 🔒
  pinned starters.

## 0.27.0 — 2026-07-28

**Two coordinated modal flows on the `/admin/style` Design System page — a walked
"Web3 Contest" wallet → on-chain flow and an extended "Contest entry & eligibility"
flow — plus a reusable minimum-visible-duration convention for load modals.** All
specimens are DEMO chrome (`demo: true`, no real signing); the engine gains only
view/chrome primitives and keeps custodial keys, wallet/multisig signing,
`Solana::Config`, and every on-chain write app-side.

### Added

- **Minimum-visible-duration convention** — `studio/modals/_load_convention`
  ships `window.StudioModals.holdAtLeast(minMs)` + a standard
  `MIN_LOAD_MS` (1400) as a SINGLE definition, rendered by both the shared modal
  host (`studio/modals/_host`, which drops its inline copy) and the style page.
  A load spinner holds for at least `min_duration`, longer if the real async runs
  longer — `resolveAt = max(min_duration, actual_completion)`; in demo mode
  `min_duration` doubles as the auto-resolve timer. `_processing_card` gains
  `min_duration` + `resolve_expr` locals so a demo load card self-advances.
- **Web3 Contest** section (renamed from "Web3") — a walked flow with
  glow-follows-the-flow continuity: Connect Wallet → Processing on-chain
  transaction → On-chain success. The Processing card is a load modal with a demo
  success/error toggle (unchecked resolves to success, checked to error), both
  resolved states built. Picking a wallet swaps to Processing, which auto-resolves
  after the min-load duration.
- **Contest entry & eligibility** section (renamed from "Eligibility & entry",
  moved directly under Web3 Contest) — the entry flow extended to
  Entry tokens → Payment processing → Entry Tokens Minted → Contest enter
  processing → Contest entered, with the glow following the step machine. Keeps
  the Age gate + Entry tokens cards. The section states the honest web2/web3 map:
  the token mint is web2-only (web3 funds USDC on-chain directly, no token); the
  paths diverge at the funding front-end and the entry-submit endpoint, then
  converge on the same on-chain Entry PDA and the same "Entry Confirmed" card.

### Changed

- **`studio/modals/_host`** — the `holdAtLeast` helper now lives in the shared
  `_load_convention` partial (same API, byte-identical behavior) so the host and
  the DS page share one definition instead of drifting copies.
- **`style/modals/_entry_tokens`** — the confirming step uses the min-load
  convention instead of a hardcoded timeout, and the step machine gains
  `entering` + `entered` so hold-to-confirm walks through the on-chain consume to
  the shared Entry Confirmed finish.
- **`style/modals/_onchain_tx`** — a processing modal opened with `demoResolve`
  auto-resolves to success (or error when `demoError`) after the min-load
  duration, honoring the convention.
- The Modals-section glow helper discriminates the on-chain-tx `state` and a
  configurable step default, so the glow tracks a walked flow across modal ids.

## 0.26.1 — 2026-07-28

**Fix the `/admin/style` Design System page breaking when reached via Turbo Drive
navigation (the admin sidebar "Design System" link).** Reached by a direct page
load the page was fine; reached by an in-app Turbo visit its modals would not open
on a card click and EVERY specimen glow ring lit at once. Both symptoms were one
cause: the page-scoped `dsModals` (and `dsSolanaModal`) Alpine store was registered
ONLY inside a `document.addEventListener('alpine:init', …)` handler in the page
body. Alpine loads via a deferred CDN `<script>` in the engine head and fires
`alpine:init` exactly once, on the first full-document load; Turbo Drive advance
visits swap `<body>` without reloading that head script, so `alpine:init` never
fires again — and because the registration lives only in the `/admin/style` body,
it was absent during that one `alpine:init`. The specimen cards' `x-data` still
re-initialize on the Turbo body swap (Alpine's MutationObserver), so their
`@click="$store.dsModals.open(…)"`, `:style` glow bindings, and the host's
`<template x-if="$store.dsModals.current()…">` all evaluated against an undefined
store and threw `Cannot read properties of undefined (reading 'current')` — no
modal opened, and the throwing `:style` wiped each card's static inline
`--studio-team-glow-opacity: 0`, so the CSS default of `1` relit all rings.

### Fixed

- **`style/_modals`** — the `dsModals` + `dsSolanaModal` registration is now a
  named `registerDsModals()` invoked through the same dual-guard the engine
  already uses for `studio/modals/_image_upload`'s `cropPhotoModal`:
  `if (window.Alpine) registerDsModals(); else document.addEventListener('alpine:init', registerDsModals);`.
  On a Turbo visit Alpine has already started, so the store registers immediately
  (the body script re-runs on every Turbo render) and `$store.dsModals` is defined
  before the cards' bindings evaluate; on a first load Alpine has not booted yet,
  so it still defers to `alpine:init`. The `if (Alpine.store('dsModals')) return;`
  idempotency guard is unchanged, so a later `alpine:init` is a no-op. No consumer
  change is required — `/admin/style` is an engine page.
- **Docs** — `style/_modal_specimen`'s fail-closed comment now records that the
  static inline `--studio-team-glow-opacity: 0` guards the ring only while
  `$store.dsModals` is DEFINED (a throwing `:style` wipes the inline value) — the
  refinement of 0.24.1's "regardless of Alpine timing" claim that this bug exposed.

### Swept

- Audited every engine `Alpine.store(...)` / `Alpine.data(...)` registration for
  the same Turbo-visit fragility. `dsModals`/`dsSolanaModal` (`style/_modals`) was
  the only page-scoped registration missing the guard. `studio/modals/_image_upload`
  (`cropPhotoModal`) already carries it; the shared modal host (`studio/modals/_host`
  → `modals`) and the theme/devMode stores (`layouts/studio/_head`) are app-wide
  bootstrap rendered on the first full load, so their single `alpine:init`
  registration persists across Turbo visits (verified: `$store.modals` stays
  defined after a Turbo nav).

## 0.26.0 — 2026-07-28

**The engine navbar pins itself under smooth-load, and the smooth-load CSS is
fully engine-owned.** Since 0.24 the `vt-pinned-header` pin was opt-in but the
engine's own `layouts/_navbar` never carried it, so a host that wanted the
pinned-header transition had to SHADOW the whole partial just to add one class
(acquisition-studio did exactly that — the known override-drift trap). The
navbar now self-pins when `Studio.smooth_load` is on, and the engine also ships
the `studio-header` cross-fade suppression that mcritchie-studio and
turf-monster had been carrying app-side as a bridge. **Consumer cleanup this
version unlocks:** acquisition-studio deletes its entire
`app/views/layouts/_navbar.html.erb` override; mcritchie-studio and
turf-monster delete their app-side `::view-transition-old(studio-header)` /
`::view-transition-new(studio-header) { animation: none; }` bridge blocks.

### Changed

- **`layouts/_navbar`** — the sticky header adds `vt-pinned-header` itself when
  `Studio.smooth_load` is on, non-preview branch ONLY (preview renders can
  repeat per page, and a duplicate `view-transition-name` silently disables
  every transition). With the flag off nothing extra renders, so a plain gem
  bump changes no opted-out app.
- **`engine.css`** — new `::view-transition-old(studio-header)` /
  `::view-transition-new(studio-header) { animation: none; }` rule beside the
  smooth-load block: it suppresses the UA-default ~250ms plus-lighter
  cross-fade between the header's two snapshots, which double-drew the wordmark
  and buttons on any navigation from a scrolled page (collapsed header →
  expanded at top). Lifts the identical bridge rule the hub and turf-monster
  carried app-side.
- **`engine.css`** — `.turbo-progress-bar` background becomes
  `var(--color-cta, #0076ff)`: the fallback (Turbo's own default blue) keeps
  the bar visible in a layout that never renders the runtime theme block
  (`studio_theme_css_tag`), where `--color-cta` is unset.

## 0.25.1 — 2026-07-28

**Fix the Profile Leveling save-close regression 0.25.0 introduced.** The 0.25.0
rebuild made `_finishSaved` ALWAYS advance to the engine's own updated view (the
seeds celebration or the plain confirmation), on the belief that Turf Monster's
live usage was "unaffected." It was not: TM's change-username modal
(`leveling: false`, `saved_event: "studio:username-saved"`) drives its OWN
post-save follow-on — its listener runs `completeQuest` and closes/swaps. With
the engine now also advancing to its own confirm view, the next quest step
("Send Your First Message") rendered TWICE at once — once in the post-save modal
dialog, once in the inline quest card behind it — which TM's Playwright e2e
caught as a strict-mode double-render (`quest_ladder_web2`, `quest_ladder_web3`,
and the web3 step-dedup contract). In 0.24 a `leveling: false` modal rendered no
celebrate view and let the app close it, so the step rendered once.

### Fixed

- **`studio/_leveling_activity_assets`** (factory) — `_finishSaved` now CLOSES on
  save (fires the `saved_event`, then stops — the 0.24 contract) instead of
  advancing to the engine's own confirm/celebrate WHEN the consuming app drives
  its own follow-on. A new `appDrivenFollowOn` getter is that signal: a **non-demo**
  caller that wired its OWN (non-default) `saved_event` owns the after-save UI, so
  the engine yields (it never force-closes — the app's listener owns close-vs-swap,
  which TM relies on: close on the contest page, swap to `quest-success` on
  `/account`). **Demo** previews (`/admin/style`) and **standalone** callers on the
  DEFAULT `saved_event` are unchanged — they still advance to the seeds celebration
  (TM shape) or the plain confirmation (MS shape), and the "Great Username" /
  "Subscribed!" specimen cards still open straight at their celebrate state via
  `props.celebrate`. No consumer change is required; TM's existing wiring restores
  its own contract.



**Profile Leveling** — the `/admin/style` "Leveling activities" section is rebuilt
into a single toggle-driven "Profile Leveling" flow, and the with-leveling /
without-leveling FORK is killed. Previously each activity shipped as TWO modal
ids (`change-username` + `change-username-plain`, `quest-activity` +
`quest-activity-plain`), because the primitive read `leveling` from a Ruby local
at render time. Now the primitive reads `leveling` at RUNTIME from the modal
store's `props.leveling`, so ONE id per activity flips the Turf Monster shape
(the seeds celebration + Free Entry Token progress) ↔ the McRitchie Studio shape
(plain input + Save, then a simple confirmation) live as its per-card leveling
toggle moves.

### Changed

- **`studio/modals/blocks/_leveling_activity`** — three views now, all ALWAYS
  rendered and gated by the reactive `leveling` getter instead of dropped at ERB
  time: the **form** (`!celebrate`), the **seeds celebration**
  (`celebrate && leveling`, TM), and a **plain confirmation**
  (`celebrate && !leveling`, MS). The `leveling` local becomes the render-time
  fallback only. **The "Quest N of N" counter pill is removed** — the profile
  modals do not carry one. **The "Level N" pill is also dropped** from the
  celebration (no consumer used it); the seeds bar stays. All existing seams
  are preserved unchanged (`submit_url`, `finalize_hook`, `saved_event`,
  `modal_store`, `demo`, seeds/level props), so Turf Monster's live usage and the
  opaque save-callback contract are unaffected (TM ships no `props.leveling` and
  keeps its `:leveling`-capability default).
- **`studio/_leveling_activity_assets`** (factory) — `leveling` is a runtime getter
  reading `props.leveling` off the modal store (falling back to `_levelingDefault`);
  an `init` hook opens the modal directly at the updated state via `props.celebrate`
  (the "updated" cards open the same id pre-advanced, like the Auth step cards);
  `_finishSaved` always advances to the updated state (the view gate picks
  celebration vs plain confirmation) AND mirrors `celebrate` onto the live store
  `props.celebrate`, so the active-card **glow follows the flow** — it transfers
  from the input card to the updated card as the modal advances, exactly like the
  Auth glow follows `props.step`. In **demo** mode the app-facing saved event is
  suppressed, so a host app's follow-on handler (e.g. Turf Monster's
  `quest-success` on `studio:username-saved`) can't stack a second modal over the
  demo's own celebrate view.
- **`/admin/style`** — "Leveling activities" → **"Profile Leveling"**: **each
  specimen card carries its OWN `Leveling` toggle** (like the Auth card's method
  checkboxes), flipping THAT card between the Turf Monster and McRitchie Studio
  shape at open — so you can preview Change Username leveling-on beside Great
  Username leveling-off. The section walks **four** cards — **Change Username →
  Great Username**, then **Join the Newsletter → Subscribed!** — each "updated"
  card opening its modal straight at the success state, mirroring Turf Monster's
  real copy, seeds, and Free Entry Token progress. No quest counter, no Level pill.

### Added

- **`_leveling_activity` locals** (all optional, additive): `consent_label` (a
  consent checkbox that gates the action — the newsletter join), `confirm_subtitle`
  (subtext on the MS-shape plain confirmation), `next_label` / `next_open` (a
  "Next Quest" button that walks to the next activity), and `demo_seeds_earned` /
  `demo_seeds_total` (style-guide-only seed payload tuning).

## 0.24.1 — 2026-07-28

Bug fix — the **`/admin/style` specimen glow failed OPEN**. Every glow-capable
specimen card (`style/_modal_specimen`) carries the `.studio-team-glow` class
statically, and the "only the active card glows" behavior rode entirely on a
reactive Alpine `:style` overriding the primitive's CSS default of
`--studio-team-glow-opacity: 1` (visible) down to `0`. Before Alpine hydrates —
or if it never loads — all 13 reactive-glow cards (Auth, Eligibility, Profile,
Leveling) painted their ring at once. The steady state was correct (the glow
follows the step machine), so this surfaced as a flash-of-all-glow on load.

### Fixed

- **`style/_modal_specimen`** now renders a **static inline
  `style="--studio-team-glow-opacity: 0"`** on the glow wrapper beside the
  reactive `:style`, so the ring is OFF at first paint (fail-closed) regardless
  of Alpine timing. The reactive binding still drives `0 ↔ 0.95` with the 0.4s
  cross-fade, so the active-card glow and its slide between step cards are
  unchanged. The `engine-motion.css` `.studio-team-glow` default is untouched
  (the always-on Tricks demos depend on it).

  > **Refined in 0.26.1:** "regardless of Alpine timing" holds only while
  > `$store.dsModals` is defined. On a Turbo Drive visit the store went
  > unregistered, the reactive `:style` threw, and Alpine wiped this inline
  > default — relighting every ring. 0.26.1 dual-guards the store registration so
  > it survives Turbo visits, restoring the fail-closed guarantee.

## 0.24.0 — 2026-07-28

The **smooth-load convention**, opt-in per app. Pages materialize behind the
current one and present themselves with a view transition — navigation renders
exactly once, with no stale-preview flash. Modifies an existing primitive:
`layouts/studio/_head` gains the convention partial and a configurable nav
spinner minimum.

**One ungated visual change on the bump, opt-in or not:** `.turbo-progress-bar`
in `engine.css` restyles every consumer's Turbo progress bar from Turbo's
default blue to the app's theme CTA color (3px, `var(--color-cta)` — defined in
both themes by the theme resolver, and the rule wins Turbo's injected-first
stylesheet cascade). Everything else is inert until an app sets
`Studio.smooth_load = true`.

### Added

- **Smooth-load convention (opt-in)** — `Studio.smooth_load` (default OFF)
  renders `layouts/studio/_smooth_load` from `_head`: the `view-transition`
  meta (Turbo 8 wraps page swaps in `document.startViewTransition`) plus
  `turbo-cache-control: no-preview`, so the next page materializes behind the
  current one and presents itself — navigation renders exactly once. An app
  with known multi-second pages should fix those before opting in (no-preview
  holds the old page until the fresh response arrives).
- **`Studio.nav_spinner_min_ms`** — the nav spinner's minimum display time,
  previously hardcoded to 2500 in `_head`. Default unchanged (2500); smooth-load
  apps typically drop it to ~300 so fast loads never linger on a spinner.
- **Smooth-load CSS in `engine.css`** — root fade-out / rise-in view-transition
  keyframes (inert until the metas render), the `.vt-pinned-header` opt-in
  utility (exactly one per page — a duplicate `view-transition-name` silently
  disables the transition), the theme-colored `.turbo-progress-bar` noted
  above, and a `prefers-reduced-motion` kill switch app e2e suites can lean on
  (`reducedMotion: "reduce"`).

### Fixed

- **`rescue_from` order in `Studio::ErrorHandling`** — `RecordNotFound` now
  resolves to `handle_not_found` (Rescuable matches last-registered first, so
  the catch-all must register first). A missing record renders a real 404 from
  `public/404.html` and **creates no ErrorLog row**; previously it was shadowed
  by the catch-all, logged as an unexpected error, and soft-404'd (302 to root)
  in production HTML. Per-host behavior changes only as each app bumps to this
  release.

## 0.23.0 — 2026-07-28

Phase D, slice 1 — the **board primitive**. The three near-identical McRitchie
Studio kanban boards (tasks / news / content) each hand-rolled the SAME SortableJS
init, the SAME optimistic move → revert → toast, and a BYTE-IDENTICAL `reorder`
controller action; the depth chart hand-rolled a within-lane variant. This slice
lifts that convergence into a neutral engine primitive, following the same seam as
the leveling modals and tricks (documented `local_assigns.fetch` locals → a
page-level Alpine factory in an `_assets` partial → capability / `fx` / event hooks
→ a `demo:` local for `/admin/style` → vendored JS).

**Purely additive — new engine files only, no existing primitive's default
changes. MS and TM render identically on the bump** (they do not use
`studio/board/*` yet; the board rebases are separate later deploys).

### Added

- **`studio/board/_board`** — the board shell: a row of columns (drop zones), an
  optional live `turbo_stream_from`, and a toast host. Documented `local_assigns`
  locals: `columns:` `card_partial:` `card_as:` `card_locals:` `reorder_url:`
  `reorder_payload:` (`:slugs` | `:ids`) `move_url:` `move_param:` `group:`
  (`false` = within-zone) `id_attr:` `zone_attr:` `handle:` `filter:`
  `zone_selector:` `draggable:` `empty_selector:` `live_channel:` `optimistic:`
  `toasts:` `empty_label:` `header_slot:` `above_board_slot:` `fx:` `on_move_hook:`
  `on_drop_hook:` `demo:`.
- **`studio/board/_column`** — one column: header + count badge + the
  `.kanban-dropzone` (`id="dropzone-<key>"`, `data-<zone_attr>`) + `.kanban-empty`
  empty state (the ZONE half of the identity contract).
- **`studio/board/_card_shell`** — OPTIONAL `render layout:` chrome that emits the
  CARD half of the contract (`id="card-<id>"`, `.kanban-card`, `data-<id_attr>`,
  `data-<zone_attr>`). Apps may hand-roll a bespoke card that satisfies the same
  contract instead.
- **`studioBoard(opts)` factory — `studio/_board_assets`.** The Alpine data behind
  the board, shipped at page level (a `<script>` cloned from a component template
  never runs), like `levelingActionModal`. ONE factory drives BOTH shapes — it
  reads `group` / `handle` / `filter` / `draggable` / `id_attr` / `zone_attr` from
  opts, so the cross-column kanban and the within-lane depth chart are the same
  code. Owns `initSortables`, `handleSortEnd` (cross-column move → PATCH →
  optimistic revert + red-ring + toast; a same-zone drop NEVER PATCHes the zone),
  `saveOrder` (reorder POST), `updateCounts`, `observeLive`,
  `installExitStreamFallback`, `animateIn`, and toasts. Preserves the
  `$nextTick` → `data-alpine-ready` init ordering (a documented flake fix). The
  primary extension seam is the dispatched window events
  `studio:board-moved` / `:board-reordered` / `:card-added` (detail
  `{ record, from, to }`) — apps LISTEN, never patch the factory.
- **SortableJS v1.15.6 (MIT) VENDORED** — `app/assets/javascripts/studio/sortable.js`,
  added to `config.assets.precompile` and loaded (deferred) by
  `layouts/studio/_head`, mirroring the vendored canvas-confetti. CSP-safe, no CDN;
  any board consumer gets `Sortable` with zero per-app wiring.
- **`Studio::Board::Rankable`** — the shared 100-gap rank read-model: a
  `board_ordered` scope (`position DESC NULLS LAST, created_at DESC`),
  `set_initial_position` (max + 100 within the zone), and `reposition!(ids, gap:,
  direction: :desc | :asc)`.
- **`Studio::Board::Reorderable`** — the shared `reorder` controller action,
  neutral param, delegating the 100-gap restamp to `Rankable#reposition!`.
- **`/admin/style` Board specimen** — the Tasks section now renders the REAL
  `studio/board/board` primitive in `demo: true` mode (drag works, no POST),
  above the static stage-palette reference.

## 0.22.0 — 2026-07-28

Two additive batches for the living style guide, converged under one release.
No existing shared primitive changes its defaults, so MS and TM render identically
on the bump.

Modal convergence, Phase 3: homes Turf Monster's quest/leveling activity modals
(change username + the quest flows) as engine primitives, each supporting BOTH
modes behind the `:leveling` capability flag. Plus a Tricks batch: three
celebration/attention effects lifted from Turf Monster into engine primitives, all
demoed on `/admin/style`.

### Added

- **Leveling-activity modal — `studio/modals/blocks/_leveling_activity`.** ONE
  primitive, **two modes**, decided by `Studio.feature?(:leveling)`:
  - **leveling on** — the full quest framing: a "Quest N of N" pill, and on
    success the seeds celebration (progress bar + level-up + Free Entry), composed
    from the existing `card_header` + `_seeds_bar` chrome.
  - **leveling off** — the plain action modal: just the action + Save, then a
    Saved state. No quest pill, no seeds. This is the McRitchie Studio shape (MS
    has no leveling; Turf Monster does).

  It renders a title, app-authored description, an optional single-line input
  (`input` / `input_type` / validation attrs), and a configurable CTA. Callers
  override the `leveling` gate per callsite (the style guide passes both) or let
  it default to the app flag.

- **Change-username modal — `studio/modals/blocks/_change_username`.** A named
  engine primitive and a thin specialization of `_leveling_activity` with username
  defaults (3–30 char input, the on-chain-neutral default copy, a
  `studio:username-saved` event). This is the primary migrated modal.

- **`levelingActionModal` factory — `studio/_leveling_activity_assets`.** The
  Alpine data behind both modals, shipped at page level (a `<script>` cloned out
  of a modal-host template never runs), like `ageVerifyModal`.

  **CRITICAL BOUNDARY — UI ONLY.** The actual save is an **app-supplied callback**:
  the modal POSTs to `submit_url` and reacts to a **domain-neutral** JSON contract
  (`{ status: "saved" | "needs_step" | "error" }`). Any second step some apps need
  (e.g. a managed-wallet write) is delegated **opaquely**: the engine hands the
  app-returned `challenge` blob to an app-supplied `window[finalize_hook]` and
  POSTs back the opaque `proof` the app returns — it never inspects, parses, or
  decodes either blob. No wallet taxonomy, signing, keys, or on-chain writes live
  anywhere in the engine; the custodial-vs-Phantom branch stays server-side. Turf
  Monster wires the managed-wallet write; McRitchie Studio wires a trivial endpoint
  that returns `{ status: "saved" }`.

- **Living style guide — new "Leveling activities" group.** Adds four specimens to
  the `/admin/style` Modals section — **change username** and a generic **quest
  activity** (a newsletter-join), each shown **both ways** (leveling on and off) so
  the two modes are visible regardless of the app's flag. Each demo resolves the
  save locally, wires the active-card glow, and carries an agent-ready reference.

- **`window.studioConfetti` — a zero-dependency, no-CDN confetti effect.**
  canvas-confetti (v1.9.3, MIT) is now **vendored into the engine**
  (`app/assets/javascripts/studio/canvas_confetti.js`) and shipped through the
  asset pipeline instead of loaded from a CDN — CSP-safe (same-origin `:self`),
  zero per-app dependency. `studio/studio_confetti.js` builds two callable
  effects on top, both honoring `prefers-reduced-motion: reduce`:
  - **`studioConfetti.burst(target)`** — the radial card-burst that explodes from
    *behind* a card/modal, emanating from its center. Aim it with a DOM element,
    a selector, or an `{x, y}` origin (0..1 viewport space); defaults to screen
    center. Ported from turf-monster's `fireConfettiFromModal`.
  - **`studioConfetti.cannons()`** — the full-screen "you joined a contest"
    celebration: a center burst plus left + right side-cannons firing inward.
    Same choreography as the engine head's `window.fireSuccessConfetti`.

- **`.pulse-cta` — an attention pulse/glow for a CTA button**
  (`engine-motion.css`). A gentle scale + expanding fading ring on a loop, themed
  off the CTA role token (`--pulse-cta-color`, default `--color-cta`) so it
  restyles per app, reduced-motion aware. Ported from turf-monster's
  "Change Username" quest CTA (`.quest-pulse`). Named `.pulse-cta` (not
  `.btn-pulse`) so it stays a plain motion-layer effect, not a `.btn` component
  variant the `engine.css` contract would demand.

- **Three `/admin/style` Tricks specimens** — a "Confetti & pulse" group renders
  all three live: a "Fire burst" and "Fire cannons" demo (each surfacing the
  `window.studioConfetti.*` call name + a copyable snippet) and the `.pulse-cta`
  button.

### Changed

- The engine head (`layouts/studio/_head.html.erb`) now loads the **vendored**
  canvas-confetti via `javascript_include_tag` rather than the jsDelivr CDN.
  `window.fireSuccessConfetti` is unchanged and rides the same global — behavior
  is identical, only the script source moves from CDN to a bundled engine asset.

## 0.21.0 — 2026-07-27

Phase 2 of the studio-engine modal convergence: homes the entry-time age-gate DOB
modal as a policy-free engine primitive, and documents the app-specific entry-token
purchase flow as a living-style-guide specimen.

### Added

- **Age-gate DOB modal — `studio/modals/blocks/_age_verify`.** The entry-time
  date-of-birth gate (Month / Day / Year + a live "too young" hint + submit),
  homed in the engine as the heavier sibling of the existing
  `studio/modals/shared/_age_attestation` checkbox. **Run one or the other:** the
  attestation is a signup-time "I confirm I'm of legal age" checkbox; this is an
  entry-time DOB gate a server can recompute and stamp.

  **The engine hardcodes NO legal policy** — the whole seam is app-supplied:
  `min_age` (REQUIRED, with **no engine default** — 18 is itself a policy value),
  `submit_url` (the app owns the authoritative recompute + DOB persistence),
  `state` (an optional PASSIVE jurisdiction label — the modal never detects
  geography and never offers an editable state field, so a spoofed client state
  can't lower the bar), and `fine_print` (the app's per-jurisdiction legal copy;
  the engine ships only a neutral, policy-free default). The per-state age table
  that the app's policy encodes never enters the engine.

- **`ageVerifyModal` factory — `studio/_age_verify_assets`.** The Alpine data for
  the DOB modal, shipped at page level (a `<script>` cloned out of a modal-host
  template never runs). A consumer renders it once in its layout, like the shared
  alpine factories; mirrors how `studio/_cropper_assets` homes `cropPhotoModal`.
  The factory carries zero policy — no age default, no state table; the client
  age math is UX only, the server recompute stays authoritative.

- **Living style guide — new "Eligibility & entry" group.** Adds two specimens to
  the `/admin/style` Modals section:
  - The **age-gate** specimen, opened with a clearly-labelled DEMO policy (21+ in
    CA) that documents the app-supplied seam, gated by
    `Studio.feature?(:age_gate)` — disabled-but-present-yet-openable when off,
    like the web3 specimens.
  - The **entry-tokens** specimen — the app-specific purchase flow
    (picker → confirming → minted) documented by composing engine chrome
    (`shell`, `card_header`, `progress_pill`) with illustrative demo packs. The
    engine does NOT own the packs, pricing, rails, or the on-chain mint. The copy
    reflects the real on-chain model: an entry token is a **prepaid entry credit
    recorded on-chain** (not a wallet-held SPL token), **minted server-side** once
    payment clears and **consumed** when the app's hold-to-confirm creates the
    entry.

### Capability gating

- **`:age_gate`** — a new, independent capability flag gating the age-gate
  specimen (and the intended consumer mount). Off by default; a consumer opts in
  via `config.features`.

### Unchanged

- Backward compatible: every addition is additive/optional. Nothing existing
  changes behaviour, and the lighter `_age_attestation` checkbox is untouched.

## 0.20.0 — 2026-07-27

Phase 1 of the studio-engine modal convergence: the engine now OWNS the wallet
brand icons, homes the entry-confirmed celebration, and gates the web3/leveling
enrichments behind the two independent capability flags.

### Added

- **Wallet brand icons ship inline from the engine** — new
  `studio/modals/blocks/_wallet_brand_sprite` emits a hidden inline-SVG sprite
  with the Phantom (purple ghost), Solflare (yellow S), and Backpack (red pack)
  marks as `<symbol>`s. The Connect-wallet picker resolves a mark by name
  (`brandIcon(name)` → `<use href="#se-wallet-…">`) and falls back to a letter
  tile only for an unknown wallet. Every consumer inherits crisp brand icons
  with **zero per-app asset files** — before this, the picker referenced
  app-served PNGs (`/wallet-phantom.png`, …), so a fresh app that had not copied
  those into its own `public/` showed 404 letter tiles.

- **Entry-confirmed celebration — `studio/modals/blocks/_entry_confirmed`.** The
  canonical "you're in" card, homed in the engine and composed via the
  `_success_card` **yield slot**: `_success_card` owns the web3 spine (the `:lg`
  check header, branded Solana tx link, drain CTA with auto-redirect, confetti),
  and `_entry_confirmed` injects the leveling enrichment into its block. All
  numbers are **app-supplied** via Alpine expressions (default `props.*`):
  `txSignature`, `lobbyUrl`, `seedsEarned`, `seedsTotal`. Turf-specific copy is
  parameterized, not baked in.

- **Seeds progress bar — `studio/modals/blocks/_seeds_bar` + `_digit_reel`.**
  Ported from Turf Monster and generalized: the animated 5-segment fill with a
  4-phase level-up sequence (fill → level pop → drain → refill) and the
  rolling-digit counter. The `--bar-progress` registered custom property,
  `.seeds-bar-continuous`, `.seeds-reel-track`, and the `seedsShimmer` keyframe
  ship in `engine-motion.css`. Motion is class-owned (timing via a
  `--seeds-fill-dur` knob) so `prefers-reduced-motion` actually cancels the
  bar-fill, shimmer, and reel.

- **Free Entry Earned modal — `studio/modals/blocks/_free_entry_earned`.** The
  standalone level-up reward modal, parameterized (store, icon, title, copy).

- **Living style guide** gains an engine-owned wallet-icon picker, an
  "Entry confirmed" (web3) specimen, and "Entry + seeds level-up" +
  "Free Entry Earned" (leveling) specimens, so the gated variants demo correctly
  (generic-success vs seeds vs free-entry).

### Capability gating

- **`:web3`** gates the generic entry-confirmed success (branded tx link +
  heading + CTA), alongside the existing wallet / on-chain / deposit modals.
- **`:leveling`** — independent of `:web3` — gates the seeds bar and the Free
  Entry Earned reward. `_entry_confirmed` self-gates its block on
  `Studio.feature?(:leveling)`, so a **web3-only app (leveling off) gets the
  clean success card automatically** — no seeds, no free entry.

### Unchanged

- Backward compatible: every addition is additive/optional (new locals default
  to today's behavior). The shared `_success_card`, `_card_header`,
  `_cta_redirect`, and the other blocks are untouched in default behavior, so
  existing McRitchie Studio and Turf Monster consumers render identically. No
  engine view-primitive gains any signing / key material — signing stays an
  app-supplied callback seam.

## 0.19.0 — 2026-07-27

### Added

- **`GET /_studio/local_review` — the local half of the board's WAITING APPROVAL
  button.** A magic link signs the recipient into the app that MINTED it: the
  token lives in that app's store, and `return_to` is sanitized to a same-origin
  PATH. So a link minted by the production task board could only ever land on
  production — the operator clicked "review this locally" and arrived, signed in,
  on `mcritchie.studio`. The board now redirects here instead, to the local
  server named by the task's `local_url`, which mints in its OWN database and
  lands the operator signed-in on the page under review
  (`?email=<who>&return_to=<path>`).

  Like the local email inbox it sits beside, this is a developer-desk tool that
  hands out sign-in material without authenticating anyone, so it is bound to the
  same floor: the route is drawn outside production only, and every request is
  re-checked against `Studio.local_tool_enabled?` — production or non-loopback
  gets a bare 404.

### Changed

- **`Studio.local_tool_enabled?(request_local:)`** — one spelling of the
  developer-desk floor (not production, loopback only), now shared by
  `Studio::LocalEmailsController` and `Studio::LocalReviewsController` so a tool
  added later cannot quietly ship a weaker gate.

- **`Studio::MagicLinkIssuing`** — the mint (`issue_magic_link`) and the URL that
  consumes it (`magic_link_url_for`) are two halves of one decision
  (`Studio.magic_link_store`), extracted from `MagicLinksController` and
  `UserMailer` into a shared concern. Handing out the wrong URL for the store
  yields "invalid or expired" on a link that was valid; they can no longer drift
  apart. No behavior change for either existing caller.

## 0.18.0 — 2026-07-27

### Added

- **Capability features — `Studio.features` / `Studio.feature?(name)`.** A new
  coarse app-capability switch mirroring the `auth_methods` / `auth_method?`
  pattern. `mattr_accessor :features` defaults to `[]` (every capability OFF);
  an app opts in from `config/initializers/studio.rb`, e.g.
  `config.features = %i[leveling web3]`, and code gates a surface with
  `Studio.feature?(:leveling)`. Distinct from `auth_methods` (which sign-in
  methods): features gate whole product surfaces. `feature?` tolerates String or
  Symbol entries and any Enumerable, so `feature?("web3")` and `feature?(:web3)`
  agree.

- **`engine-motion.css` — four EFFECT primitives.** Beyond the seven motion
  primitives, a new visual-effect family (same design rules: plain classes,
  themed CSS-var knobs, namespaced keyframes): `.text-gradient` (gradient-clipped
  text fill), `.studio-glow` / `.studio-glow--pulse` (a soft themed glow halo,
  distinct from the animated rainbow-border `.studio-border-glow`),
  `.surface-glass` (a frosted, translucent glass panel for overlay chrome via
  `backdrop-filter` + `color-mix`), and `.conic-surface` (a slow rotating
  conic-gradient ambient wash). All themed through the role tokens; the animated
  ones honor `prefers-reduced-motion`.

- **`engine-motion.css` — the LEVELING family (Turf Monster's level badges).**
  The polished `.level-badge` ladder is lifted verbatim into the engine so any
  consumer with `Studio.feature?(:leveling)` ships it: the `.level-badge` base +
  `.level-badge-1 … .level-badge-10` tiers (outline starter → filled green →
  lifted/glowed/beveled → two-tone → mint → animated mint → holographic Level 10
  with the 8-stop 400% gradient), the `.level-up-pop` pop + glow burst, the
  `.nav-level-pop` nav bounce, and the `.badge-with-sheen` one-shot sheen wrapper
  (ported from TM's `@utility` to a plain class, this layer's convention). The
  tiers theme off `--color-primary-500-rgb` (emitted by `studio_theme_css_tag`)
  so they restyle per app; the fixed mint accent is a `--level-mint` /
  `--level-mint-rgb` knob (`#06d6a0` default). The port uses the modern slash
  form `rgb(var(...) / a)` throughout — fixing TM's `levelGlow`, which shipped
  the legacy `rgba(var(--…-rgb), a)` form that silently drops for a
  space-separated var. The animated tiers honor `prefers-reduced-motion`.

### Changed

- **`admin/style` — the living style guide (renamed from `admin/design_system`).**
  The page moves to `/admin/style` (`StyleController#index`, helper
  `admin_style_path`); `/admin/design_system` now **redirects** there and keeps
  its `admin_design_system_path` helper resolving, so a shipped host sidebar link
  keeps working. Four sections reached by a sticky section nav, reordered to lead
  with the color foundation: **Theme (landing) · Modals · Tricks · Tasks**
  (anchors `#theme · #modals · #tricks · #tasks`), rendered as sibling partials
  (`_theme`, `_modals`, `_tricks`, `_tasks`).
  - **Theme** now owns "the colors": it leads with the 7 role tokens/swatches
    (moved out of the old Style section), folds in the `/admin/theme` editor, and
    keeps a live dark/light preview. Save + Regenerate now persist **in place** —
    they submit via `fetch` and `preventDefault` the navigation (the old form
    posted to `theme_settings#update`, which redirected to `/admin/theme` and
    bounced the operator off the page), the live preview stays, and the outcome
    is a toast (the shared `_flash` toast primitive). The standalone
    `/admin/theme` page's own redirect is unchanged.
  - **Tricks** (the old "Style" section) is reframed as a board of copy-paste-for-
    an-agent style tricks: each specimen surfaces its class name prominently with
    a one-click copy plus the copyable usage snippet. It keeps the Buttons /
    Surfaces-text-form / Motion / Effects groups, and its **Leveling** group now
    renders the REAL `.level-badge` tiers (all ten + a chip context + a
    `.level-up-pop` demo), gated by `Studio.feature?(:leveling)` — greyed and
    flagged "disabled-but-present" on hosts (like McRitchie Studio) with leveling
    off, never hidden.
  - **Modals** is unchanged this pass (its real modal port lands next).

## 0.17.0 — 2026-07-27

### Added

- **`admin/design_system` — the living style guide (first slice).** A new
  admin-gated page (`DesignSystemController#index`, route
  `admin_design_system_path`) that renders the engine's shared UI primitives
  live in the host app's theme. The route is propagated to every consumer by
  `Studio.routes`, and the view is a bare content wrapper that renders inside
  each host's `application.html.erb`, inheriting that app's navbar + theme. This
  slice ships the **Style** section — a grouped, live gallery where each
  specimen shows the rendered primitive, its class name, and a copyable usage
  snippet: **Buttons** (`.btn` + every role variant + `.btn-sm` / `.btn-lg`
  sizes), **Surfaces / text / form** (`.card`, `.card-hover`, `.badge`,
  `.input-field`, `.empty-state`, `.label-upper`), the seven **Motion**
  primitives from `engine-motion.css` (`.studio-border-glow`, `.spinner`,
  `.loading-dots`, `.sheen`, `.ping`, `.fade-edge-*`, `.progress-meter`) each
  with tunable CSS-var knobs demonstrated, and the seven **Theme tokens** as
  swatches read live off `var(--color-*)`. Specimens use ONLY the engine's own
  classes, so a consumer that bundles `engine.css` and imports
  `engine-motion.css` styles them for real (nothing is inlined). The Modals,
  Theme, and Tasks sections are later slices.

## 0.16.0 — 2026-07-26

### Added

- **Motion / effect primitive layer** — a new, OPT-IN stylesheet at
  `app/assets/tailwind/studio_engine/engine-motion.css` consolidating seven
  reusable animation + visual-effect primitives that had drifted across the MS
  and TM apps: `.studio-border-glow` (mask-composite rainbow border),
  `.spinner` (one canonical border spinner), `.loading-dots` (three bouncing
  dots), `.sheen` (sweep-of-light), `.ping` (expanding pulse ring),
  `.fade-edge` (static mask-image edge fade), and `.progress-meter` (a
  dual-layer color-flip progress bar). Plain `.class` + `@keyframes` (not
  `@utility`), themed through the 7-role CSS custom properties, every knob a
  tunable CSS var. It does NOT auto-bundle: `tailwindcss:engines` only
  generates an entry for the file literally named `engine.css`, so consumers
  adopt this layer deliberately with a single `@import` (see the file header).
  App-side de-fork of the local copies is a follow-up task.

## 0.14.0 — 2026-07-22

### Added

- **Passwordless engine login** — the stock `sessions/new` sign-in view now
  renders its method set from `auth_methods`, so a host app configured for
  passwordless sign-in gets the correct engine-shipped view with no local
  override. Fixes a 500 in the passwordless path where the view assumed a
  password field.

## 0.13.1 — 2026-07-19

### Changed

- **CI runs the engine's own suite from a glob-derived manifest** (PR #18) —
  `bin/release-check` now derives its test manifest by globbing the tree
  instead of keeping a hand-maintained list, and a suite-guard trips if any
  test file goes unrun; bundler is set up before any other require so the
  guard's invariant holds from boot. Internal CI tooling only — no
  consumer-facing change.

## 0.13.0 — 2026-07-19

### Added

- **Engine-shipped component CSS** — `.card`/`.btn*`/`.badge`/`.input-field`/`.empty-state` + `text-2xs`/`text-3xs` preset tokens; consumers adopt with `@import "../builds/tailwind/studio_engine";` (docs/NEW_APP_SETUP.md section 13).
- **De-forked UI primitives** — the modal host upstreams Turf's animated host (inline keyframes, `window.ModalAnimations` registry, `enterAnim`/`exitAnim` props, directional `swap()`/`advance()`; API superset of the old host — behavioral deltas listed in the README), and `components/user_nav` gains partial slots (`balance_slot`/`extra_icons_slot`/`div2_slot`) with the legacy `*_html` string locals still honored.

### Fixed

- **Theme invariants scan class attributes, not prose** — the used-classes
  invariant extracts `class="..."` / `class: "..."` contents before tokenizing,
  so a comment mentioning a `card-*`/`btn-*` token no longer trips it; the
  theme-var invariant now asserts per mode (dark AND light) instead of the
  union, so a var emitted in only one mode cannot pass.
- **Modal host review fixes** — `cardClasses()` no longer clobbers registry
  `slide` animations (the directional swap flags are guarded, so
  `enterAnim`/`exitAnim: "slide"` resolve to real classes instead of a frozen
  220ms snap); the README's behavioral-delta wording is corrected; and a
  node-executed store suite hardens the rendered modal store (cardClasses
  resolution, registry merge, animated close timing, swap races, late registry
  replacement).
- **Consumer checkout fetches full history** — the consumer-CI checkout uses
  `fetch-depth: 0` so the hub's e2e quarantine ratchet can resolve
  `origin/release` (the default depth-1 single-ref checkout left the baseline
  ref unresolvable, which is red by design).

## 0.12.1 — 2026-07-11

### Fixed
- **Sticky table headers: skip self-pinning tables** — `shouldEnhanceTable`
  now declines tables whose header cells are already `position: sticky`
  (they pin themselves inside their own scroll container). Cloning such a
  table doubled the header, and the activation math misfired: the in-flow
  `thead` box scrolls under the nav while the sticky `th` cells stay pinned
  and visible. Upstreamed from mcritchie-studio's local copy so consumers can
  drop their forks and enable `Studio.sticky_table_headers`.

## 0.12.0 — 2026-07-08

### Added
- **Model-page protocol (v1)** — a reusable, admin-only per-record inspector,
  drawn into every consuming app via `Studio.routes`:
  `/models/:model/:id` renders one record as pretty JSON plus a copy/paste
  rails-console command to reload it, and `/models/:model/random` bounces to a
  random record of that model. New `Studio::ModelsController` +
  `app/views/studio/models/show.html.erb` (theme-token styled, reuses the
  `components/copy_button` partial). The protocol object `Studio::ModelPage`
  ships an **empty registry** — no model is reachable until a host opts in with
  `Studio::ModelPage.register("release", Release, lookup: :slug)` in an
  initializer (mirrors the admin-models host-registry pattern; the engine never
  constantizes host models by name). Gated with `require_admin`.

## 0.11.0 — 2026-06-24

### Changed
- **Rails 8.1 support** — widened the gemspec `rails` bound from
  `">= 7.0", "< 8.0"` to `">= 7.2", "< 8.2"`, so consuming apps can migrate to
  Rails 8.1 independently (the engine no longer pins the ecosystem to Rails 7).
  This release is the gate for the McRitchie Rails 8.1 train — `mcritchie-studio`
  and `turf-monster` can bundle Rails 8.1 only once this version is published.
  The lower bound moves to 7.2 (the oldest Rails the apps actually run) since
  Rails 8 requires Ruby >= 3.2 and the ecosystem is already on Ruby 3.3.11.

### Added
- **`test/dummy` Rails app + `test/integration/engine_rails_8_1_boot_test.rb`** —
  boots the engine inside a real Rails app and exercises its Rails-version-
  sensitive surfaces (the Railtie registration, Zeitwerk autoload wiring, the
  `Studio.routes` DSL, and the `ErrorLog` / `ThemeSetting` / `Sluggable`
  ActiveRecord models). Re-run this against any new Rails line before widening
  the bound again. The engine's full unit suite + this boot test are green
  against Rails 8.1.3 (ActiveSupport/ActiveRecord 8.1, Zeitwerk 2.8, minitest 6).

### Fixed
- `bin/release-check` now prefers the `ruby@3.3` toolchain (was pinned to the
  retired `ruby@3.1`, which cannot resolve Rails 8.1) and runs the full test
  list, including the new Rails 8.1 boot test and the previously-omitted
  `link_token` / sticky-header / admin-models-table tests.

## 0.10.0 — 2026-06-24

### Added
- **Shared websocket / Redis primitive** (`docs/CABLE.md`) — one place for the
  setup every host app's realtime needs, extracted after a SEV-1 (a host app
  shipped an ActionCable channel with no `redis` gem and no TLS cable config; the
  broadcast raised `Gem::LoadError` — a `ScriptError`, not a `StandardError` — which
  escaped a `rescue StandardError` and 500'd every task write).
  - **`redis` is now an engine dependency** (plus `turbo-rails`), so a consuming app
    can never hit that `Gem::LoadError` again.
  - **`Studio::Redis`** — the single source of Redis connection truth for `cable.yml`,
    the `cache_store`, and Sidekiq: `.url`, `.tls?`, and `.options(**extra)`, which
    auto-applies `ssl_params: { verify_mode: VERIFY_NONE }` for Heroku's `rediss://`
    self-signed TLS (the gotcha that silently drops every broadcast).
  - **`Studio::Cable.safe_broadcast { … }`** — best-effort broadcast guard that
    catches `StandardError` **and** `ScriptError`, so a cable failure never breaks
    the caller (the exact hole that caused the SEV-1).
  - **`Studio::Broadcastable`** — model concern with safe Turbo-Streams wrappers
    (`safe_broadcast_replace_to`, `_append_to`, `_prepend_to`, `_update_to`,
    `_remove_to`) every app should broadcast through.

## 0.9.0 — 2026-06-23

### Added
- **`Studio::Enumeral`** — a shared, DB-backed enumeration table for the whole
  ecosystem. Every "list of fixed, labeled, colored values" (Pokémon types first;
  statuses/tiers/roles later) is rows in ONE `studio_enumerals` table, grouped by
  `category`: a stable machine `key`, a human `label`, a `color` hex, a display
  `position`, a sparse `rank` (gappy 100/200/… domain ranking — e.g. most-common
  first — distinct from display order), and `metadata` (jsonb) for
  category-specific extras. Class helpers `catalog`, `lookup`, `color_map` (one
  query → `{ key => color }`), `color_for(category, key, fallback:)`, and a
  metadata-backed `emoji` reader + `emoji_map` (decorative glyphs live in
  `metadata`, not a column); scopes `ordered` / `by_rank`; `available?` degrades
  to empty when the table isn't installed. Shipped by the gem like `Studio::Link` /
  `Studio::EmailDelivery` — reference migration `create_studio_enumerals`
  installed per app (copy into `db/migrate`). No behavior is attached: a consumer
  adopts a new category by seeding rows, no code change.

## 0.8.0 — 2026-06-21

### Added
- **`Studio::Link` + unified `/l/<token>`** — one short-token model + entry point
  for both single-use, expiring **magic_link**s and reusable, non-expiring
  **referral** links. Polymorphic `linkable` (optional), `metadata` jsonb (email/
  return_to/target/age_attested off the wire), nullable `expires_at`, atomic
  single-use consume. `Studio::LinkToken` holds the pure token/kind/sanitizer
  logic (unit-tested without a DB); `Studio::LinksController` dispatches by kind
  (magic → scanner-safe confirm + POST consume; referral → attribution cookie +
  redirect). `Studio::LinkConsumption` concern shares sign-in/sign-up. Reference
  migration `create_studio_links` (installed per app like `studio_email_deliveries`).
- **`Studio.magic_link_store`** (`:signed` default | `:database`) and
  **`Studio.draw_link_routes`** flags. `:database` mints `Studio::Link`s and
  emails the short `/l/<token>` (vs the legacy `/magic_link/<MessageVerifier>`);
  fully back-compatible — the default leaves existing consumers untouched.
- **Branded mailer** lifted into the engine: `layouts/branded_mailer` + a branded
  `UserMailer#magic_link` body (theme-colored button, banner-aware). Apps with
  their own `UserMailer`/`branded_mailer` still win.
- **`Studio::EmailImage`** + **`/admin/email_images`** (admin-gated) — manage the
  banner image on transactional emails (magic-link now; per-variant registry is
  the extension point). Backed by `Studio::S3` + an owner-less `ImageCache` row
  (permanent public URL, nil-safe pre-upload).

### Changed
- `ImageCache#owner` is now optional (+ reference migration to drop the owner
  `NOT NULL`), so app-global images (e.g. email banners) can be cached.

## v0.7.0 (2026-06-20)

### Added
- **`admin_model_table` helper** (`Studio::AdminModelsTableHelper`) — a shared
  shell for `/admin/models` tables (overflow wrapper, `thead`, hover rows,
  colspan empty state). Each consumer `_<key>_table` partial now declares only
  its columns via `headers:` plus a per-row block; the helper is exposed
  automatically through the `Studio::AdminModels` concern. Removes the duplicated
  table boilerplate across mcritchie-studio and turf-monster.

## v0.6.2 (2026-06-19)

### Added
- **`Studio.sticky_table_headers` opt-in** for shared sticky table headers. The
  flag defaults off and, when enabled by a consumer app, loads the engine-owned
  `studio/sticky_table_header.css` and `studio/sticky_table_header.js` assets
  from the shared Studio head partial.

## v0.6.1 (2026-06-18)

### Added
- **`components/emoji_swap` UI primitive** plus shared CSS for nav/sidebar
  emoji hover and focus transitions, including reduced-motion fallback and
  aliases for the existing `nav-emoji-*` class names.

## v0.6.0 (2026-06-16)

### Changed
- Require `tailwindcss-rails ~> 4.5` so Studio apps can move onto the
  Tailwind CSS v4 build chain together.

## v0.5.10 (2026-06-15)

### Added
- **`Studio::AdminModels`** shared controller concern plus shared admin model
  index/show shells and teams/arenas table partials. Consumer apps define their
  model registry and scopes locally, while shared pagination, team sorting,
  sport emoji display, team JSON modal payloads, and model page framing live in
  the engine.
- **Shared operator primitives** under `studio/banners/*` for non-production
  environment banners, the shared banner button, Dev Mode controls, email
  connector status, and admin impersonation banners. Consumers can render
  `studio/banners/environment` and `studio/banners/impersonation`.
- **`Studio::Impersonation`** opt-in concern for Act As session conventions:
  `true_user`, `impersonated_user`, `impersonating?`,
  `start_impersonation_session`, and `clear_impersonation_session`. Consumer
  apps still own authorization, audit logging, routes, and app-specific safety
  rules.
- **`StudioEmailDeliveryHelper#email_delivery_banner_details`** returns the
  structured connector, provider icon, send/capture state, and tooltip used by
  the shared email status button.

## v0.5.9 (2026-06-14)

### Added
- **`bin/rails "email:smoke[to@example.com]"`** — shared provider smoke-test
  task that sends one direct ActionMailer message through the current transport
  and prints the app, sender, transport, delivery method, `perform_deliveries`,
  external-send status, and message id. It refuses capture/test/file modes by
  default so agents do not mistake swallowed mail for a provider proof.

## v0.5.8 (2026-06-14)

### Added
- **`StudioEmailDeliveryHelper#email_delivery_banner_status`** — shared
  non-production banner status text for whether the current process sends
  external email and which transport is active (`resend`, `ses`, `capture`, or
  the ActionMailer delivery method).

## v0.5.7 (2026-06-14)

### Added
- **`Studio.mailer_from_for_transport` / `Studio.marketing_from_for_transport`** —
  provider-aware sender helpers. SES-ready apps use app/domain-specific
  `MAILER_FROM` and `MARKETING_MAILER_FROM`; Resend fallback uses
  `RESEND_MAILER_FROM`, defaulting to `McRitchie Studio <team@mcritchie.studio>`
  so new apps can send during SES sandbox/presetup without verifying a second
  Resend domain.

### Fixed
- **`ses:check` / `ses:verify_domain` credential selection** now prefers
  `SES_AWS_ACCESS_KEY_ID` / `SES_AWS_SECRET_ACCESS_KEY` before falling back to
  generic `AWS_*` credentials, keeping SES account checks separate from
  consumer app S3/ImageCache IAM users.
- **`ses:verify_domain` existing identity handling** now accepts AWS SES's
  `already exist` response wording and falls back to reading the existing
  identity.

## v0.5.6 (2026-06-14)

### Added
- **`Studio.wallet_address_method` / `Studio.user_wallet_address(user)`** —
  shared wallet-address adapter for SSO/session awareness. Defaults support
  `wallet_address` and `solana_address`; apps can configure another method.

## v0.5.5 (2026-06-14)

### Added
- **Local email inbox** at `/_studio/local_emails` for non-production localhost requests. It lists recent outbox rows and exposes local proof links for magic-link, email-verification, wallet-export, and email-change emails.
- **`Studio.local_email_capture?`** — shared capture switch for local/worktree stacks. `LOCAL_EMAIL_CAPTURE=1` or `AGENT_WORKTREE=1` records delivery rows without enqueueing external sends.

## v0.5.4 (2026-06-14)

### Changed
- Engine magic links are now scanner-safe: emailed links land on an inert GET confirmation page, and the token is consumed only by the CSRF-protected POST from that page.
- Added the shared `magic_link_consume_path` route helper for consumer apps using engine-drawn auth routes.

## v0.5.3 (2026-06-14)

### Added
- **`Studio::Email.deliver`** — shared ActionMailer delivery entry point that uses an app-level `EmailDelivery` when present, the engine's namespaced durable outbox when installed, and raw `deliver_later` as a fallback.
- **`Studio::EmailDelivery` / `Studio::EmailDeliveryJob`** — namespaced durable delivery rows for apps that want shared audit, retry, and resend recovery without colliding with an existing top-level `EmailDelivery` model.
- **`studio_email_deliveries` migration template** — installable shared outbox table for new or migrating consumer apps.

### Changed
- Engine magic-link and passwordless signup controllers now send through `Studio::Email.deliver` instead of calling `deliver_later` directly.

## v0.5.2 (2026-06-13)

### Added
- **`Studio::MailTransport`** — shared ActionMailer transport selection for SES SMTP primary and Resend rollback.
- **`ses:check` / `ses:verify_domain`** — shared Rake tasks for SES credential and domain verification checks.
- **`bin/release-check`** — local preflight for Ruby syntax, engine unit tests, and optional gem packaging.

### Changed
- Engine release docs now describe the RubyGems flow and consumer lockfile adoption instead of the legacy git tag pinning flow.
- Runtime dependency ranges are now bounded for cleaner RubyGems releases while preserving the current Rails 7 / Solid Queue 1.x app stack.
- `resend` is declared as an engine runtime dependency so consumer apps can drop direct rollback dependencies after they bundle the release that includes `Studio::MailTransport`.

## v0.5.1 (2026-06-02)

Smooths the turf-monster adoption of the v0.5.0 auth core (turf already ships its own battle-tested auth routes).

### Added
- **`Studio.draw_auth_routes`** (default `true`) — gates the `magic_link` + `solana` route block in `Studio.routes`. An app that already defines those routes (turf-monster) sets it `false` to keep its own routes and avoid a duplicate route-NAME boot crash.

### Changed
- **`MagicLink`** re-exposes `TOKEN_KEY` + `TTL` constants (equal to the config defaults) for back-compat with consumer code/tests that reference them; behavior is still driven by `Studio.magic_link_token_name` / `Studio.magic_link_ttl`.

## v0.5.0 (2026-06-02)

Promotes the **shared authentication core** out of Turf Monster into the engine so every Studio app runs one passwordless-first auth flow. This release is the **backend** half (services, POROs, concern helpers, base controllers, mailer); the shared wallet JS + Connect-Wallet modal land with the first consumer wiring. Turf Monster is **not** on this version yet — it stays on 0.4.x until its incremental migration.

### Added
- **`Studio.auth_methods`** config (default `%i[magic_link google wallet]`; `:password` opt-in) + `Studio.auth_method?(m)`. Login/signup surfaces render a field/button per enabled method. `:password` also re-arms the `User#authenticate` contract check.
- **`Studio.magic_link_ttl`** (15 min), **`Studio.magic_link_token_name`** (`"magic_link_v1"`), **`Studio.mailer_from`** config.
- **`SessionContext`** PORO — canonical guest/web2/web3 viewer state (`mode`, `to_h` camelCase for `Alpine.store('session')`). Wallet predicates are `respond_to?`-guarded so a wallet-less app is safe.
- **`Current`** baseline (`attribute :user`) — apps needing more request-scoped state override the file.
- **`MagicLink`** service — signed, single-use (jti in `Rails.cache`), URL-safe token; token name/TTL from config.
- **`GoogleOauthValidator`** — server-side `tokeninfo` re-check (audience / email_verified / expiry).
- **`Solana::SessionAuth`** concern — Rails-session adapter over `solana-studio`'s `Solana::AuthVerifier` (nonce delete-before-verify + host binding). solana-studio is host-provided; only loaded when wallet sign-in is on.
- **Base controllers** (generic; apps override for richer flows): `MagicLinksController` (create-or-login), `SolanaSessionsController` (nonce/verify), and an upgraded `OmniauthCallbacksController` (now runs `GoogleOauthValidator`).
- **`UserMailer#magic_link`** + `ApplicationMailer` (proc `from:` ← `Studio.mailer_from`) + app-name-aware templates.
- **Routes**: `Studio.routes` now draws `magic_link_request`/`magic_link` (when `:magic_link`) and `solana_nonce`/`solana_verify` (when `:wallet`), gated by `auth_method?`.

### Concern (`Studio::ErrorHandling`)
- `set_app_session` now binds a rotating `session[:session_token]` (OPSEC-045, guarded) and resets the `:onchain` flag; `clear_app_session` wipes both.
- `require_authentication` is now **format-aware** (HTML→redirect, JSON/Turbo→401, was a blind redirect that 406'd AJAX — OPSEC-046).
- New helpers: `set_current_context`, `verify_session_token` (guarded), `onchain_session?`, `wallet_context`, `client_session_payload` (identity-only baseline; apps override to merge balances).

### Breaking / Migration
- **`User.from_omniauth` contract is now `(auth, email_verified:)`** — the engine `OmniauthCallbacksController` passes the `GoogleOauthValidator` result. Consumers using the engine callback must update their `from_omniauth` to accept the kwarg.
- Consumers enabling `:magic_link` / `:wallet` must provide the User class methods the base controllers call (`User.find_by(email:)`, `User.from_solana_wallet(addr)`), the relevant columns (`email`, `email_verified_at`, `solana_address`, optional `session_token`), and `default_url_options` for mailer link generation.

## v0.4.13 (2026-06-02)

Promotes `components/_avatar_cropper` onto the shared crop-photo modal — completing the image-upload extraction started in v0.4.12. The avatar cropper is the **deferred-form-field** counterpart to `imageUploadHost`: it stages a cropped PNG on a hidden file input + shows a round preview, and the enclosing form (signup / profile edit) submits later (vs. `imageUploadHost`, which submits immediately).

### Changed
- **`components/_avatar_cropper`** now drives its crop through the shared `crop-photo` modal (`Alpine.store('modals').open('crop-photo', { imageUrl })`) and renders `studio/cropper_assets`, replacing the old bespoke `z-[110]` overlay + direct cropper.js load + the `avatarCropper()` factory (now `avatarCropperHost()`). The parent gets the cropped Blob back via the `crop-photo-confirmed` window event.

### Integration
Consumers rendering `components/avatar_cropper` now need the v0.4.12 image-upload integration: the `crop-photo` modal registered in the modal-host block (see v0.4.12 → Integration). The partial renders `studio/cropper_assets` itself, so cropper.js + the factories load where it's used.

### Migration
Apps that kept a local override of `components/_avatar_cropper` to route it through the shared modal (Turf Monster) can **delete the override** and use this.

## v0.4.12 (2026-06-02)

Promotes the image crop-and-upload UI out of Turf Monster into the engine: a shared cropper modal, the immediate-save upload host, the loading-card-around-a-Turbo-submit helper, and the generic "saving" card. Any consumer can now add a cropped image upload (avatar, banner, logo, OG image) with one `imageUploadHost(...)` x-data plus the cropper assets partial — no bespoke JS.

### Added
- **`studio/_cropper_assets`** — cropper.js (1.6.2) CSS + JS **and** the three inline factories below. Render it on pages that can open the cropper (avatar field, banner editor); both the library and the behavior load only where an upload trigger exists. The JS rides with the page, **not** the modal host, so it works whether or not an app overrides `studio/modals/_host`.
  - `window.imageUploadHost(opts)` — x-data host for crop-then-immediate-save uploaders. `open()` (modal-as-picker) / `onFileSelected()` (native picker) → `applyCrop()` drops the Blob into a hidden form input and submits with a loading card + toast.
  - `window.submitFormWithProgress(form, opts)` — opens the `saving` card, holds ≥450ms, submits the Turbo form, then closes + toasts on `turbo:submit-end`.
  - `window.cropPhotoModal(opts)` — the crop modal's x-data factory.
- **`studio/modals/_crop_photo`** — the shared image cropper modal. Opens via `Alpine.store('modals').open('crop-photo', { imageUrl?, aspectRatio?, maxWidth?, maxHeight?, transparent?, autoCropArea?, dispatch? })`; hands the cropped Blob back via the `crop-photo-confirmed` window event.
- **`studio/modals/_saving`** — generic loading card (title from `props.title`), opened by `submitFormWithProgress`.

### Integration
Register the two modals in your `studio/modals/host` block + render the assets on each upload page:
```erb
<%# inside the studio/modals/host block %>
<template x-if="$store.modals.current().id === 'crop-photo'"><%= render "studio/modals/crop_photo" %></template>
<template x-if="$store.modals.current().id === 'saving'"><%= render "studio/modals/saving" %></template>

<%# on each page with an image upload %>
<%= render "studio/cropper_assets" %>
<div x-data="imageUploadHost({ aspectRatio: 1, filename: 'avatar.png', saving: 'Saving photo…', dismissible: true, toast: false })"
     @crop-photo-confirmed.window="applyCrop($event.detail.blob)"> … hidden form (x-ref form + fileInput) + trigger … </div>
```
Registrations live in the host **block** (the consumer's `yield` content), so apps that override `studio/modals/_host` — like Turf Monster, which has a substantially diverged host — integrate the same way.

### Migration
For an app that had its own copies (Turf Monster):
1. `bundle update studio-engine`.
2. Delete the local `crop_photo_modal.js` (+ its importmap pin / `application.js` import), the `imageUploadHost` + `submitFormWithProgress` definitions, and `modals/_crop_photo` / `modals/_saving` / `shared/_cropper_assets`.
3. Point the host block's crop-photo / saving registrations at `studio/modals/crop_photo` / `studio/modals/saving`, and the cropper-asset renders at `studio/cropper_assets`.

## v0.4.11 (2026-05-24)

Preserves non-dismissible modals (e.g. pending on-chain TX) across bfcache restore and Turbo snapshot caching. Previously, the modal host's cleanup hooks called `closeAll()` on both `pageshow.persisted` and `turbo:before-cache`, which silently dropped any `dismissible: false` modal — including the processing card a still-in-flight JS promise was expecting to resolve against. The promise's `solanaModal.success()` then no-op'd against an empty stack and the user saw nothing despite their TX landing on-chain.

### Added
- **`Alpine.store('modals').closeAllDismissible()`** — drops every modal in the stack whose `props.dismissible !== false`, leaves locked modals in place.

### Changed
- **bfcache + Turbo snapshot cleanup** now calls `closeAllDismissible()` instead of `closeAll()`. Celebratory modals still clear on return; pending-TX modals survive.

### Migration
None required — celebratory modal behavior is unchanged. Consumers relying on `dismissible: false` (turf-monster's `onchain-tx` modal) gain crash-recovery for free.

## v0.4.10 (2026-05-23)

Lets consumer apps override toast z-indexes without `!important`. Previously, `#toast-container` set `z-index: 60` via an inline `style=` attribute, which forced any consumer override to use `!important`. Same source-order problem for `.toast-page-blur` (z-index in the inline `<style>` block here loaded after the consumer's `application.tailwind.css`). Both now read from CSS custom properties with the previous values as fallback defaults.

### Changed
- **`#toast-container`** z-index moved from inline `style=` to a CSS rule reading `var(--studio-toast-z, 60)`.
- **`.toast-page-blur`** z-index now reads `var(--studio-toast-blur-z, 55)`.

### Migration
None required — defaults preserve existing behavior. Apps that need higher z-indexes (e.g. to stack above a `z-50`/`z-110` sticky navbar) can now set the variables on `:root` in their stylesheet and drop their `!important` workaround:
```css
:root {
  --studio-toast-z: 120;
  --studio-toast-blur-z: 115;
}
```

## v0.4.9 (2026-05-23)

Modal success_card upgrades — canonical "celebration" look for any modal that needs an Entry / Action / Payment confirmed card. All options additive; existing callers unaffected.

### Added
- **`_success_card` — `large_title:`** boolean. Bumps the headline from `text-lg` to `text-3xl` (the celebration look).
- **`_success_card` — `title_key:` / `message_key:`** Alpine-expression locals for live-driven headline + subtitle. Lets a card track a store as labels mutate without re-mounting (paired with the same option on `_processing_card` in v0.4.6).
- **`_success_card` — `tx_solana:`** boolean. Upgrades the tx-signature explorer link from the plain underlined-hash style to a boxed pill with the Solana brand mark (gradient SVG, three diagonal bars) on the left and a launch arrow on the right. Same `tx_signature_key` Alpine expression drives both variants.
- **`_success_card` — `cta_drain:`** boolean. When paired with `auto_redirect_url_key`, the countdown drains as a translucent overlay on the CTA button itself — no separate progress bar / "Redirecting in Xs…" text. The celebration look. Uses the new `@keyframes studio-modal-drain` defined in the host's style block.
- **`_success_card` — yield block.** Callers can pass an inline block; the card renders it below the CTA. Used by turf-monster's onchain-tx modal to slot in the seeds-bar + level-up celebration without forking the partial.

### Migration
None required. Apps that don't set the new options keep the existing default look.

## v0.4.8 (2026-05-23)

Bugfix follow-up to v0.4.7. The v0.4.7 fix removed the ERB-escape example from the doc comment, but the same comment still referenced the bug it had just fixed using literal ERB-tag characters (the words "ERB <%# %> terminates at the first %> sequence" sit inside an ERB comment that uses `%>` as its terminator — recursive footgun). The first inline `%>` ended the outer comment and the rest leaked again.

### Fixed
- **`studio/modals/host` comment leak (v0.4.6 + v0.4.7).** Rewrote the doc comment to contain zero `%` characters; ERB now sees the entire block as a single comment. No API change.

## v0.4.7 (2026-05-23)

Bugfix — modal host doc-comment was leaking into rendered pages.

### Fixed
- **`studio/modals/host` comment block terminated early.** The leading comment in `_host.html.erb` contained a worked example of the consumer render-block syntax using literal ERB escape sequences. ERB scans for the first tag-close to close the comment, and the escape sequences end in one — so the comment terminated mid-escape, leaving the rest as literal output at the bottom of every page. (See v0.4.8 — this v0.4.7 fix was itself incomplete.)

## v0.4.6 (2026-05-23)

Small follow-up to 0.4.5 — modal dismissibility opt-out.

### Added
- **`props.dismissible: false`** on a modal's props now suppresses escape-key + click-outside close. Required for flows that mustn't be interrupted mid-step — on-chain TX while a Phantom signature is pending, multi-stage withdrawals, etc. Defaults to true (existing behavior). Set per-modal:
  ```js
  $store.modals.open('onchain-tx', { state: 'processing', dismissible: false });
  // ...later, when the TX confirms:
  $store.modals.current().props.dismissible = true;  // user can now close
  ```

## v0.4.5 (2026-05-23)

Modal infrastructure — same shape as the toast system from v0.4.0. Apps render `studio/modals/host` once, then open through `Alpine.store('modals')` and compose the shared content blocks. No migration required for v0.4.4 consumers.

### Added
- **`studio/modals/host` partial.** Single shared shell that bundles the scroll-lock CSS, bfcache/Turbo snapshot cleanup, `Alpine.store('modals')` registration (stack-based), `window.StudioModals.holdAtLeast(ms)` helper, and the modal markup (z-[120] backdrop, fade-and-scale transitions, escape/click-outside/ARIA dialog). Consumer renders once in `application.html.erb` with a block that registers their app-specific content partials by id:
  ```erb
  <%= render "studio/modals/host" do %>
    <template x-if="$store.modals.current().id === 'auth'">
      <%= render "modals/auth" %>
    </template>
  <% end %>
  ```
- **`Alpine.store('modals')` stack store.** API: `open(id, props, opts)` (with `opts.replace: true` for flicker-free transitions between steps in a wizard), `close()`, `closeAll()`, `isOpen(id)`, `current()`. Auto-syncs `body.modal-open` for scroll lock. Stack-based so modals can nest (e.g. confirm-on-top-of-form).
- **`window.StudioModals.holdAtLeast(ms)` helper.** Stamps the moment a loading view becomes visible, returns `{ then(callback) }` that delays the callback by the remaining time if the operation finished before the minimum. Replaces ad-hoc `Date.now() - startedAt` arithmetic at every async-success site. Mirrors `_navSpinnerMinMs` from `_head.html.erb`.
- **Four reusable content-block partials in `studio/modals/blocks/`.** Composable building blocks any modal can render to assemble its inner content:
  - `_success_card` — icon (default green check, or any emoji), title, optional sub-text, optional Solana tx-signature explorer link, primary CTA (href or dispatched event), secondary CTA, **self-driven auto-redirect countdown** (progress bar + "Xs…" text, fires `window.location.href` at zero), and **opt-in confetti** burst via `window.fireSuccessConfetti`.
  - `_error_card` — emoji icon (default ⏳, configurable for ⚠️ / 📍 / etc.), title, message (static string or Alpine-expression key for live updates), CTA that can reload the page, dispatch an event, or be omitted.
  - `_processing_card` — spinner (sm/md/lg, three color tokens) + title + optional message. Designed to pair with `holdAtLeast` on the caller side.
  - `_progress_countdown` — standalone progress bar + countdown text. Reads display values from caller-provided Alpine expressions so externally-driven countdowns (board's `setInterval` mutating `$store.modals` props) and internally-driven ones (success card's own timer) can share the same visualization.

### Architecture
- **Content vs. blocks.** Each consumer app owns its modal *content* partials (turf-monster's `modals/auth`, mcritchie-studio's account flows, etc.) because the flows are product-specific. The engine provides the *shell* (host) and the *building blocks* (cards) because those are universal UI vocabulary.
- **Single root requirement** on modal content partials — Alpine's `<template x-if>` clones only the first root element from its content. Top-level `<style>` blocks or stray siblings are silently dropped. Bake the style inside the partial's outer wrapping `<div>` if needed.

## v0.4.4 (2026-05-20)

Sticky-navbar scroll fixes — bounce-free for every consuming app, no migration required.

### Fixed
- **Navbar scroll-collapse bounce.** A `position: sticky` navbar that shrinks on scroll changes layout above the fold; Chrome/Firefox scroll-anchoring then compensates by moving `scrollY`, which re-crosses the collapse threshold and oscillates. `_head.html.erb` now ships `body { overflow-anchor: none }`, so the navbar resize no longer drags `scrollY`. Every app that renders `layouts/studio/head` gets this automatically.
- **Navbar unscroll threshold `20 → 5`** in `_navbar.html.erb` — widens the hysteresis dead zone (5/60) so a height change can't push `scrollY` back across the lower bound.

### Added
- **`--nav-h` CSS variable.** `_head.html.erb` ships a `ResizeObserver` that publishes the page header's live height to `--nav-h` on `:root` — updated on every resize (including the collapse animation) and re-attached after Turbo navigations. Fixed/sticky elements below the navbar can position off `var(--nav-h)` instead of hardcoded px (e.g. `style="top: var(--nav-h)"`). Auto-detects the page `<header>`; no markup changes needed.

## v0.4.3 (2026-05-19)

Tier-3 fix from the turf-monster pre-prod opsec audit (OPSEC-016).

### Fixed (security)
- **`GET /sso_login` no longer mutates the session (OPSEC-016).** The action previously called `authenticate_sso_user!` directly — starting a session on a GET. GETs are not CSRF-covered and are prefetchable (`<img>`, `<link rel=prefetch>`, browser prefetch), so an XSS on any `*.mcritchie.studio` subdomain that wrote `session[:sso_email]` could have a forged `/sso_login` hit silently start a session as that user. `sso_login` now only redirects to the login page; the session mutation happens exclusively through the CSRF-protected `POST /sso_continue` ("Continue as …" button).

### Changed
- The hub's one-click SSO link to a satellite's `/sso_login` now lands the user on the satellite login page with the "Continue as …" button instead of logging them in directly — one extra click, and the GET endpoint is no longer a session-mutation vector.

## v0.4.2 (2026-05-19)

Security follow-up to v0.4.1 — closes a cross-app session-fixation surface.

### Fixed (security)
- **Removed legacy `session[:user_id]` fallback in `Studio::ErrorHandling#current_user`** (OPSEC-042). Previously, if `session[Studio.session_key]` was empty but `session[:user_id]` was present, the engine would look up the user by that ID and silently call `set_app_session(user)` — promoting an arbitrary user ID to logged-in status. Combined with the shared `*.mcritchie.studio` cookie scope, any XSS on any subdomain that wrote `session[:user_id]` became cross-app login-as-anyone. The legacy key was a Devise-era migration carrier; consumer apps no longer write to it. Removing the fallback closes the fixation surface.

### Breaking
- Any user with a stale session that still has `session[:user_id]` set but NOT `session[Studio.session_key]` will be logged out on next request. Practically: nobody, since the engine has been writing `session[Studio.session_key]` since v0.2.x.

## v0.4.1 (2026-05-17)

Pre-public-release security hardening per `SECURITY-AUDIT-2026-05-17.md`.

### Fixed (security)
- **SSRF guard in `Studio::ImageCache.cache!`** — `source_url` is now validated: rejects schemes other than http/https, blocks loopback / private / link-local IPs (incl. AWS metadata 169.254.169.254), and blocks `localhost` / `*.local` / `*.internal` / `*.lan` hostnames. Raises `Studio::ImageCache::InvalidSourceURL`. Does not defend against DNS rebinding.
- **MIME-type allowlist in `Studio::ImageCache.cache!`** — `content_type` must be one of `ALLOWED_CONTENT_TYPES` (image/png|jpeg|jpg|webp|gif). Raises `Studio::ImageCache::UnsupportedContentType`.
- **MiniMagick resource caps per invocation** — every resize runs with `-limit memory 256MB -limit map 512MB -limit width/height 16KP` to prevent decompression-bomb DoS.
- **Remote source size cap** — `MAX_REMOTE_BYTES = 50MB`. Raises `Studio::ImageCache::SourceTooLarge` on overage.
- **`ErrorLog.capture!` no longer stores `exception.inspect`** — Ruby's default inspect for many error subclasses includes ivar dumps that can carry secrets (API keys read into locals, request bodies). Now stores a sanitized `"#<{class}: {message[0,1000]}>"` instead.

### Changed (breaking for misconfigured users only)
- **`Studio.s3_bucket_prefix` no longer defaults to `"mcritchie-studio"`.** Default is `nil`; host apps MUST set explicitly in `config/initializers/studio.rb`. Both current consumer apps already do this — no impact in practice.
- **`Studio.UserContractError` message** now points at the correct repo URL (`amcritchie/studio-engine`, not `amcritchie/studio`).

### Added
- `LICENSE` file (MIT) — gemspec already declared MIT but the file was missing. Required for RubyGems listing.
- Gemspec author email changed from `alex@mcritchie.studio` (personal) to `studio-engine@mcritchie.studio` (project alias).

## v0.4.0 (2026-05-17)

### Changed (breaking)
- **Gem renamed from `studio` to `studio-engine`.** Repo URL is now `github.com/amcritchie/studio-engine` (was `.../studio`). Consumers must update their `Gemfile`:
  ```ruby
  # Before:
  gem "studio", git: "https://github.com/amcritchie/studio.git", tag: "v0.3.1"
  # After:
  gem "studio-engine", git: "https://github.com/amcritchie/studio-engine.git", tag: "v0.4.0"
  ```
- The Ruby `Studio` module name is **unchanged** — all call sites (`Studio.configure`, `Studio::ErrorHandling`, `Studio::ImageCache`, etc.) keep working without code changes.
- Gem entry point at `lib/studio-engine.rb` (a thin `require_relative "studio"` shim) ensures `gem "studio-engine"` auto-requires correctly without a `require:` option in the Gemfile.

### Added
- `LICENSE`, gemspec `metadata` (homepage / source / bugs / changelog URIs), `spec.description`, `spec.required_ruby_version` — getting ready for RubyGems publishing.

## v0.3.1 (2026-05-17)

### Fixed
- `Studio.validate_user_contract!` no longer checks for `User#email` (or any column-style attribute). ActiveRecord defines column accessors lazily, so they don't appear on `.instance_methods` until first record access — leading to false-positive `Studio::UserContractError` raises at boot. Only explicitly-defined methods (`authenticate`, `admin?`, `display_name`, class `find_by`) are validated. DB columns are out of scope; missing columns fail the User table migration instead.

## v0.3.0 (2026-05-17)

### Added
- **Shared stage-* badge palette.** New scheme aliases on `app/views/components/_badge.html.erb`: `stage-fresh` (blue), `stage-shaping` (yellow), `stage-structured` (mint), `stage-refined` (emerald), `stage-cohered` (violet), `stage-shipped` (emerald), `stage-closed` (gray). Consumer apps' News + Content stage helpers can now resolve to a unified palette instead of each picking ad-hoc scheme names per stage. Closes ecosystem-audit Tier 1 #2.
- **`Studio.validate_user_contract!`** + boot-time validator hook in `Engine#after_initialize`. Verifies host's `User` class responds to required methods (`authenticate`, `admin?`, `email`, `display_name`, plus class `find_by`). Raises `Studio::UserContractError` with a clear pointer to `docs/USER_CONTRACT.md` when something's missing — replaces the previous cryptic `NoMethodError` at first request. Opt out per-app with `Studio.validate_user_contract = false`. Closes ecosystem-audit Tier 2 #16.
- **`docs/USER_CONTRACT.md`** — full reference for required + optional User methods, recommended DB columns, and a minimal compliant model example.
- **Sentry fan-out from `ErrorLog.capture!`.** When the host app has loaded `sentry-ruby` (and Sentry is initialized via DSN), every `ErrorLog.capture!` call also sends the exception to Sentry with `error_log_slug` as a tag for cross-reference. Apps without `sentry-ruby` are unaffected — the call is guarded with `defined?(::Sentry)`. Closes ecosystem-audit Tier 2 #15.

### Changed
- Stage badge color schemes are additive — existing `success/danger/warning/info/violet/primary/orange/emerald/gray/neutral` schemes unchanged.

### Notes
- Both current consumer apps (mcritchie-studio, turf-monster) already satisfy the new User contract — validator is a no-op for them.

## v0.2.4 (pre-2026-05-17)

Last release before formal versioning. Consumer apps tracked `git: main` until this point. v0.2.4 is the snapshot at the previous commit `ef738ff` ("Studio::ImageCache.cache! accepts source_path for local files"). Anything before that is in `git log`.
