# Site footer

Every app on studio-engine can end its public pages with the same footer, from
configuration alone. The gem ships the markup, the styles, the map, the scripts
and Leaflet itself. The app declares facts.

Booking through Google Calendar is its own primitive, usable with or without
the footer: see [`BOOKING.md`](BOOKING.md). This page covers where the two meet.

This page and `BOOKING.md` ship inside the gem (`docs/` in the installed
studio-engine), so a consumer can cite them by path: `bundle exec gem contents
studio-engine | grep docs/` finds them. The repository copy is
<https://github.com/McRitchie-Studio/studio-engine/blob/main/docs/SITE_FOOTER.md>.

## Adopt it

The app owns its layout, so the footer is one line the app writes. The engine
never injects it.

```erb
<%# app/views/layouts/application.html.erb, at the end of <body> %>
<%= studio_site_footer %>
```

**The footer is on by default.** That line, with nothing configured, renders
the default footer. `config.site_footer` has three states:

| `config.site_footer` | What `studio_site_footer` renders |
|----------------------|-----------------------------------|
| unset (`nil`) | The default footer |
| a Hash, or a callable receiving the view | The app's own facts ([Your own facts](#your-own-facts)) |
| `false` | Nothing: the opt-out |

### The default footer

```ruby
# config/initializers/studio.rb
Studio.configure do |config|
  config.app_name = "Example Co"   # nothing about the footer: it is already on
end
```

It prints only what the engine knows to be true of the app:

- **The name**, as the wordmark and the © line: the site identity's title
  (`Studio.site_identity[:title]`), which is `config.app_name` until the
  operator or `config.site_title` says otherwise.
- **The logo**: the app's "Footer Logo" in `config.theme_logos`, else its
  navbar logo. None configured, none shown.
- **A legal line**, for the routes the host has: "Privacy Policy" when it has a
  route named `privacy`, "Terms of Service" when it has one named `terms`
  (`get "privacy", to: "legal#privacy", as: :privacy`). A route is linked only
  when a GET reaches it and its path needs no arguments. A host with neither
  gets the © line alone.

