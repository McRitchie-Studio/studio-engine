# Booking

An app on studio-engine can take bookings through a Google Calendar appointment
schedule: inline in a page, in a popup, and on a `/schedule` page. The gem ships
the frame, the popup, the page and their scripts. Google does the scheduling.

It stands alone. An app does not need the [site footer](SITE_FOOTER.md) to use
it, and not every app needs it at all: it is a simple scheduler for an app that
wants one. Everything about *when* someone can book is configured in Google, not
here: availability, conflict checking across several calendars, buffers between
appointments, the booking form's questions, and the Meet link on the invitation.

## Adopt it

```ruby
# config/initializers/studio.rb
Studio.configure do |config|
  config.booking_url = "https://calendar.google.com/calendar/appointments/schedules/EXAMPLE-SCHEDULE-ID"
  config.draw_booking_routes = true   # GET /schedule, the engine's booking page
end
```

That is a working booking page at `/schedule`, in the app's own layout. To put
the calendar in a page of your own instead, or as well:

```erb
<%= studio_booking_frame %>
<%= studio_booking_link "Book a call", class: "btn btn-primary" %>
```

Nothing is added to the app's asset manifest or its Tailwind build. An app that
enforces a Content Security Policy must allow the frame: see
[Content Security Policy](#content-security-policy).

## Set up the schedule in Google

These steps are Google Calendar's, as its menus read in October 2026. Google
moves them; the things to end up with do not change.

1. **Create the appointment schedule.** In Google Calendar, signed in as the
   account that will own the bookings: *Create*, then *Appointment schedule*.
   Give it a title, an appointment length and its general availability. Under
   the booked-appointment settings, set the buffer between appointments and the
   most bookings in a day. Under the booking page's settings, choose Google Meet
   as the place if each invitation should carry a Meet link, and choose what
   the form asks for.
2. **Share the other calendars in, for conflict checking.** A schedule can only
   avoid events it can see. For each other calendar that should block a slot (a
   personal account, a second Workspace), open that calendar's settings in the
   account that owns it, share it with the schedule's owner, and let the owner
   see at least whether the time is free or busy. Then, in the schedule's
   availability settings, tick those calendars under the ones checked for
   conflicts. Google limits checking more than one calendar to some paid
   plans; check what the owning account has.
3. **Copy the booking URL.** Open the schedule's booking page and take its long
   address, the one of this shape:

   ```text
   https://calendar.google.com/calendar/appointments/schedules/EXAMPLE-SCHEDULE-ID
   ```

   Google's *Share* dialog may also offer a short link; use the long address,
   which is the one that embeds (the dialog's website-embed code carries it as the
   frame's `src`). Paste it without `?gv=true`: the engine adds that for the
   embedded page and leaves it off the link to Google's own page. A link pasted
   with it is accepted and stored without it.

The id in that address is not a secret (it is on every page that embeds it), but
it is the app's own: keep real ids out of examples and tests.

## Configuration

| Setting | What it is | Default |
|---------|------------|---------|
| `config.booking_url` | The schedule's public `https` address | `nil`: no booking. Every helper below renders nothing and no link opens a popup |
| `config.booking_crop` | The frame's crop at rest: `{ top:, bottom:, frame_height: }` | `nil`: the whole frame. See [The crop](#the-crop) |
| `config.draw_booking_routes` | Draw the engine's booking page, `GET /schedule` | `false` |
| `config.booking_path` | Where the app's OWN booking page lives: a path, or a callable receiving the view | `nil`. See [A page of your own](#a-page-of-your-own) |

## Helpers

| Helper | What it renders |
|--------|-----------------|
| `studio_booking_frame` | Google's booking page inline, plus a line linking to the page itself. `title:` names the frame; `crop:` is `true` (the default: use `config.booking_crop`), `false`, or a Hash for this frame alone |
| `studio_booking_link "Book a call", class: "btn btn-primary"` | A link that opens the popup in place. Its href is the booking page, so it works with scripts off |
| `studio_booking_popup` | The dialog. The site footer renders it; call it yourself on a page with booking links and no footer |

## The frame

- **Deferred.** The URL waits in `data-src`. A script assigns `src` only after the
  window's `load` event, and only once the frame is within 200px of the viewport.
  `loading="lazy"` is not enough: a third-party frame that starts before `load`
  holds that event open for as long as Google takes to answer.
- **Whole at rest, unless the app declares a crop.** Without one the frame shows
  Google's whole page, 732px tall from 640px up and 1200px below that, where
  Google stacks the month above the slots.
- **White in both themes.** Google's page cannot be themed.
- **With scripts off** the frame is replaced by a plain link to the booking page.

## The crop

Google's page has a header above the calendar (the owner, the title, the length,
the meeting line) and credit lines below it. A crop hides both at rest, so the
page shows only the "Select an appointment time" box, and opens the frame to its
full height when the visitor starts using it.

```ruby
config.booking_crop = { top: 200, bottom: 600, frame_height: 720 }
```

The three numbers are pixels in Google's own page, at 640px wide or more:

| Key | What it is | Does it move? |
|-----|------------|---------------|
| `top` | The box's top edge | Only when the schedule's header changes: its title, description or meeting line |
| `bottom` | The box's bottom edge **on its fullest day** | Yes. See below |
| `frame_height` | The whole page's height on that fullest day | With `bottom` |

**There is no default crop, because the numbers belong to one schedule.** Two
schedules with different headers have different tops, and a crop measured on one
slices the other's heading. An app that has not measured gets the whole frame.

### How the window is derived

The wrapper shows `top - 6` to `bottom + 6`, held inside the frame, and the frame
behind it is `frame_height` tall. Six pixels is the margin 0.83.0 used.

The box is as tall as the month grid or the longest column of appointment slots,
whichever is taller, at 48px a slot. The month grid was six rows in every month
measured (two schedules, seven months each, on 2026-10-01), so a short month did
not move the box. The slot column is not fixed: a day that is partly booked, or partly over, has fewer slots
than a free one. So **the box's bottom on any one day is not the schedule's
bottom**, and a crop measured from one look at the page cuts off the last slots
of a fuller day.

That is why `bottom` is the bottom on the fullest day, and why it cannot slice
content: on every other day the box is shorter than the window, and what shows
under it is a strip of Google's credit lines. The crop errs toward showing too
much, never too little. `frame_height` is the page's height on that same day, so
the opened frame holds the whole page without a scrollbar of its own.

What the crop cannot follow is a change to the schedule itself. Measure again
when the header changes, or when a day can hold more slots than the fullest day
measured (longer hours, shorter appointments).

### Measure it

```bash
npm ci && npx playwright install chromium     # once
bin/booking-crop-measure https://calendar.google.com/calendar/appointments/schedules/EXAMPLE-SCHEDULE-ID
```

Run it from a checkout of this repo. It opens Google's embedded page in headless
Chromium at two frame widths (640px and 862px), selects every bookable day of
the next three months (`--months N` for more), and prints the Hash, with what it
measured against:

```text
  640px wide: box 200-600px, page 720px tall.
    month grid: 6 rows. Fullest day: 8 slot rows (Tuesday, January 8, 2030).
    walked 28 bookable days over 3 month(s). As it opened: box bottom 456px, 5 slot rows.
  ...
  config.booking_crop = { top: 200, bottom: 600, frame_height: 720 }
```

It books nothing: it only selects days. It reads Google's page by role and
attribute (`main`, `table[role=grid]`, `td[data-date]`, `[role=list]`), and stops
with an error if the page is no longer shaped that way, rather than print numbers
from the wrong element. `--json` prints the measurements for a script.

It reaches the live Google page, so it never runs in CI: the command refuses
under a `CI` environment, and the browser lane proves the measuring against a
stub (`e2e/booking_crop_measure.spec.js`).

### One frame's own crop

```erb
<%= studio_booking_frame crop: false %>                                        <%# whole, whatever the app declares %>
<%= studio_booking_frame crop: { top: 150, bottom: 480, frame_height: 640 } %>  <%# this frame alone %>
```

Each cropped wrapper carries its numbers as custom properties
(`--booking-crop-offset`, `--booking-crop-window`, `--booking-frame-height`) in
its own `style` attribute, so two frames with different crops can share a page.
Each opens when focus moves into it.

### A crop that cannot be one

A Hash whose values are not numbers, a negative `top`, a `bottom` that is not
below `top` or is past `frame_height`, or a window as tall as the frame, is not
applied. The frame shows whole, and one line is logged:

```text
[studio.booking] booking crop {...} is ignored (bottom is not below top); the frame shows whole.
```

`config.booking_crop` logs it when it is assigned, at boot. Anything that is not
a Hash, `nil` or `false` raises there.

### Its limits

- **The crop is off below 640px**, where Google stacks the month above the slots.
- **The breakpoint is the viewport's, not the frame's.** Google lays the month
  beside the slots only when the frame itself is about 600px wide. A frame in a
  narrow column on a wide screen is stacked, and a crop measured side by side
  does not fit it: pass `crop: false` there.
- **The crop cannot stay on.** The form Google shows after a slot is picked is a
  dialog centred in the frame's full height, so the frame opens fully on use.

## The popup

A booking link opens Google's page in a `<dialog>` without leaving the page. The
frame inside is requested the first time the dialog opens, and kept while that
page stays up: closing and reopening does not ask Google again. The popup is
never cropped.

A Turbo restoration visit (back or forward) is a new page built from a snapshot,
and it does ask again. The inline frame is restored with its `src`, so the
browser re-requests Google's page for it. The popup's frame is not: its `src` is
put back to waiting before the snapshot is taken, so a restored page asks Google
for the popup only when someone opens it.

- **On a page that already shows the inline frame**, a booking link scrolls to
  that frame, opens its crop and moves focus into it. It does not open a second
  calendar on top of the first.
- **The link's href is the fallback**: with scripts off, on a modified click (new
  tab), or on a page with no dialog, it is an ordinary link. It goes to the
  app's booking page when there is one, else to Google's own page.
