# Site footer and booking

Every app on studio-engine can end its public pages with the same footer, and
take bookings through Google Calendar, from configuration alone. The gem ships
the markup, the styles, the map, the scripts and Leaflet itself. The app declares
facts.

## Adopt it

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

```erb
<%# app/views/layouts/application.html.erb, at the end of <body> %>
<%= studio_site_footer %>
```

That is the whole adoption. Nothing is copied into the app's `public/`, and
nothing is added to its asset manifest or its Tailwind build.

## The facts

`config.site_footer` is a Hash, or a callable that receives the view (so it can
use route helpers). `nil`, the default, means the app has no footer and
`studio_site_footer` renders nothing.

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
| `address` | The Location band, and the map | No Location band, no map, and Leaflet is never requested |
| `social` | A row of round icons | No row |
| `columns` | Link columns under bold headings | Brand only |
| `legal` | The centred line above the © | The © alone |
| `booking` | `{ label:, title: }` for the popup's heading and the frame's accessible name | "Schedule a call", and "Schedule a call with <name>" |

Rows may be tuples, as above, or hashes (`{ label:, href: }`, `{ heading:, links: }`,
`{ label:, icon:, url: }`). The rules a row can carry:

- **A link with a `nil` path** renders its label disabled ("Coming soon"). Use it
  for a page that does not exist yet.
- **A link to an `http(s)` URL** opens in a new tab.
- **A booking link** opens the booking popup instead of leaving the page. A link
  is a booking link when its path is the engine's booking page
  (`studio_booking_path`), or when it says so:
  `[ "Schedule a call", contact_path, { booking: true } ]`. Its href stays as the
  fallback.
- **Only some hrefs are linked.** A link, a social URL, `home_path` and
  `directions_url` may be a relative path or an `http:`, `https:`, `mailto:` or
  `tel:` URL. Anything else, `javascript:` and `data:` included, is never written
  into the page: a link or a social icon prints unlinked, `home_path` falls back
  to `/`, and `directions_url` falls back to the Google Maps default. Each
  refused value is logged once (`[studio.site_footer] ... is not linked`).
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
  full height. The engine's booking page is always included.

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

`config.booking_url` is the public link to a Google Calendar appointment
schedule, as Google gives it to you, without `?gv=true` (the engine adds that for
the embedded page). `nil`, the default, means no booking: the helpers below
render nothing and no link opens a popup.

| Helper | What it renders |
|--------|-----------------|
| `studio_booking_frame` | Google's booking page inline, plus a line linking to the page itself. `crop: false` shows the whole page at rest; `title:` names the frame |
| `studio_booking_link "Book a call", class: "btn btn-primary"` | A link that opens the popup in place. Its href is the booking page, so it works with scripts off |
| `studio_booking_popup` | The dialog. The footer renders it; call it yourself only on a page with booking links and no footer |
| `studio_footer_map class: "h-80"` | The map alone, for a contact page. Pass `lat:`/`lng:` to map another address |

### The frame

- **Deferred.** The URL waits in `data-src`. A script assigns `src` only after the
  window's `load` event, and only once the frame is within 200px of the viewport.
  `loading="lazy"` is not enough: a third-party frame that starts before `load`
  holds that event open for as long as Google takes to answer.
- **Cropped at rest, whole in use.** From 640px up, the frame shows only Google's
  slot picker: a 414px window onto a 732px page, 205px down. When focus moves
  into the frame, the window opens to the full page, because the form Google
  shows after a slot is picked is centred in the frame's full height. Those
  numbers are Google's layout as measured on 2026-09-30. If Google moves it, pass
  `crop: false`.
- **White in both themes.** Google's page cannot be themed.
- **With scripts off** the frame is replaced by a plain link to the booking page.

### The popup

A booking link opens Google's page in a `<dialog>` without leaving the page. The
frame inside is requested the first time the dialog opens, and kept while that
page stays up: closing and reopening does not ask Google again.

A Turbo restoration visit (back or forward) is a new page built from a snapshot,
and it does ask again. The inline frame is restored with its `src`, so the
browser re-requests Google's page for it. The popup's frame is not: its `src` is
put back to waiting before the snapshot is taken, so a restored page asks Google
for the popup only when someone opens it.

- **On a page that already shows the inline frame**, a booking link scrolls to
  that frame, opens its crop and moves focus into it. It does not open a second
  calendar on top of the first.
