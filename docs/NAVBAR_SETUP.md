# Navbar Setup Guide

The Studio engine provides a feature-rich base navbar that each app can copy and customize.

## What the Engine Provides

- **Base navbar partial** (`layouts/_navbar.html.erb`) — sticky header with scroll hysteresis, logo, brand title, user nav, mobile sub-navbar
- **Admin preview page** at `/admin/navbar` — responsive breakpoint simulation with scrolled state toggles
- **Navbar controller** — admin-only, renders the preview page

## Out of the Box

If your app doesn't create its own `app/views/layouts/_navbar.html.erb`, the engine's base navbar renders with:
- Logo from `Studio.logo_for("Navbar Logo")`
- Brand title from `Studio.app_name` (last word in primary color)
- Empty desktop nav section (no links)
- User nav (when logged in) or theme toggle + login button (when logged out)
- Mobile sub-navbar with admin dropdown + theme toggle
- **Link sidebar** (when `Studio.sidebar_sections` is declared — see
  `NEW_APP_SETUP.md` section 4): a trigger button in the desktop icon rail and
  the mobile sub-navbar, plus the slide-out panels rendered after the header.
  With the default empty sections none of it renders, and `preview: true`
  renders always skip it (the `/admin/navbar` preview repeats the partial;
  the panels carry page-unique ids). When the viewer's sections include an
  `admin: true` entry, the sidebar replaces the admin dropdown — both use the
  cog glyph, and two gears side by side read as a duplicate.

## How to Override

Create `app/views/layouts/_navbar.html.erb` in your app. Rails loads app files before engine files, so your partial wins.

Start by copying the engine's version and customizing:
1. Add nav links to the desktop `<nav>` section
2. Add nav links to the mobile sub-navbar
3. Pass custom locals to `_user_nav` (balance, extra icons, etc.)

## Available Locals

| Local | Type | Default | Description |
|-------|------|---------|-------------|
| `preview` | boolean | `false` | Disables scroll handler and sticky positioning |
| `show_logged_in` | boolean | `logged_in?` | Override session-based login check |
| `balance_html` | string | `nil` | Raw HTML for balance display (passed to `_user_nav`) |
| `extra_icons_html` | string | `nil` | Raw HTML for extra icon buttons (passed to `_user_nav`) |
| `scroll_timeline` | boolean | `config.navbar_scroll_timeline` | Opts this render into the scroll-driven collapse (below) |

## Adding Nav Links

### Desktop (hidden on mobile)
```erb
<nav class="hidden md:flex items-center gap-4">
  <%= link_to "Page", page_path, class: "text-secondary hover:text-primary text-sm font-medium transition" %>
</nav>
```

### Mobile Sub-Navbar
```erb
<div class="flex md:hidden items-center gap-3 px-4 py-1.5 overflow-x-auto border-t border-subtle bg-surface-alt">
  <%= link_to "Page", page_path, class: "text-secondary hover:text-primary text-xs font-medium transition whitespace-nowrap" %>
  <span class="ml-auto flex items-center gap-3">
    <%= render "components/admin_dropdown" %>
    <%= render "components/theme_toggle" %>
  </span>
</div>
```

## Logo Configuration

Logos are configured in `config/initializers/studio.rb` via `config.theme_logos`:

```ruby
config.theme_logos = [
  { file: "favicon.png",   title: "Favicon" },
  { file: "logo.png",      title: "Navbar Logo" },
  { file: "logo.jpeg",     title: "Auth Logo" },
]
```

`Studio.logo_for(title)` resolves logos with a fallback chain:
1. Exact title match
2. "Navbar Logo" fallback
3. First logo in the list

The navbar uses `Studio.logo_for("Navbar Logo")`, auth views use `Studio.logo_for("Auth Logo")`.

## Brand Title Auto-Split

`Studio.app_name` is split into words. The last word is rendered in `text-primary`:
- "Tax Studio" → "Tax **Studio**"
- "Turf Monster" → "Turf **Monster**"
- "McRitchie Studio" → "McRitchie **Studio**"

## Brand Heading

The brand title is the page's `<h1>` by default. On a page that carries its own
h1, pass `brand_heading: false` and the brand is drawn as a `<div>` with the same
classes and contents, so the page's title is the outline's only h1:

```erb
<%= render "layouts/navbar", brand_heading: false %>
```

## Brand Wordmark (optional)

An app with a brand lockup (its icon and words drawn as one artwork) can show it
in place of the "Navbar Logo" image and the `app_name` text:

```ruby
config.navbar_wordmark = { light: "/brand/navbar-light.svg",
                           dark:  "/brand/navbar-dark.svg" }
```