- **The page behind does not scroll** while the dialog is open.
- **It is sized to the visible viewport** (`dvh`, with `vh` as the fallback), so
  a phone's toolbars do not push the Close button off screen.

It is a native `<dialog>`, not the engine's modal host (`studio/modals/_host`),
on purpose. The host needs Alpine, its store, and each modal registered inside
the host's block in the layout, so an app without a host would have no popup.
The host's card is padded and scrolls, where this body is a full-bleed frame. And
the host mounts content with `<template x-if>`, which would build a new frame and
ask Google again on every open.

## The page

`config.draw_booking_routes = true` draws `GET /schedule`
(`Studio::BookingsController`, helper `studio_booking_path`): a heading, the
frame with the app's crop, and the footer if the app has one, in the app's own
layout. It is public, and answers `404` when no `booking_url` is set.

The route is a flag, off by default, like every route a consumer might already
own.

### A page of your own

An app that wants different words around the calendar renders
`studio_booking_frame` in a view of its own. The frame is the same one, crop
included, and needs nothing else. Tell the engine where that page is:

```ruby
config.booking_path = "/schedule"
# or, with a route helper:
config.booking_path = ->(view) { view.schedule_path }
```

With it set the app's page is treated as the engine's own is:

- a site-footer link whose href is that path opens the popup without
  `{ booking: true }`;
