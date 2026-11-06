# Branded loader

Every app draws its loader from its own icon, in its own theme colours, with no
per-app markup. One class, `.studio-loader`, sized by `--studio-loader-size`;
the style rides `data-loader-style`. Code: `lib/studio/loader.rb` (config and
art), `app/helpers/studio/loader_helper.rb`, `app/views/studio/loader/`,
`engine-motion.css` ("BRANDED LOADER") and `app/javascript/studio/loader.js`.
The six styles are the ones Alex McRitchie picked from the Loader Lab
(task `branded-app-loader`, 2026-10-28). The branded loader is one member of a
family of eight; the rest are in [The family](#the-family) below.

## Declare the style

In `config/initializers/studio.rb`; the default is `:breathe`, so an app that
says nothing still gets a branded loader:

```ruby
config.loader = :orbit
config.loader = { style: :sparkle, icon: "/brand/icon-dark.svg", art: "/brand/loader-sparkle.svg" }
```

| Key | Default | Meaning |
|---|---|---|
| `style` | `:breathe` | one of the styles below |
| `icon` | the navbar brand's logo, else theme_logos' "Navbar Logo" | the image every style draws |
| `art` | none | the marked-layer SVG a signature style needs |

An unknown style or key, or a signature style without `art`, raises at boot.

## The styles

| Style | Lab | Kind | Picked for |
|---|---|---|---|
| `breathe` | 01 | generic, the default | any app; buttons |
| `liquid` | 03 | generic, takes `percent:` | uploads, imports |
| `orbit` | 04 | generic | Commercial Welding (second style) |
| `steel` | 09 | generic | McRitchie Industries |
| `weld_bead` | 05 | signature, needs `art` | Commercial Welding |
| `sparkle` | 08 | signature, needs `art` | McRitchie Studio |

**Generic** styles draw the icon as an image and nothing else, so they fit any
app. **Signature** styles animate parts of the icon, which an image cannot
expose, so the app supplies an art file: an SVG in the **icon's own viewBox**
holding only the animated layers, marked with `data-loader`:

```xml
<!-- weld_bead: the one line the bead runs -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 264.3 300.2">
  <path data-loader="outline" d="M133.1 300C..."/>
</svg>

<!-- sparkle: each spark, in the order they flare; group transforms are kept -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 662.45 538.14">
  <g transform="translate(-2,-1.81)"><path data-loader="spark" d="..."/> ...</g>
</svg>
```

The icon is drawn underneath and the layers are inlined over it, so the two
files must share a viewBox. Art that is missing, outside `public/`, or has no
marked layer falls back to Breathe rather than blanking the loader.

## The standard pace

Every app has one standard for quick loads and long loads:

| The visit | What the user sees |
|---|---|
| Under 350ms | No loader, and no added wait |
| Longer | The loader appears at 350ms and stays at least 750ms, until the page is ready |

Both numbers are defined once, in `Studio::Loader` (`OVERLAY_DELAY_MS`, `OVERLAY_MIN_SHOW_MS`).
`studio/loader` falls back to the same two, and a test holds them level.

**Every engine app gets this with no view edit.** `layouts/studio/_head` carries the overlay in
a `<template>`, because the body is the host's, and `studio/loader` adds it to the body when a
visit starts. A host that still calls `studio_loader_overlay` keeps its own, and only that one
shows. `config.loader_overlay = false` opts an app out. A layout that does not render
`layouts/studio/_head` gets neither: Rantly has its own head today.

**Where the wait is.** The wait is on the visit's response, before Turbo sees it. Turbo's
`turbo:before-render` comes too late. A view transition has already taken the old page's picture
by then, with rendering paused, so a wait there freezes the loader and carries it out inside the
moving picture. So the loader stays live through its minimum, hides, and only then does Turbo
take the picture and play the move. The move's image wait (at most 500ms) runs after that, inside
the render, so neither wait can cut the other short. They add. With transitions off the same
minimum applies, and the page swaps when it ends.

**What never waits:** a frame, a form or a prefetch response; a failed visit, a 4xx or 5xx page;
a download or other non-HTML response; a network failure; a refresh or poll (a `replace` shows no
overlay); Back to a cached page, where no overlay appears; a response that asks for a full load
(`turbo-visit-control: reload`, as a signing page does), since the second load is the one that paints.

**`StudioLoader.hide()` is immediate.** It ignores the minimum and ends any wait, because the
caller owns that moment. A caller's `StudioLoader.show()` has no minimum. A form marked
`data-studio-loader-overlay` keeps its overlay up for the rest of the minimum, with nothing else
held. Turbo's top progress bar is unchanged.

Measured in the lab, Chromium, from the click (`e2e/loader_pace.spec.js`):

| Page answers at | Loader in | Loader out | Move start | Move end |
|---|---|---|---|---|
| About 50ms | Never | Never | 68 | 785 |
| 450ms | 385 | 1138 | 1162 | 1886 |
| 1500ms | 378 | 1572 | 1572 | 2287 |

## Use it

```erb
<%= studio_loader %>                               <%# 96px, the app's style %>
<%= studio_loader size: 20, label: "Saving" %>     <%# inline, beside text %>
<%= studio_loader style: :liquid, percent: 40 %>   <%# a fill that follows a percent %>
<%= studio_loader_overlay delay: 500, min_show: 0 %> <%# only to differ from the standard: once, in the layout body %>
```

- **Page loads.** The overlay renders hidden. `studio/loader`
  shows it when a visit the user started (a Turbo `advance` or `restore`)
  outlasts its `delay:` (350ms) and hides it at the end of its `min_show:` (750ms), or
  when the page arrives if that is later. A fast load never flashes it. A `replace` visit never shows it: that is a background
  refresh, such as a poll's `Turbo.visit(url, { action: "replace" })` or Turbo
  8's page refresh; frames and prefetches fire no visit at all. So is a link
  marked `data-turbo-action="replace"`, even one the user clicks. A form marked
  `data-studio-loader-overlay="Caption"` shows it while it submits.
  `window.StudioLoader.show("Caption")` / `.hide()` cover any other long wait.
- **Always clears.** A Turbo visit whose response is not HTML (a download at a
  URL with no extension) clears at once, on `turbo:reload`. Leaving the page
  (`pagehide`) and a back/forward-cache restore (`pageshow`) clear the overlay
  and every busy button. A submit Turbo does not drive clears its overlay and
  busy button after `max_wait:` (15000ms), because a `data-turbo="false"` form
  whose response is a download replaces no page; raise it for a form that
  legitimately waits longer. A Turbo visit is never capped: it always ends in
  an event. The cap never hides an overlay `StudioLoader.show` opened.
- **Announced.** The overlay's `role="status"` label ("Loading") is a live
  region, re-said each time the overlay shows. The overlay is never
  `aria-busy`, which would mute it. During a Turbo visit Turbo marks `<html>`
  `aria-busy` itself, so a screen reader that honours it hears the status for
  `StudioLoader.show` and non-Turbo submits, not for Turbo visits.
- **Pending buttons.** Put `studio_loader_pending` inside the button (a small
  Breathe in the button's text colour) and mark what it replaces
  `data-loader-idle`. It shows while the button or its form is
  `aria-busy="true"`: Turbo marks a submitting form itself; for a form Turbo
  does not drive, `studio/loader` marks the submitter.
- **Percent.** `StudioLoader.setPercent(el, n)` moves a `percent:` loader.

## The family

Every app has eight ways to say "wait". Pick the one that matches the wait
(task `engine-loader-family`, from a reel Alex McRitchie shared). `/admin/style`
shows all eight in its Loaders section.

| Loader | Use it for | Code |
|---|---|---|
| Spinner | A short wait beside text or in a control | `studio_loader style: :spinner` |
| Skeleton | Content that is on its way; the page keeps its layout | `studio_skeleton :card, count: 3` |
| Progress bar | A wait you can measure; with no percent it sweeps | `studio_loader style: :bar, percent: 40` |
| Pulsing dots | A reply on its way, such as a chat answer | `studio_loader style: :dots` |
| Button loader | A submit in flight | `studio_loader_pending` in the button |
| Full screen | A page load longer than 350ms | the overlay, above |
| Pull to refresh | Reloading a feed on a phone | `studio_pull_to_refresh` |
| Infinite scroll | A long list, one page at a time | `studio_infinite_scroll` |

### Plain styles: spinner, dots and bar

They draw no icon, only the theme's colours (`--studio-loader-color`, the
primary). They are styles of `studio_loader`, not new classes: each wraps the
engine's canonical motion rule (`.spinner`, `.loading-dots`, `.progress-meter`)
and only sets its knobs. Those classes still work alone; a later adoption task
moves the hub and Turf onto the helper. An app's own `config.loader` refuses a
plain style, because the app's loader draws its icon.

```erb
<%= studio_loader style: :spinner %>                     <%# 20px %>
<%= studio_loader style: :dots, label: "Alex is typing" %> <%# 32px wide %>
<%= studio_loader style: :bar, percent: 62, label: "Uploading" %>
<%= studio_loader style: :bar %>                         <%# no percent: it sweeps %>
```

- **Size.** `size:` is the ring's diameter, the dots' row width, or the bar's
  width (default `100%`; its height is `--studio-loader-bar-height`, 6px).
- **The bar is a progressbar.** Its label is its accessible name. A percent is
  its `aria-valuenow`; with none it has no value, which is how an indeterminate
  progressbar reads. `StudioLoader.setPercent(el, n)` moves it, sets the value,
  and stops the sweep.
- **In a button.** `studio_loader_pending style: :spinner` is the spinner in the
  button's text colour. Words the button says only while busy ("Saving…") go
  in an element marked `data-loader-busy`; what they replace is `data-loader-idle`.

### Skeleton

Grey shapes of the content to come. The wrapper is `aria-busy="true"`; every
shape is `aria-hidden`; one screen-reader line (`label:`, default "Loading")
names the wait. The shapes are tints of `--color-text`, so one rule reads on a
dark, light or glass surface. The shimmer stops under reduced motion.

```erb
<%= studio_skeleton %>                                     <%# three lines %>
<%= studio_skeleton :avatar, count: 4 %>                   <%# list rows %>
<%= studio_skeleton :card, count: 3, class: "sm:grid-cols-3" %>
<%= studio_skeleton :media, lines: 2 %>
```

The wrapper is a grid, and any html option lands on it. A natural home is the
placeholder of a lazy frame: Turbo marks the frame busy and swaps the skeleton
out when the content arrives.

```erb
<turbo-frame id="feed" src="<%= feed_path %>" loading="lazy">
  <%= studio_skeleton :card, count: 3 %>
</turbo-frame>
```

### Infinite scroll

The view renders the same call for every page. The block is one page of items:

```erb
<%= studio_infinite_scroll id: "posts", page: @page,
      next_url: (posts_path(page: @page + 1) if @more),
      announce: "%{count} more posts loaded", class: "grid gap-4" do %>
  <% @posts.each do |post| %><%= render post %><% end %>
<% end %>
```

- **How it grows.** After its items, a page leaves a `<turbo-frame>` for the
  next page, holding a "Load more" link to `next_url`. Page 2 and later render
  their items inside that frame, so Turbo lifts just the frame out of the
  response and the list grows in place. The frames take no box
  (`display: contents`), so the items flow into the list's own grid. Use a
  `div` list, not a `ul`.
- **When it loads.** `studio/infinite_scroll` (a lazy controller) watches the
  button's row and loads the frame once it comes within 600px of the viewport.
  No click is needed, and each page loads once.
- **The button stays.** "Load more" is always visible. While a page loads,
  Turbo marks the frame busy and the button shows a spinner. A keyboard press
  moves focus to the first new item. With no script, the link opens the next
  page as an ordinary page, so every page must render the whole view.
- **Announced.** A polite status line says how many items came, and, on the
  last page, `end_label:` ("That is everything").
- **Cheaper frames.** A frame request renders the whole page; a host may skip its
  layout when `turbo_frame_request?`.

### Pull to refresh

```erb
<%= studio_pull_to_refresh do %>          <%# reloads the page (a replace visit) %>
  ...
<% end %>
<%= studio_pull_to_refresh frame: "feed" do %>  <%# reloads one frame %>
  ...
<% end %>
```

Phone widths and touch only (`(pointer: coarse) and (max-width: 640px)`):
elsewhere the wrapper does nothing. A pull from the top of the page past the
threshold refreshes; a short pull settles back. While it is armed, the browser's
own pull (Chrome on Android) is off, so one pull never refreshes twice. The
refresh is a `replace` visit, so the page-load overlay never shows for it.
It is an extra, never the only way: the browser's reload still works, and a
keyboard user never needs it.

**Not yet verified on a real phone.** The browser lane drives it with synthetic
touch events in Chromium at phone width. iOS Safari's own rubber-band scroll and
a real Android Chrome have not been tried; that is a follow-up.

## Colours

`--studio-loader-color` (halo, frame, sparkle tint) is `--color-primary` and
`--studio-loader-hot` (the orbiting spark) is `--color-accent`, both from the
app's theme tag. The bead's cooling colours are `--studio-loader-bead-1..6`.

## Reduced motion

Under `prefers-reduced-motion: reduce` every loader is a still icon: no
animation, and the halo, orbit spark, bead and sparkle flares are not drawn.

## Lab

`/lab/loaders` is the style guide's own Loaders section, with its demo feed at
`/lab/loaders_feed`; `/lab/pull_to_refresh` stamps each render so a pull shows
(`e2e/loader_family.spec.js`, `LoaderLabController`).

`/lab/loader` in the dummy app (`e2e/loader.spec.js`) shows every style on its
brand from `test/fixtures/files/loader`. `/lab/loader_visits` puts the overlay
under Turbo (`e2e/loader_visits.spec.js`, `e2e/loader_bfcache.spec.js`): a slow
page, a background replace visit, `data-turbo="false"` forms and a download
with no extension. `/lab/page_transitions?slow=450` forces the slow page the pace spec times
(`e2e/loader_pace.spec.js`).