`light` is the file for a light page and `dark` the file for a dark page (the
root's `dark` class). Both render; engine.css shows the matching one, so the
theme toggle swaps them with no script. The lockup keeps the root link and the
brand h1 (`brand_heading: false` still makes it a div), with `alt` set to
`Studio.app_name`. It is height-led: its height is the logo's collapse size
(48px expanded, 32px collapsed on desktop, 40px on a phone) and its width is the
artwork's own, scaled down inside the left column on a narrow phone. Crop the
artwork tight to the lockup, with no padding, so it fills that height. `nil`, the
default, leaves the navbar byte-identical; anything other than a Hash with both
paths raises at boot.

## Scroll-Driven Collapse (optional)

```ruby
config.navbar_scroll_timeline = true
```

From 768px, in a browser with scroll-driven animations, the header collapses
on the page's scroll timeline instead of from script. It keeps one height and
is sticky at minus its band (its expanded height less its collapsed height), so
the band scrolls away with the page and the compact bar sticks. The logo,
title, avatar and name shrink by transforms, and the icon rail slides so the
gaps stay even. The compositor runs it with the scroll, so a busy page cannot
make the header stutter. The sizes are the band table's own endpoints: the
`nav-collapse` controller measures them once (on connect, resize, font load
and a bar resize), so an app that overrides the endpoints needs nothing more.

Phones and browsers without scroll timelines (Firefox today) keep the `--nav-p`
collapse; crossing 768px swaps modes. On the timeline `--nav-h` is the compact
bar's height. `false`, the default, leaves the navbar byte-identical. The
`scroll_timeline:` local overrides the setting for one render.

On the timeline the pinned stack (below) publishes where the stack sits once
it has pinned, the compact bar, and writes nothing per scroll frame: it
publishes on a resize, a band re-measure and a change of layers only. A sticky
reader (a board's lane headers) needs nothing more. A `fixed` reader is on
screen at the top of the page too, where the expanded header still reaches
further down; give it `data-pin-edge` and engine.css moves its `top` and
`height` off `--nav-bottom` with the header, on the same scroll timeline, in
CSS. `components/_sidebar_panel` carries it already.

## Reading the Pinned Stack

`studio/pinned_stack` publishes the pinned chrome's geometry as custom
properties on the root: `--pin-stack-bottom` (the bottom of all pinned chrome),
`--pin-<name>-top`, `-h` and `-bottom` per `data-pin` layer, and the legacy
`--nav-h` and `--nav-bottom`. CSS positions off those.

A **script** must never read `--pin-stack-bottom` off the root. While a scroll
is in motion the publisher writes only the elements that read the stack in CSS
and writes the root once the scroll has been still for 160ms, so the root can
be that late. Read it live instead, measured on call:

```js
import { stackBottom } from "studio/pinned_stack"
stackBottom()                          // px, the stack's bottom right now

window.studioPinnedStack.bottom()      // the same, for a script with no import
window.studioPinnedStack.read()        // { bottom, timeline, travel, layers: { nav: { h, top, bottom } } }
```

Neither writes anything. On a scroll-timeline header the read is the pinned
compact bar, the same value CSS readers get.

## CSS Class Hooks

These classes are available for preview CSS targeting:
- `.nav-logo` — the logo image
- `.nav-title` — the brand title (an h1, or a div when `brand_heading: false`)
- `.nav-logo-link` — the link wrapping logo + title
- `.nav-wordmark-brand`, `.nav-wordmark`, `.nav-wordmark-light`, `.nav-wordmark-dark` — the brand lockup when `config.navbar_wordmark` is set
- `.user-nav-col` — the right-side user nav column (fixed width, seats a balance)
- `.user-nav-fit` — the same column when no `balance_html` is passed: shrink-to-fit, with media-stepped `max-width` clamps (14/15/20rem) mirroring `.user-nav-col`

## Responsive Breakpoint System

The navbar handles three responsive tiers via CSS:
- **Tiny** (< 400px) — stacked title, compact spacing
- **Small** (400-767px) — stacked title, medium spacing
- **Desktop** (768px+) — inline title, full spacing

## Admin Navbar Preview

Visit `/admin/navbar` to see the navbar at different breakpoints with:
- Width sliders per breakpoint (Tiny, Small, Tablet)
- Device markers (iPhone 15, iPhone 16 Pro Max, iPad Pro 13")
- Scrolled state toggle per preview
- Username override input
- Both logged-in and logged-out views

## Checklist for New App Setup

1. Add `Studio.logo_for` entries to `config/initializers/studio.rb`
2. Place logo files in `public/`
3. Create `app/views/layouts/_navbar.html.erb` with your nav links
4. Add `<%= render "layouts/navbar" %>` to your layout
5. Visit `/admin/navbar` to verify responsive behavior
