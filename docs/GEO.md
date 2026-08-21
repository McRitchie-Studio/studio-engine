# Geo — validation and locking

Where a visitor appears to be, and whether this app is willing to serve them
there. Every app that installs the engine gets the capacity; each app decides
what it locks.

The split, because it is the whole design:

| | What the engine owns | What your app owns |
|---|---|---|
| **Validation** | IP → country + subdivision, cached per session; the badge; the policy; the operator's page | nothing — include one concern |
| **Locking** | `require_geo_allowed`, one before_action | **which surfaces it protects**, the copy, where a blocked visitor lands |

Locking is deliberately loose. "Which actions are geo-restricted" is a product and
legal question, not a framework one — an app that pays out money locks its
payouts, an app that streams video locks its player, and a marketing site locks
nothing at all and still wants the badge.

---

## Quick start

**1. Install the table.**

```bash
bin/rails studio_engine:install:migrations && bin/rails db:migrate
```

**2. Include the concern in `ApplicationController`.**

```ruby
class ApplicationController < ActionController::Base
  include Studio::GeoDetection
end
```

That alone gives every controller and view `geo_country`, `geo_state`
(alias `geo_subdivision`), `geo_region_token`, `geo_blocked?` and
`geo_override_active?`, plus detection on every request.

**3. Declare the policy in `config/initializers/studio.rb`.**

```ruby
Studio.configure do |config|
  config.geo_home_country = "US"
  config.geo_default_banned_subdivisions = %w[WA ID MT LA AZ HI NV CA]
  config.geo_default_banned_countries = []
  config.geo_development_region = ENV.fetch("DEV_GEO_STATE", "US-CO")
  config.draw_geo_routes = true   # /admin/geo + /geo/check
end
```

**4. Lock what needs locking.**

```ruby
class WalletsController < ApplicationController
  before_action :require_geo_allowed, only: %i[withdraw deposit]
end
```

**5. Render the badge** wherever the visitor should see where they stand:

```erb
<%= render "components/geo_badge" %>
```

Webhooks and health checks should skip detection — they have no visitor:

```ruby
skip_before_action :detect_geo_state
```

---

## The vocabulary

| Term | Example | Meaning |
|---|---|---|
| country | `US` | ISO 3166-1 alpha-2, upcased |
| subdivision | `WA` | the state/province/region code **within** a country |
| region token | `US-WA` | the two joined — the only form stored |

The token is not ceremony. **`CA` is California and Canada.** A ban list of bare
codes cannot say which one it means; a list of tokens always can. Bare codes are
still accepted everywhere on input (a checkbox grid posts them, and an app
migrating from a US-only list has years of them) and are normalized against
`Studio.geo_home_country` before they are written.

A country with no subdivision is written `CU-` and reads back as
`["CU", nil]`.

---

## The policy

`Studio::Geo.blocked?` is pure, and it is the only place the rules live. Three
ways to be blocked:

1. the resolved **country** is on `banned_countries`;
2. the resolved **region** is on `banned_subdivisions`;
3. **fail closed** — the app blocks specific subdivisions of its own country, and
   this visitor is in that country with **no detectable subdivision**.

Rule 3 is the subtle one and the reason no app should write its own gate. A blank
subdivision is usually a VPN, a datacenter IP, a provider outage or a lookup
timeout — and it could be any of the blocked regions wearing a mask. So an
unplaceable **home-country** visitor is treated as blocked.

Two deliberate narrowings:

- It only fires when subdivision rules for the home country actually exist. An
  app that blocks nothing at that grain is hiding nothing, so failing its
  unplaceable visitors closed would cost real access to protect no rule.
- A **resolved foreign** country with a blank region stays allowed. Only the
  home-country ambiguity is dangerous.

Set `Studio.geo_fail_closed = false` if your rules are advisory rather than legal.

The operator's kill switch (`enabled` on the row, off until someone turns it on)
means **off** — including for visitors the app cannot place. That is the state an
operator flips to when the gate is misfiring, so it has to release everyone.

