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

The page shows what the server thinks of *you* (country, subdivision, blocked,
simulation), the kill switch, a comma-separated country list, and — when the home
country is the US — the 50-state grid. Regions outside the home country are
edited as tokens.

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

**Flag art.** The gem ships the 52 US subdivision flags (states + DC + PR) at
`app/assets/images/state-flags/`, ~10 MB, so an app gets the complete badge from
an empty repository. Every other country renders an emoji flag, which costs no
bytes — shipping ~250 country SVGs for a 16px badge is not a trade worth making.
A subdivision with no art renders text-only, which is a normal answer.

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