It has no address, no map, no phone, no email, no tagline, no social row and no
link columns, and the page names no Leaflet. The engine cannot know those, and
a guessed link is a dead one. For any of them, add a location (below) or
declare [your own facts](#your-own-facts).

### A location, in one setting

```ruby
Studio.configure do |config|
  config.site_footer_address = { street: "123 Example St", city_line: "Washington, DC 20024",
                                 lat: 38.8894, lng: -77.0352 }
end
```

That adds the Location band, and the map when `lat:` and `lng:` are both there,
to the default footer. The keys are the facts' `address:` keys
([The address and the map](#the-address-and-the-map)). It also gives a location
to an app's own facts that carry none. **An address in the app's own facts
wins**, whole, and `address: false` there shows none.

### Turning it off

```ruby
Studio.configure do |config|
  config.site_footer = false   # no footer on any page; unset (nil) is the default footer
end
```

To keep the footer off some pages rather than all of them, narrow
[where it shows](#where-it-shows) instead. A facts callable that answers `nil`
for a request renders no footer for that request.

### Your own facts

```ruby
# config/initializers/studio.rb
Studio.configure do |config|
  config.site_footer = ->(view) {
    {
      tagline: "Everything, by example",
      address: { street: "123 Example St", city_line: "Washington, DC 20024",
                 lat: 38.8894, lng: -77.0352 },
      social:  [ [ "LinkedIn", :linkedin, "https://www.linkedin.com/in/someone/" ],
                 [ "Instagram", :instagram, nil ] ],
      columns: [
        [ "Contact", [ [ "team@example.com", "mailto:team@example.com" ],
                       [ "Schedule a call", view.studio_booking_path ] ] ],
        [ "Company", [ [ "Home", view.root_path ], [ "Career", nil ],
                       [ "Blog", "https://blog.example.com" ] ] ]
      ],
      legal:   [ [ "Privacy Policy", view.privacy_path ], [ "Terms of Service", view.terms_path ] ]
    }
  }
  config.site_footer_controllers = %w[landing packages]
  config.booking_url = "https://calendar.google.com/calendar/appointments/schedules/EXAMPLE-SCHEDULE-ID"
  config.draw_booking_routes = true
end
```

That is the whole adoption. Nothing is copied into the app's `public/`, and
nothing is added to its asset manifest or its Tailwind build.

## An app with no database

An app with no ActiveRecord (a public site with no accounts, such as rantly)
can take the engine for its footer alone, with nothing else to set:

```ruby
# Gemfile
gem "studio-engine"   # pin the first release whose CHANGELOG lists footer-only support
```

```ruby
# config/application.rb: the app's own framework choice, unchanged
require "rails"
require "active_model/railtie"
require "action_controller/railtie"
require "action_view/railtie"
# no active_record/railtie
```

```ruby
# config/initializers/studio.rb
Studio.configure do |config|
  config.site_footer = ->(view) { { name: "Example", columns: [ [ "About", [ [ "Home", view.root_path ] ] ] ] } }
end
```

```erb
<%# app/views/layouts/application.html.erb, at the end of <body> %>
<%= studio_site_footer %>
```

Leave `config.site_footer` unset and the same app gets
[the default footer](#the-default-footer), its name read from `config.app_name`
since there is no site-identity table to ask.

Do not call `Studio.routes(self)`: everything it draws (sign-in, admin, error
logs) needs a database. The app also needs an asset pipeline (Propshaft or
Sprockets), as every Rails 8 app has, and a mapping of the theme tokens onto its
own palette (see [Colours](#colours)).

When the app loads no ActiveRecord (`Studio.active_record?` reads false, because
`ActiveRecord::Railtie` is not defined), the engine itself:

- requires the ActiveSupport core extensions it calls at load time
  (`Integer#minutes` and the like), so the app need not;
- skips the user-contract check ([`USER_CONTRACT.md`](USER_CONTRACT.md)), even
  when the app defines a `::User` of its own: the contract is what the engine's
  database-backed surfaces call on a user record, and the app has none;
- keeps every one of its `app/` roots but `app/helpers` out of eager loading
  (controllers, models, mailers, jobs, services, and the two `concerns` roots,
  which Zeitwerk treats as roots of their own), so a production boot does not
  load code that needs ActiveRecord, ActionMailer or ActiveJob. The helpers,
  the footer's among them, still eager load;
- answers `bin/rails studio_engine:install:migrations` with a no-op that exits 0
  and writes nothing, which is what the hub's release sweep runs in every member
  after an engine publish.

An app WITH ActiveRecord sees none of this change.
`test/integration/footer_only_consumer_test.rb` boots such an app, in
development and with `eager_load = true`.

## The facts

`config.site_footer` is a Hash, or a callable that receives the view (so it can
use route helpers). Unset (`nil`), the facts are the default footer's; `false`
means the app has no footer and `studio_site_footer` renders nothing
([Adopt it](#adopt-it)).

Every key is optional. A missing key removes its part of the footer.

| Key | What it prints | When absent |
|-----|----------------|-------------|
| `name` | The wordmark, the logo's label and the © line | The site identity's title (`Studio.site_identity[:title]`) |
| `wordmark` | Two parts, the second in the primary colour: `%w[Example Co]` | `name`, split before its last word |
| `logo` | An image beside the wordmark: an asset name or a path | The app's "Footer Logo" in `config.theme_logos`, else its navbar logo. `logo: false` shows none |
| `logo_invert` | `true` inverts a dark mark in light mode | Shown as drawn |
| `home_path` | Where the logo and wordmark link | `/` |
| `tagline` | A line under the wordmark | No line |
| `email` | A `mailto:` link under the tagline | No line. (To list the email in a column instead, write it as a column link.) |
| `address` | The Location band, and the map | `config.site_footer_address`; with neither, no Location band, no map, and Leaflet is never requested. `address: false` shows none even with the setting |
| `social` | A row of round icons | No row |
| `columns` | Link columns under bold headings. A column may carry a width hint: `[ "Contact", links, { width: 1.5 } ]` | Brand only |
| `legal` | The centred line above the © | The © alone |
| `booking` | `{ label:, title: }` for the popup's heading and the frame's accessible name | "Schedule a call", and "Schedule a call with <name>" |

Rows may be tuples, as above, or hashes (`{ label:, href: }`, `{ heading:, links: }`,
`{ label:, icon:, url: }`). The rules a row can carry:

- **A link with a `nil` path** renders its label disabled ("Coming soon"). Use it
  for a page that does not exist yet.
- **A link to an `http(s)` URL** opens in a new tab.
- **A booking link** opens the booking popup instead of leaving the page. A link
  is a booking link when its path is the booking page (the engine's
  `studio_booking_path`, or the app's own `config.booking_path`), or when it
  says so:
  `[ "Schedule a call", contact_path, { booking: true } ]`. Its href stays as the
  fallback.
- **Only some hrefs are linked.** A link, a social URL, `home_path` and
  `directions_url` may be a relative path or an `http:`, `https:`, `mailto:` or
  `tel:` URL. Anything else, `javascript:` and `data:` included, is never written
  into the page: a link or a social icon prints unlinked, `home_path` falls back
  to `/`, and `directions_url` falls back to the Google Maps default. Each
  refused value is logged once (`[studio.site_footer] ... is not linked`).
- **The columns sit on a grid with fixed rows.** Below 768px the brand runs
  across the top and the link columns sit two to a row. From 768px every link
  column is in one row under the brand. From 1024px the brand is in that row
  too. A footer with more than four link columns keeps the brand across the top
  and wraps the columns four to a row.
- **An email address or a URL in a column is never broken mid-word.** A label
  that is an address (no space, and an `@`, a `.` or a `/`) is kept on one line,
  and its track is at least as wide as it is: the column grows to hold it and
  the columns beside it give way. No column moves to another row. On the
  smallest phones (under 360px) the gutter narrows and the address is set a
  little smaller, which holds an address of about 25 characters beside a second
  column at 320px; a longer one runs past the footer's edge there. Under 300px,
  narrower than any phone, the address is allowed to break.
- **`width:` is a column's track**, as a share of the row, from 768px:
  `{ width: 2 }` as a tuple's third element, or `width:` in a hash row. A number
  from 0.5 to 4; anything else is ignored. Without one, the first column is 1.5
  and the rest are 1 (the brand, from 1024px, is 1.7). Below 768px the two tracks
  are fixed at 1.2 and 1, and with more than four columns the hints are not used.
- **A social profile with a `nil` URL** renders its icon unlinked, with a dashed
  outline. The engine draws `:linkedin`, `:instagram`, `:x`, `:facebook` and
  `:youtube`; any other icon falls back to the label's first letter.

### The address and the map

```ruby
address: { street: "123 Example St", city_line: "Washington, DC 20024",
           lat: 38.8894, lng: -77.0352,
           zoom: 15,                               # optional, default 15
           directions_url: "https://maps.app/..." } # optional
```

- `street` or `city_line` gives the Location band. Without `directions_url` the
  address links to Google Maps directions for it.
- `lat` and `lng`, both, give the map. An address without them keeps the band
  and has no map.
- The map is [Leaflet](https://leafletjs.com) 1.9.4 on OpenStreetMap's keyless
  tiles (`tile.openstreetmap.org`). No account and no API key.
- Dark mode filters the same tiles in CSS. There is no second tile set.
- With scripts off, or if Leaflet fails to load, the map element is a link to
  directions.
- Nothing is requested before the window's `load` event, and nothing until the
  map is within 400px of the viewport. A visit that never scrolls to the footer
  fetches neither Leaflet nor a tile.
- On a touch device one finger scrolls the page, not the map. The map runs edge
  to edge, so a swipe that began on it would otherwise trap the visitor. Pinch
  still zooms, and the zoom buttons and the directions link remain. With a
  mouse the map drags, and the wheel zooms only after a click on the map.

`studio_footer_map class: "h-80"` renders the map alone, for a contact page. It
maps the footer's address; pass `lat:`/`lng:` to map another. The element has no
height of its own, so `class:` or `style:` sizes it.

Leaflet numbers its own panes and controls up to `z-index: 1000`. The map
element is its own stacking context (`isolation: isolate`), so none of that
competes with the navbar or a modal. If you mount Leaflet yourself on another
element, isolate that element too.

Leaflet is served by the engine through the app's asset pipeline
(`studio/leaflet.js`, `studio/leaflet.css`, both in the engine's precompile
list), so it works on Heroku with no extra step in either a Sprockets or a
Propshaft app. The engine's copy of the stylesheet drops Leaflet's default marker
image and its layers-control image, which are not shipped: mark a point with
`L.divIcon`, as the footer does.

## Where it shows

`studio_site_footer` asks `config.site_footer_visible`, one callable that
receives the view. Its default:

- **A visitor** (signed out) sees the footer on every page.
- **A signed-in viewer** sees it only on the controllers in
  `config.site_footer_controllers`, by controller name (`"landing"`) or path
  (`"admin/reports"`). Every other signed-in page is a working surface and stays
  full height. The booking page is always included: the engine's `/schedule`,
  or the app's own when `config.booking_path` names it.

The default shows the footer on any page a signed-out visitor can reach,
including an app page that happens to be public. Narrow it by replacing the
callable, composing with the default rather than restating it:

```ruby
config.site_footer_visible = ->(view) {
  Studio::SiteFooter.default_visible?(view) && !view.controller_path.start_with?("games/")
}
```

`studio_show_site_footer?` gives a view the same answer.

## Booking

With `config.booking_url` set, the footer renders the booking popup, and a
booking link in a column opens it instead of leaving the page (the rule is under
[The facts](#the-facts)). `booking: { label:, title: }` in the facts sets what the
links, the popup and the booking page call the act.

The frame, its crop, the popup, the `/schedule` page, an app's own booking page
(`config.booking_path`) and how to set the schedule up in Google are in
[`BOOKING.md`](BOOKING.md).

## What it costs a page

- The footer's CSS and scripts are inline, rendered once per page, and scoped
  (`.ftr-*`, `.booking-*`). They read the theme's custom properties with a
  fallback beside each, so the footer lays out the same in an app whose Tailwind
  build has never seen these views. Do not restyle it with utilities that your
  build may not emit.
- A page with no address never names Leaflet: the map's styles and its mount
  script are rendered only with a map (`studio/site_footer/_map_assets`). A page
  with no `booking_url` carries no booking script.
- A facts callable that raises costs the footer, not the page: in production the
  error is logged once and the page renders without a footer. In development and
  test it raises.

## Colours

The footer reads the engine's theme tokens, with a fallback beside each:

| Token | Paints |
|-------|--------|
| `--color-surface-alt` | The band's background |
| `--color-text-body` | The band's text |
| `--color-text` | The wordmark, the headings and the Location title |
| `--color-text-secondary` | The links (through `--ftr-link-ink`) and the tagline |
| `--color-text-muted` | The © line |
| `--color-primary`, `--color-primary-500-rgb` | The wordmark accent, link hover, social icons and the map tint |
| `--color-border` | The rules |

**Links are painted at full opacity** in `--ftr-link-ink`, which defaults to
`--color-text-secondary`. On the engine's default theme that ink clears WCAG AA
4.5:1 on the band in both themes (`test/lib/site_footer_link_contrast_test.rb`
measures it). An app that maps the tokens onto its own palette owes the same:
set `--color-text-secondary` to an ink that clears 4.5:1 on its
`--color-surface-alt`, in light and dark. To give the footer's links a colour of
their own without touching the token, set `--ftr-link-ink` on the footer:

```css
footer[data-site-footer] { --ftr-link-ink: #4a4a4a; }
@media (prefers-color-scheme: dark) { footer[data-site-footer] { --ftr-link-ink: #c8c8c8; } }
```

## Content Security Policy

An app that enforces a policy must allow what the footer fetches from other
origins (the booking frame's `frame-src` is in [`BOOKING.md`](BOOKING.md#content-security-policy)):

| Directive | Source | For |
|-----------|--------|-----|
| `img-src` | `https://tile.openstreetmap.org` | The map's tiles |

Leaflet itself is same-origin (`script-src 'self'`, `style-src 'self'`), since it
is served from the app's own assets.

The footer's own `<style>` and `<script>` blocks are
inline and carry no nonce, like the rest of the engine's partials, and Leaflet
positions its tiles with inline `style` attributes. A policy that forbids inline
script or style needs `'unsafe-inline'` for them (or hashes), exactly as it does
for the engine's head partial today.

## Coexisting with an app's own copy

An app that still renders a local footer partial uses the same
`data-footer-map` attribute. The engine's script keeps out of its way: its guard
is an engine name (`__studioFooterMapsArmed`), and it acts only on
engine-rendered maps, which carry `data-leaflet-js`. The booking scripts follow
the same rule ([`BOOKING.md`](BOOKING.md#coexisting-with-an-apps-own-copy)).

## Markup hooks

Stable, for tests and for an app's own scripts:
`footer[data-site-footer]`, `[data-footer-location]`, `[data-footer-map]`. The
booking hooks are in [`BOOKING.md`](BOOKING.md#markup-hooks).

## Class hooks

These class names are stable, and an app may style against them:

| Class | Element |
|-------|---------|
| `.ftr` | The footer |
| `.ftr-cols` | The grid of brand and link columns; `--ftr-tracks` is its link-column tracks. `.ftr-cols-many` with more than four |
| `.ftr-brand` | The brand block |
| `.ftr-col` | One link column (a `nav`) |
| `.ftr-heading`, `.ftr-list` | A column's heading and its list |
| `.ftr-link`, `.ftr-link-solid`, `.ftr-link-disabled` | A link; an address kept on one line; a "coming soon" label. `--ftr-link-ink` on `.ftr` is the link colour |
| `.ftr-location`, `.ftr-location-title`, `.ftr-address` | The Location band |
| `.ftr-legal`, `.ftr-copyright` | The legal line and the © line |
| `.ftr-map` | The map |

The rest (`.ftr-wrap`, `.ftr-home`, the social and pin classes) may change.

The footer's stylesheet is inline and unlayered, and comes after the app's own
in the document, so an app rule needs more specificity to win: prefix it with
`footer[data-site-footer]`.

### An app that overrode 0.83.0's tracks

0.83.0 laid the columns on equal `minmax(0, 1fr)` tracks, and an app could only
fix the broken address from its own stylesheet, with `grid-template-columns` on
`footer[data-site-footer] .ftr-cols` and `overflow-wrap: normal` on the mailto
link. Those rules are more specific than the engine's and still apply.

- **Left in place** they draw the same rows as the engine now does, with the
  address whole (a browser spec holds that, at 320, 390, 768, 1024 and 1280px).
  Nothing breaks if the block outlives the upgrade.
- **Delete the block once the app is on this version.** Not before: on 0.83.0 it
  is the only thing keeping the address whole. While it stays it hides the
  engine's tracks, so a `width:` hint does nothing and the narrow-phone gutter is
  the only engine rule still acting on the row.

## Tests

- `test/lib/studio/site_footer_test.rb`: the facts' rules, the default facts, the
  address setting's precedence, and the visibility rule.
- `test/lib/vendored_leaflet_test.rb`: Leaflet is vendored, precompiled, and
  addressed through the asset pipeline.
- `test/integration/site_footer_test.rb`: what a host renders, with and without
  each fact, signed in and out; the default footer with nothing set, the
  `false` opt-out, `config.site_footer_address` on the default footer and
  against an app's own address, and the default legal links with and without
  the host's routes.
- `test/integration/footer_only_consumer_test.rb`: an app with no ActiveRecord
  boots (development and eager-loaded), renders the footer with no Leaflet, and
  runs `studio_engine:install:migrations` to a clean exit; with nothing set it
  renders the default footer.
- `test/lib/site_footer_link_contrast_test.rb`: the link ink clears 4.5:1 on the
  band, on the default tokens, in both themes.
- `e2e/site_footer.spec.js`: the map's script and the footer's layout, in a
  browser, with the network closed: which columns share a row at 320, 390, 768,
  1024 and 1280px with two, three, four and five columns, the address on one
  line inside its column at each, and the line heights. These lab pages load Turbo, so the map's remount after a Turbo visit is
  covered.

`/admin/style` shows the footer under Tricks, with this app's own facts, or a
sample when it has declared none (the default footer or `false`).
