# Branded loader

Every app draws its loader from its own icon, in its own theme colours, with no
per-app markup. One class, `.studio-loader`, sized by `--studio-loader-size`;
the style rides `data-loader-style`. Code: `lib/studio/loader.rb` (config and
art), `app/helpers/studio/loader_helper.rb`, `app/views/studio/loader/`,
`engine-motion.css` ("BRANDED LOADER") and `app/javascript/studio/loader.js`.
The six styles are the ones Alex McRitchie picked from the Loader Lab
(task `branded-app-loader`, 2026-10-28).

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

## Colours

`--studio-loader-color` (halo, frame, sparkle tint) is `--color-primary` and
`--studio-loader-hot` (the orbiting spark) is `--color-accent`, both from the
app's theme tag. The bead's cooling colours are `--studio-loader-bead-1..6`.

## Reduced motion

Under `prefers-reduced-motion: reduce` every loader is a still icon: no
animation, and the halo, orbit spark, bead and sparkle flares are not drawn.

## Lab

`/lab/loader` in the dummy app (`e2e/loader.spec.js`) shows every style on its
brand from `test/fixtures/files/loader`. `/lab/loader_visits` puts the overlay
under Turbo (`e2e/loader_visits.spec.js`, `e2e/loader_bfcache.spec.js`): a slow
page, a background replace visit, `data-turbo="false"` forms and a download
with no extension. `/lab/page_transitions?slow=450` forces the slow page the pace spec times
(`e2e/loader_pace.spec.js`).
