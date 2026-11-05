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
| `meta`, `meta_title` | Short text beside the title, such as the version, and its `title` attribute. Hidden below 640px. |
| `label` | The nav's accessible name. A row with tabs needs it. |
| `tabs` | `[{ label:, href:, current:, data: }]`. `current` is the `aria-current` value (`"page"`, or `"true"` for a tab that follows the scroll). Leave it blank on the others. |
| `tabs_data` | Data attributes for the tabs' scroller. |
| `actions_html` | A control on the right, for a row with no tabs. |
| `data` | Data attributes for the row, such as the page's own `studio_controller`. |
| `row_class` | The bleed. The default, `-mx-4 px-4`, fits a container with `px-4`. Pass another value in a container with no gutter of its own. |

The partial renders two sibling elements, so call it from the page's long container:
a sticky row can travel only as far as its parent.

Put the space above the row on the container, as `pt-6` is above. The row carries no
top margin, because a stuck row is measured from its place in the flow.

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
the navbar.

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
| `section-target` | A `<section>` with a section header | The section's top on `--pin-section-top`, so the title shows, stuck or about to be. |
| `section-subtarget` | An anchor inside such a section | One `--section-header-h` lower, clear of the section's bar. |

Do not write `scroll-margin-top` by hand: `--nav-h + 5rem` does not know the page row or the bar.

A jump from the top of the page reads the margin while the row is still at rest, so the title
lands up to the row's own rise below the line, in the gap above the section. The title shows,
and it sticks on the next scroll.

The style guide's tab highlight changes when a section's top is within 80px of the page row
(`LINE_SLACK`, `style_section_nav_controller.js`). So a tab can change up to 80px of scroll
before the bar swaps. The slack is what holds the highlight on a clicked tab after the row rises.

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