---

## Finding the page — the signpost, in whichever chrome the app has

The **Geo** row is one partial, `components/_geo_signpost`, and both
engine-owned admin chromes render it. It links `/admin/geo` when two things are
true, and otherwise renders **disabled, naming the one that is missing**:

| State | What the row does |
|---|---|
| `ENABLE_GEO_BLOCKING` truthy **and** routes drawn | links the manager |
| routes drawn, variable off | disabled — "Set ENABLE_GEO_BLOCKING=true" |
| routes not drawn | disabled — "Draw the geo routes first `config.draw_geo_routes = true`" |

**The disabled row hands over a string, so it is built to be copied.** The
machine string is its own `<code>` element, which is what keeps it inside the
dropdown's narrow panel — it carries `break-all` alone, so it wraps mid-token
while the prose beside it still breaks at word boundaries. The row carries no
`select-none`: an operator must be able to select the thing they came for. It
announces as `role="link"` with `aria-disabled="true"`, and the fix is VISIBLE
text rather than a mouse-only `title` — the hover title keeps the long form with
the file path, but nothing lives there alone.

**Disabled rather than hidden, on purpose.** An app that has not turned geo on
still learns the feature exists and what to set; hiding the row teaches nobody
anything, and the feature stays invisible until someone reads this file.

**`ENABLE_GEO_BLOCKING` governs the LINK, never the gate.** An app with it unset
still detects, still blocks, still enforces its exclusion list. A default-off
variable that switched enforcement would silently stop a live legal blocklist on
the next deploy — the opposite of what a signpost is for. An app that prefers to
decide in code sets `config.geo_blocking_enabled = true` and the variable is
ignored.

### Which chrome an app gets, and what that costs

A signpost is only signage where someone looks, so read this before assuming a
gem bump put Geo in front of your admins. The engine has **two** admin chromes
and a host may fork a **third**:

| What the app declares | Its admin menu | Where Geo appears | What you do |
|---|---|---|---|
| no sidebar sections, or public-only ones | `components/_admin_dropdown` | the dropdown | nothing |
| at least one `admin: true` section | `components/_link_sidebar` | the sidebar, under its own admin-chipped `Geo` heading | nothing |
| a forked navbar or sidebar of its own | the fork | **nowhere** | render the partial, below |

The first two need no host change at all, and the row appears in **exactly
one** of them. Declaring an admin-flagged section is what flips an app from the
first row to the second: `studio_sidebar_replaces_admin_menu?` then suppresses
the dropdown so two cog glyphs do not read as a double gear. Declaring only
public sections keeps the dropdown — both chromes render for that shape, on
purpose — so the sidebar leaves the signpost to the dropdown rather than
showing an admin the same row twice.

**A forked chrome renders neither, and the engine cannot reach it.** Adopt the
signpost in one line, inside the fork's own admin block:

```erb
<%= render "components/geo_signpost",
      variant: :sidebar, close_action: "$store.sidebars.gearOpen = false" %>
```

`variant:` is `:dropdown` (narrow rows) or `:sidebar` (wide emoji rows).
`close_action:` is the Alpine expression that closes **your** panel behind the
row — the flag is the caller's, so the partial never hardcodes one. The row
self-gates on `admin?`; do not re-gate it, and do not copy the branching into
your fork, or the two chromes drift into disagreeing about whether geo is
reachable.

**Live today:** `turf-monster` is the forked chrome
(`app/views/components/_gear_sidebar.html.erb`), so its admins reach
`/admin/geo` by URL until that one line lands — worth knowing before setting
`ENABLE_GEO_BLOCKING=true` there and expecting a link to appear.

## The operator's page — `/admin/geo`

Opt in with `Studio.draw_geo_routes = true`. It draws four routes:

| Route | Helper | What it is |
|---|---|---|
| `GET /admin/geo` | `admin_geo_path` | the manager (admin only) |
| `PATCH /admin/geo` | `admin_geo_update_path` | save the policy |
| `POST /admin/geo/toggle` | `admin_geo_toggle_path` | start/stop simulating a blocked location |
| `GET /geo/check` | `geo_check_path` | **public** probe — fresh detection as JSON |

> **Why opt-in.** turf-monster owns all four of these helper names today. Drawing
> a name an app already has raises `Invalid route name, already in use` while
> that app's `routes.rb` is loading, which takes down **every** route in it — not
> just this page. Flip the default once no consumer's `main` owns the names.

Three cards, in the order an operator asks the questions:

1. **Current Detection** — what the server thinks of *you*: country, subdivision,
   blocked, simulation, each with its flag.
2. **Configuration** — the kill switch, then the summary: a row of blocked
   regions and a row of blocked countries as flag chips, so "what does this app
   block?" is answered without reading a 52-square grid.
3. **The editors** — two grids behind a tab, one open at a time. Regions in the
   home country (the 50-state grid when that country is the US), and Countries
   (all 249, `Studio::Geo::COUNTRIES`). Regions outside the home country are
   edited as tokens.

**Everything on the page answers a click immediately.** A square paints from its
own checkbox, the summary chips and counts rebuild from the editor, and — the
part worth knowing about — ticking *your own* region repaints the navbar badge
and the Blocked? tile, so a rule can be seen before it is saved. That preview
mirrors `Studio::Geo.blocked?` in the browser (same three rules, same fail-closed
narrowing) and decides nothing: the server re-decides on save and on every
request afterwards.

**Simulation** pins your session to a blocked region so you can walk the blocked
experience without a VPN. It picks `Studio.geo_simulated_region` if set, else the
first region this app actually blocks. With nothing blocked it refuses and says
so, rather than pinning you somewhere indistinguishable from where you are.

`/geo/check` answers:

```json
{"country":"US","subdivision":"WA","region":"US-WA","simulated":false,"blocked":true,"state":"WA"}
```

`state` is the legacy key turf-monster's client already reads; it is the same
value as `subdivision`.

**The badge's blocked look is an attribute** — `data-blocked="true"` plus one CSS
rule that ships with the partial — so anything that learns the policy changed can
repaint it by flipping one attribute. That is what the live preview does.

---

## The badge

`components/_geo_badge` renders the visitor's location — a subdivision flag plus
its code at home, a country emoji flag plus the region name elsewhere, and a red
`??` when the location cannot be resolved at all.

`??` is not cosmetic. Under the fail-closed rule that visitor **is** blocked, and
the badge has to say so rather than render nothing.

Pass locals to render a specimen with no session (a style guide, a view test):

```erb
<%= render "components/geo_badge", subdivision: "WA", country: "US", blocked: true, simulated: false %>
```

**Flag art.** The gem ships the 52 US subdivision flags (states + DC + PR) twice:
the vector originals at `app/assets/images/state-flags/` (~10 MB — real art,
several files past a megabyte) and 64x48 rasters of the same art under
`thumb/` (~200 KB for the set). The badge renders one flag per page and uses the
SVG; a 52-square grid uses the rasters, because ten megabytes of downloads for
images painted at 16px is not a trade worth making. Helpers:
`geo_subdivision_flag_path` and `geo_subdivision_flag_thumb_path`.

Every other country renders an emoji flag, which costs no bytes — shipping ~250
country SVGs is the same trade, refused again. A subdivision with no art renders
text-only, which is a normal answer.

---

## The lookup

The engine configures Geocoder on boot for every app that has the gem —
`ipinfo.io` over **HTTPS**, a 3-second timeout, and a `Rails.cache`-backed IP
cache. Two of those are not preferences:

- **`use_https`** — ipinfo 301-redirects HTTP to HTTPS with a non-JSON body, and
  Geocoder does not follow the redirect. A plain-HTTP lookup therefore returns
  *nothing*, silently, on every request — and every geo-gated feature fails
  closed for every visitor. It cost turf-monster two weeks of blocked payments.