- `studio_booking_link` falls back to it, instead of to Google's page;
- a signed-in viewer keeps the footer on it, without the controller being listed
  in `config.site_footer_controllers`. The page is matched by the request's path.

Without `booking_path` (and without the engine's route) an app's own page gets
none of the three: the engine has no way to know it is the booking page. If both
are declared, `booking_path` is the booking page. A callable that returns `nil`
falls back to the engine's page.

## With the site footer

The footer renders the popup, and prints a booking link in any column that names
one (see [`SITE_FOOTER.md`](SITE_FOOTER.md)). Its facts may carry the copy:
`booking: { label:, title: }` sets what the links, the popup and the page call
the act ("Schedule a call") and the frame's accessible name. Without a footer the
label is "Schedule a call" and the name is "Schedule a call with <site title>".

## Content Security Policy

An app that enforces a policy must allow the frame:

| Directive | Source | For |
|-----------|--------|-----|
| `frame-src` | `https://calendar.google.com` | The booking frame and the popup |

The primitives' own `<style>` and `<script>` blocks are inline and carry no
nonce, like the rest of the engine's partials, and a cropped wrapper carries its
numbers in an inline `style` attribute. A policy that forbids inline script or
style needs `'unsafe-inline'` for them (or hashes), exactly as it does for the
engine's head partial today.

## Limits

- **Google's page cannot be themed.** It is another origin's document in a
  frame: its colours, type and wording are Google's. The frame sits on a white
  panel in both themes.
- **Escape does not close the popup once focus is inside the frame.** Key
  presses there belong to Google, and nothing in the page can change that. The
  Close button and a click on the backdrop always work, which is why Close is a
  solid, full-size button.
- **The page cannot see into the frame.** It is told nothing about a click or a
  booking. The one signal it gets is that focus moved into the frame, which is
  what opens a crop.
- **A crop is a measurement of Google's layout.** If Google redesigns the page,
  measure again, or set `config.booking_crop = nil`.

## Upgrading from 0.83.0

**0.83.0 cropped every frame, with one schedule's numbers. The next release
crops none until the app declares its own.** After upgrading, a frame that was
cropped shows Google's whole page.

To keep exactly the crop 0.83.0 drew (a 414px window, 205px down a 732px frame):

```ruby
config.booking_crop = { top: 211, bottom: 613, frame_height: 732 }
```

Prefer to measure. Those numbers were read from one schedule with five slots
showing (613 is that box's bottom). Measured again on 2026-10-01, the same
schedule's fullest day has eight, so the 0.83.0 window cuts off its last three;
and on a schedule with a different header it slices the heading.
`bin/booking-crop-measure` gives the numbers for yours.

`studio_booking_frame crop: false` still means the whole frame. `crop: true`,
the default, now means "the app's crop", which is none until declared.

An app that renders its own booking page should also set `config.booking_path`
(above); 0.83.0 had no way to name it.

## Coexisting with an app's own copy

An app that still renders local booking partials uses the same `data-booking-*`
attributes. The engine's scripts keep out of its way: their guards are engine
names (`__studioBookingFramesArmed`, `__studioBookingPopupArmed`), and they act
only on engine-rendered elements, which carry `data-studio-booking` (the frame,
its wrapper, the dialog and the links). Write a booking link with
`studio_booking_link`, not by hand, so it carries the marker.

## Markup hooks

Stable, for tests and for an app's own scripts: `[data-booking-wrap]` (also
`[data-booking-crop]` and `.booking-frame-cropped` when cropped, `.is-open` once
used), `iframe[data-booking-frame]`, `dialog[data-booking-dialog]`,
`iframe[data-booking-popup-frame]`, `a[data-booking-popup]`,
`[data-booking-close]`, `[data-booking-page]`. They also carry
`data-studio-booking`.

## Tests

- `test/lib/studio/booking_test.rb`: the crop's derivation and what it refuses,
  and the booking page's path. `test/lib/studio/site_footer_test.rb` holds the
  booking URLs.
- `test/integration/site_footer_test.rb`: what a host renders: whole by default,
  the declared crop, one frame's own, the engine's page, and an app's own page
  named by `booking_path`.
- `e2e/booking_frame.spec.js`: the scripts and the layout in a browser, with
  Google stubbed: deferred loading, whole by default, cropped to declared numbers
  and open on use, two crops on one page, the popup.
- `e2e/booking_crop_measure.spec.js`: the measuring tool's walk and arithmetic,
  against a stub.

`/admin/style` shows the frame's two states under Tricks.
