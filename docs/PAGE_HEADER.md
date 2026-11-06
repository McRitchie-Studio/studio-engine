# The page header and the pinned stack

## The rule

A page has up to four pinned layers, each below the last, and none overlaps another:

1. The navbar (`layouts/_navbar`).
2. The page row (`studio/_page_header`): the title, then optional meta and tabs.
3. The section's header (`studio/_section_header`), on a page long enough to want one.
4. A table's sticky header (`config.sticky_table_headers`).

An admin page uses `studio/_page_header` for its title. It does not draw its
own sticky row, and it does not write a pixel height. Each layer takes its place
from the pinned stack ([`NAVBAR_SETUP.md`](NAVBAR_SETUP.md#reading-the-pinned-stack)).

## Using it

```erb
<div class="max-w-7xl mx-auto px-4 pt-6 pb-8 space-y-6">
  <%= render "studio/page_header",
        title: "Models",
        label: "Models",
        tabs: configs.map { |key, config|
          { label: config.fetch(:label), href: admin_model_path(key),
            current: (key.to_s == @key ? "page" : nil) }
        } %>

  ...the page...
</div>
```

| Local | What it does |
|-------|--------------|
| `title` | The page's one `h1`. Required. |
| `crumbs` | The trail above the title: the page's ancestors, root first, as `[{ label:, href: }]`. Build it with `studio_crumbs` (below). |
| `crumb_label` | The page's own name at the end of the trail, when the title is too long for it. The default is the title. |
| `meta`, `meta_title` | Short text beside the title, such as the version, and its `title` attribute. Hidden below 640px. |
| `label` | The tabs' `<nav>` accessible name. A row with tabs needs it. |
| `tabs` | `[{ label:, href:, current:, data: }]`. `current` is the `aria-current` value (`"page"`, or `"true"` for a tab that follows the scroll). Leave it blank on the others. |
| `tabs_data` | Data attributes for the tabs' scroller. |
| `actions_html` | A control on the right, such as the page's one primary action. With tabs, it comes after them. |
| `links` | The page's other links, `[{ label:, href:, current: }]`, on a line of their own at the foot of the row. They stick with it. |
| `links_label` | That line's accessible name. The default is "More links". |
| `data` | Data attributes for the row, such as the page's own `studio_controller`. |
| `row_class` | The bleed. The default, `-mx-4 px-4`, fits a container with `px-4`. Pass another value in a container with no gutter of its own. |

The partial renders two sibling elements, so call it from the page's long container:
a sticky row can travel only as far as its parent.

Put the space above the row on the container, as `pt-6` is above. The row carries no
top margin, because a stuck row is measured from its place in the flow.

## Crumbs

Alex McRitchie's ruling of 2026-11-05: every admin page has a standard crumb trail above an
h2-size title, left-aligned. The page's sub-sections and its most important links go on the
right, as tabs, with at most one primary action. Its other links go on the line under the
title, to be organized later.

**One parent map.** An app names each page that has children once, in an initializer. Each
entry names its label, its address and its parent. The trail builds itself up the chain:

```ruby
# config/initializers/studio_crumbs.rb
Rails.application.config.to_prepare do
  Studio.crumbs.clear.draw do
    page :admin,       "Admin",       :admin_dashboard_path
    page :deployments, "Deployments", :deployments_path, parent: :admin
    page :release,     ->(release:) { release.slug }, ->(release:) { release_path(release) },
         parent: :deployments
  end
end
```

A label or an address is a String, a Symbol (a route helper, read in the view and then on
`main_app`) or a lambda. The view runs a lambda with the keywords it names, taken from the
call. An unknown page raises `Studio::Crumbs::UnknownPage`, and a loop raises
`Studio::Crumbs::Cycle`.

```erb
<%# A page in the map: its ancestors. %>
<%= render "studio/page_header", title: "Deployments", crumbs: studio_crumbs(:deployments) %>
<%# A page not in the map names only its parent. %>
<%= render "studio/page_header", title: @release.slug, crumbs: studio_crumbs(parent: :deployments) %>
<%# A lambda's keywords. %>
<%= render "studio/page_header", title: "Checks", crumbs: studio_crumbs(parent: :release, release: @release) %>
```

**An engine page** (the style guide) cannot know the host's key for itself, so it calls
`studio_crumbs_here`: the map's page whose address is this request's path, or no trail.
A page whose address needs keywords never matches.

**What it draws.**

- From 40rem, the trail is on a line of its own above the title. Each ancestor is a muted
  link, the page itself is bold with `aria-current="page"`, and a chevron (CSS, with empty alt
  text) sits between. It is an `<ol>` in a `<nav aria-label="Breadcrumb">`.
- Below 40rem, the trail gives way to one link to the parent: "‹ Deployments", with the
  accessible name "Back to Deployments".
- Every ancestor link and the parent link carry `data-page-transition-back`, so the page
  transition plays the app's move the other way
  ([`PAGE_TRANSITIONS.md`](PAGE_TRANSITIONS.md#back)).
- The trail is part of the row, so it sticks with the title. The row's box does not change
  between rest and stuck.

**The title.** From 40rem it is the type scale's h2: 30px, at the display weight. On a phone
it is 1.5 times the base, so a long title leaves the tabs room. It stays the page's one `h1`.

## The gliding pill

Alex McRitchie, 2026-11-05: the open tab's pill glides from tab to tab. The row draws one
pill, `.page-header-glide`, with the lit primary button's classes, so it keeps that look in
light, dark and glass. CSS anchor positioning puts it on the tab with `aria-current`, and its
insets transition. So when the scroll spy (`style-section-nav`) or a page moves
`aria-current`, the pill slides. No script measures anything; `aria-current` stays the one
source of truth.

- The tab with `aria-current` gives up its own fill, and each label sits above the pill.
- With reduced motion, the pill jumps.
- With no tab current, there is no pill.
- The track sets `anchor-scope: --page-header-current`, so two rows on one page each
  anchor their own pill.
- **Support.** The block is inside `@supports (anchor-name: --a) and (position-anchor: --a)
  and selector(:has(a))`. Where that fails, the block does nothing, and each tab keeps its
  own fill, as before. Measured: Chromium (the e2e lane) supports it and plays the glide.
  Safari and Firefox were not measured here.

## How it behaves

- **At rest** the row has no background and no border. It reads as a normal page
  header, with the tabs floating on the right.
- **Once stuck** under the navbar it takes the bar. Its height does not change
  between the two states, so the change moves nothing.
- **In a flex or grid parent** it behaves the same. The sentinel sits at the parent's
  start there, so the controller measures the row's place from the row.
- **A long title** wraps. If it leaves the tabs less than 6rem, the tabs move to their
  own line under it, at full width. The title stops at three lines with an ellipsis;
  the whole text stays in the `h1`. The page never scrolls sideways, and a short title
  keeps the row on one line.
- **On a phone** the tabs scroll sideways inside the row, and the page does not. The
  open tab is scrolled into view on load. A fade marks an end that hides a tab.
- **If the `page-header` controller fails to load**, the row keeps its bar at all
  times. The tabs are links, so they still work.

## The stack

The row carries `data-pin="page"` and positions off `--pin-page-top`, the bottom of
everything above it. It must not position off `--pin-stack-bottom`: that value
includes the row's own edge, so the row would chase itself down the page.

Anything that sits under the stack positions off `--pin-stack-bottom` or, in a
script, `window.studioPinnedStack.read()`. It needs no edit when a page adopts the
row. The sticky table header's clone is one such reader. It needs
`config.sticky_table_headers` on in the host, or the `sticky_table_headers` local on
the head partial. The engine draws no `position: sticky` header cells of its own: a
page that draws them gets no clone, and points their `top` at `--pin-stack-bottom`.

At rest the row's bottom edge is part of the stack, so `--pin-stack-bottom` is lower
at the top of the page than once the row has stuck. A sticky reader under the row
sees no difference. A `fixed` reader that must sit right under the navbar reads
`--nav-bottom` instead.

The row is never a `<header>`: the publisher takes the document's first `<header>` as
the navbar. Nor is it a landmark: the row is a `<div>`, and the tabs, the crumb trail and
the links line are each their own `<nav>`, side by side, so no landmark nests in another.

The partial is `studio/_page_header`, not `components/_page_header`. A host's view
wins over the engine's at the same path, and the hub has its own
`components/_page_header` with other locals.

## The section header

A long page keeps its reader's place with a section title that stays on screen. The page
row stays, the section's header sits directly under it, and when the next section arrives
its header takes the place.

```erb
<section id="modals" class="section-target space-y-8">
  <%= render "studio/section_header", title: "Modals" %>
  ...the section...
</section>
```

| Local | What it does |
|-------|--------------|
| `title` | The heading's text. Required. |
| `level` | The heading's tag. The default is `:h2`. |
| `row_class` | The bleed, as on the page row. The default is `-mx-4 px-4`. |

The rules for the page:

- **Make it the first direct child of its `<section>`.** It is sticky, and a sticky element
  travels only inside its parent. That parent is what gives the swap, with no scroll script.
  In a wrapper `div` it leaves with the wrapper. Keep an intro paragraph as its next sibling.
  Put no top padding on the section: the section's top is how the publisher knows the header
  has left its place.
- **Stick one level.** One bar shows at a time. Do not nest a section header in a section header.
- **No `overflow`, `transform` or `backdrop-filter` on an ancestor.** Each of these can
  stop a sticky element or its blur.

How it behaves:

- **At rest** it reads as a normal section title, with no background and no border.
- **Stuck** it takes the page row's bar: solid surface in light and dark, and the glass bar
  under `data-surface-style="glass"`. Its box does not change, so the change moves nothing.
  Under glass, while it is stuck, it owns the round bottom corners and the page row goes
  square, so no page shows in a notch between the two.
- **It stays one line.** A long title ends in an ellipsis on the bar, and the whole text stays
  in the heading. The bar is 2.25rem at every width, `--section-header-h`.
- **On a phone** the same 2.25rem bar is the smaller treatment, and the title keeps its size.
  Measured at 390x844 under the lab's two-row navbar: 86px navbar, 54px row, 36px bar, so 176px,
  21% of the screen.
- **On a short screen**, under 36rem tall, such as a small phone or one on its side, it stays
  in the flow and never sticks: the navbar and the page row already take a quarter of the height.
- **If the pinned stack does not run**, it stays in the flow. With no publisher, no bar would
  come, and a clear title would lie over the page.

### How it joins the stack

A section header is in the stack, so a table's sticky header and any other reader of
`--pin-stack-bottom` sit under it with no edit. It does not carry `data-pin`. Every layer of
the registry counts by its bottom edge, so a header waiting below the fold would drag
`--pin-stack-bottom` down the page, and headers sharing a name would overwrite each other.

So each one carries `data-pin-section`, and together they publish as one layer, `section`:

- `--pin-section-top` is the bottom of the layers above. It stands whether or not one is
  stuck, and every header positions off it.
- `--pin-section-h` and `--pin-section-bottom` are 0 until one is stuck. While the end of its
  section pushes it out, they shrink frame by frame, so a reader under it rises with it.
- `window.studioPinnedStack.read().layers.section` is the same, for a script.

The publisher puts `data-stuck` on the stuck header, and `data-pin-section-stuck` on the root.

### Where a jump lands

| Class | On | Lands |
|-------|----|-------|
| `section-target` | A `<section>` with a section header | Its top just past the pinned line, `--nav-h` plus `--pin-page-h`, so its title shows on its bar. |
| `section-subtarget` | An anchor inside such a section | One `--section-header-h` lower, clear of the section's bar. |

Do not write `scroll-margin-top` by hand: `--nav-h + 5rem` does not know the page row or the bar.

These are CSS alone. No script moves the page after a jump, so a Back, a reload, a Turbo visit
and a scroll by the reader or the app all keep their place.

**A first jump from the top of the page lands low.** The navbar is still tall when the browser
reads the margin, and it collapses after the jump. So the title lands by the collapse below the
line: 75px on the hub at 390px, 38px on Turf, and 0 on both at desktop width. The title shows and
the bar comes on the next scroll. Later jumps land on the line.

**Keep the sections further apart than that.** If the gap between two sections is smaller than the
collapse, the section above still shows a sliver of its bar after the jump. The style guide's gap
is 6rem for this reason. Its tab highlight has the same margin, `LINE_SLACK`, 80px, so a tab can
change up to 80px of scroll before the bar swaps.

A short last section cannot reach the line, so the section above it can keep its bar, with the
title lower on the screen.

## Who has adopted it

The page row: `style/index`, `studio/admin_models/show` and `studio/admin_surveys/index`.
The section header: `style/index`, every section.

These engine pages have not adopted the row. Each needs more than the row has today:

- `studio/admin_surveys/show`: a back link and a mono subtitle.
- `studio/models/show`: an eyebrow and a mono subtitle.
- `studio/knowledge_docs/_browser`, `_coverage_table` and `show`: a title with a live
  badge, filters that wrap, a subtitle.
- `studio/emails/index`: an eyebrow and a long description in its `<header>`.
- `studio/geo_settings/edit` and `studio/site_identities/edit`: a title only, but no
  gutter of their own. The bar needs one, or a stuck title meets its left edge.
- `navbar/show`: a review page for the navbar itself, with its own controls.

Public pages (`studio/bookings/show`, `studio/public_users/show`, `studio/surveys/*`)
and the sign-in pages have no admin chrome, so the rule does not apply to them.