- **the cache** — the anonymous tier rate-limits by *requesting* IP, and a
  platform's egress IPs are shared with other tenants, so the quota can be
  exhausted by traffic that is not yours. Caching by lookup URL (which embeds the
  IP) collapses repeat visitors and every uptime-monitor hit into one lookup per
  TTL. Geocoder caches only valid responses, so a 429 is never cached.

Set `IPINFO_API_TOKEN` to lift the anonymous rate limit. A blank token is a safe
no-op (the anonymous tier), so this stays dormant rather than failing closed on a
missing secret.

**The host wins.** An app that has already configured Geocoder — anything with
its own cache store — is left alone, because an engine that overwrote it would
change a shipped app's IP provider on a gem bump. `Studio.configure_geocoder =
false` opts out entirely. An app with no `geocoder` gem places nobody, and every
gate then behaves as it does for an unplaceable visitor.

**Freshness.** A resolved region is trusted for `Studio.geo_ttl` (a day). A blank
one is retried after `Studio.geo_retry_ttl` (five minutes), so a provider blip
does not cache "nowhere" — and fail every gate closed — for 24 hours.

---

## Configuration reference

| Setting | Default | What it does |
|---|---|---|
| `geo_home_country` | `"US"` | resolves bare codes; scopes the fail-closed rule |
| `geo_default_banned_countries` | `[]` | policy before an operator saves one |
| `geo_default_banned_subdivisions` | `[]` | same, for regions |
| `geo_fail_closed` | `true` | block unplaceable home-country visitors |
| `geo_ttl` | `24.hours` | how long a resolved region is trusted |
| `geo_retry_ttl` | `5.minutes` | how long a blank one is trusted |
| `geo_development_region` | `nil` | where a dev session stands (loopback never geocodes) |
| `geo_simulated_region` | `nil` | where `/admin/geo`'s simulate button puts you |
| `geo_blocked_message` | lambda | what a blocked visitor is told |
| `geo_blocked_redirect` | `nil` | where an HTML request lands (default `root_path`) |
| `draw_geo_routes` | `false` | draw `/admin/geo` + `/geo/check` |
| `geo_blocking_enabled` | `nil` | `nil` reads `ENABLE_GEO_BLOCKING`; true/false decides in code. Governs the admin dropdown's Geo row only |
| `configure_geocoder` | `true` | let the engine configure the lookup |
| `geo_ip_provider` | `:ipinfo_io` | Geocoder `ip_lookup` |
| `geo_ip_api_key` | `nil` | falls back to `ENV["IPINFO_API_TOKEN"]` |
| `geo_lookup_timeout` | `3` | seconds |
| `geo_cache_ttl` | `24.hours` | IP cache TTL |

`geo_development_region` is **development only**. A test or production
environment that cannot place a visitor must say so — that is precisely the case
the fail-closed rule exists for.

---

## Adopting from an app that already has geo

An app carrying its own `GeoSetting` / `GeoHelper` / detection code moves in four
steps:

1. **Install the table** and copy the rows —
   `banned_states` → `banned_subdivisions` (bare codes are canonicalised on
   write, so `%w[WA ID]` can be assigned straight across).
2. **Delete the local copies**: the model, the helper, the settings controller
   and its view, the badge partial, the geocoder initializer, and the detection
   methods on `ApplicationController`.
3. **Include `Studio::GeoDetection`** and set the config above, including
   `draw_geo_routes = true` once the local geo routes are deleted (they claim the
   same helper names).
4. **Keep the session keys.** The concern reads the same ones an app already has
   in production — `:geo_state`, `:geo_country`, `:geo_ip`, `:geo_detected_at`,
   `:geo_override` — so every live visitor keeps their resolved location instead
   of the app re-geocoding the internet on deploy day.

Published policy pages should render `Studio::GeoSetting.effective_banned_*`,
which is the same list the gate enforces — so what a visitor is told can never
drift from what is enforced.
