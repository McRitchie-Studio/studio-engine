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
| `show_logout_link` | boolean | `false` | Show "Log out" link in user nav bar |

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

## CSS Class Hooks

These classes are available for preview CSS targeting:
- `.nav-logo` — the logo image
- `.nav-title` — the brand title h1
- `.nav-logo-link` — the link wrapping logo + title
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