- **The link's href is the fallback**: with scripts off, on a modified click (new
  tab), or on a page with no dialog, it is an ordinary link.
- **The page behind does not scroll** while the dialog is open.
- **It is sized to the visible viewport** (`dvh`, with `vh` as the fallback), so
  a phone's toolbars do not push the Close button off screen.
- **Escape closes it, with one limit.** Once focus is inside Google's frame, key
  presses belong to Google (it is another origin), and Escape no longer reaches
  the dialog. Nothing in the page can change that. The Close button and a click
  on the backdrop always work.

It is a native `<dialog>`, not the engine's modal host (`studio/modals/_host`),
on purpose. The host needs Alpine, its store, and each modal registered inside
the host's block in the layout, so the footer would no longer be one line and an
app without a host would have no popup. The host's card is padded and scrolls,
where this body is a full-bleed frame. And the host mounts content with
`<template x-if>`, which would build a new frame and ask Google again on every
open.

### The page

`config.draw_booking_routes = true` draws `GET /schedule`
(`Studio::BookingsController`, helper `studio_booking_path`): a heading, the
frame, and the footer, in the app's own layout. It is public, and answers `404`
when no `booking_url` is set.

The route is a flag, off by default, like every route a consumer might already
own (mcritchie-studio draws its own `/schedule` today). An app that wants
different words around the calendar renders `studio_booking_frame` in a view of
its own instead; the page and the partial are the same frame.

## What it costs a page

- The footer's CSS and scripts are inline, rendered once per page, and scoped
  (`.ftr-*`, `.booking-*`). They read the theme's custom properties with a
  fallback beside each, so the footer lays out the same in an app whose Tailwind
  build has never seen these views. Do not restyle it with utilities that your
  build may not emit.
- A page with no address never names Leaflet. A page with no `booking_url`
  carries no booking script.
- A facts callable that raises costs the footer, not the page: in production the
  error is logged once and the page renders without a footer. In development and
  test it raises.

## Content Security Policy

An app that enforces a policy must allow what these primitives fetch from other
origins:

| Directive | Source | For |
|-----------|--------|-----|
| `frame-src` | `https://calendar.google.com` | The booking frame and the popup |
| `img-src` | `https://tile.openstreetmap.org` | The map's tiles |

Leaflet itself is same-origin (`script-src 'self'`, `style-src 'self'`), since it
is served from the app's own assets.

The footer's and the booking primitives' own `<style>` and `<script>` blocks are
inline and carry no nonce, like the rest of the engine's partials, and Leaflet
positions its tiles with inline `style` attributes. A policy that forbids inline
script or style needs `'unsafe-inline'` for them (or hashes), exactly as it does
for the engine's head partial today.

## Coexisting with an app's own copy

An app that still renders local footer or booking partials (mcritchie-studio,
until it adopts these) uses the same `data-footer-map` and `data-booking-*`
attributes. The engine's scripts keep out of its way: their guards are engine
names (`__studioFooterMapsArmed`, `__studioBookingFramesArmed`,
`__studioBookingPopupArmed`), and they act only on engine-rendered elements,
which carry `data-leaflet-js` (the map) or `data-studio-booking` (the frame, its
wrapper, the dialog and the links). Write a booking link with
`studio_booking_link`, not by hand, so it carries the marker.

## Markup hooks

Stable, for tests and for an app's own scripts:
`footer[data-site-footer]`, `[data-footer-location]`, `[data-footer-map]`,
`[data-booking-wrap]`, `iframe[data-booking-frame]`, `dialog[data-booking-dialog]`,
`iframe[data-booking-popup-frame]`, `a[data-booking-popup]`, `[data-booking-close]`,
`[data-booking-page]`. The booking elements also carry `data-studio-booking`.

## Tests

- `test/lib/studio/site_footer_test.rb`: the facts' rules, the visibility rule
  and the booking URLs.
- `test/lib/vendored_leaflet_test.rb`: Leaflet is vendored, precompiled, and
  addressed through the asset pipeline.
- `test/integration/site_footer_test.rb`: what a host renders, with and without
  each fact, signed in and out, and the booking page.
- `e2e/site_footer.spec.js`, `e2e/booking_frame.spec.js`: the scripts, in a
  browser, with Google stubbed and the network closed. These lab pages load
  Turbo, so the map's remount after a Turbo visit is covered.

`/admin/style` shows the footer under Tricks, with this app's facts or a sample.
