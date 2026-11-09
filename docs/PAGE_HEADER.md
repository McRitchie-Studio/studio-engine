# The page header and the pinned stack

## The rule

A page has up to four pinned layers, each below the last, and none overlaps another:

1. The navbar (`layouts/_navbar`).
2. The page row (`studio/_page_header`): the title, then optional meta and the controls
   on the right (tabs or anchors, a Links menu, one action, tools).
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
| `title` | The page's one `h1`. Required. The row records it, so the navbar draws its brand as a div (docs/NAVBAR_SETUP.md, Brand Heading). |
| `crumbs` | The trail above the title: the page's ancestors, root first, as `[{ label:, href: }]`. Build it with `studio_crumbs` (below). |
| `crumb_label` | The page's own name at the end of the trail, when the title is too long for it. The default is the title. |
| `meta`, `meta_title` | Short text beside the title, such as the version, and its `title` attribute. Hidden below 640px. |
| `label` | The pill group's `<nav>` accessible name. A row with tabs or anchors needs it. |
| `tabs` | Views of the same thing, `[{ label:, href:, current:, data: }]`. `current` is the `aria-current` value (`"page"`, or `"true"` for a tab that follows the scroll). Leave it blank on the others. |
| `anchors` | Sections of this page, `[{ label:, href: "#id", current:, data: }]`. The same pill group as tabs. A row takes `tabs` or `anchors`, never both. |
| `tabs_data` | Data attributes for the pill group's scroller. |
| `menu`, `menu_label` | Related pages elsewhere, `[{ label:, href:, data: }]`, behind one neutral button. The label is "Links" by default. |
| `action` | The page's one primary action, `{ label:, href:, data: }`. Rightmost. |
| `tools_html` | Local-only and dev controls, after the action, muted. |
| `actions_html` | **Deprecated.** Free HTML after the pill group. It renders for one more release and warns in development. Use the locals above. |
| `links` | The page's other links, `[{ label:, href:, current: }]`, on a line of their own at the foot of the row. They stick with it. |
| `links_label` | That line's accessible name. The default is "More links". |
| `data` | Data attributes for the row, such as the page's own `studio_controller`. |
| `row_class` | The bleed. The default, `-mx-4 px-4`, fits a container with `px-4`. Pass another value in a container with no gutter of its own. |

The partial renders two sibling elements, so call it from the page's long container:
a sticky row can travel only as far as its parent.

Put the space above the row on the container, as `pt-6` is above. The row carries no
top margin, because a stuck row is measured from its place in the flow.

## The four kinds of control

Alex McRitchie, 2026-11-06: the controls on the right of a page header follow one
convention. The /deployments header showed a grey pill, a purple button and a black
button side by side, three looks for one row. The right side now takes four kinds of
control, each with one look.

**Which kind is it?** Ask these questions in order, and stop at the first yes:

1. **Does it make or change something?** It is the **action** (`action:`). A page has at
   most one: "New Task", "Invite". A second action goes on the page, not in the header.
2. **Is it a view of the same data?** It is a **tab** (`tabs:`): Deployments | Triage,
   Users | Teams. The tab for this page carries `current: "page"`.
3. **Is it a place on this page?** It is an **anchor** (`anchors:`), with an `href` of
   `#id`: the style guide's sections. The engine's same-page link handler
   (`studio/in_page_links`, below) scrolls to it, with no visit.
4. **Is it a page somewhere else?** It is a **quick link** (`menu:`), in the Links menu.
5. **Does only a developer need it** (a local-only seeder, a progression tester)? It is a
   **tool** (`tools_html:`). Render it only where it applies, for example
   `(render("dev_tools") if Rails.env.local?)`.

Something that fits none of these, such as a count or a status badge, is not a control.
Put short text beside the title with `meta:`.

```erb
<%= render "studio/page_header",
      title: "Deployments", crumbs: studio_crumbs(:deployments), label: "Views",
      tabs: [{ label: "Deployments", href: deployments_path, current: "page" },
             { label: "Triage", href: triage_path }],
      menu: [{ label: "Stages", href: stages_path }, { label: "Docs", href: docs_path }],
      action: { label: "New Task", href: new_task_path },
      tools_html: (render("dev_board_tools") if Rails.env.local?) %>
```

**One order, one height.** The partial draws them in this order, whatever order the call
names them in: the pill group (tabs or anchors), the menu, the action, then the tools.
Every control is a `.btn-sm`. In the row a small primary button takes a clear 1px border,
the width of a neutral button's, so all four kinds stand at one height (measured at 28px
against 30px without it).

| Kind | Look | Behaviour |
|------|------|-----------|
| Tabs | The pill group, with the gliding pill on the current tab | Links to the other views |
| Anchors | The same pill group | Same-page links: `studio/in_page_links` scrolls, with no visit. A scroll spy can move `aria-current` |
| Quick links | One neutral "Links" button with a chevron | Opens a list of links under the button's right edge |
| Action | One primary button, rightmost of the page's own controls | A link to the thing it makes |
| Tools | Muted, behind a dashed rule, full strength on hover or focus | Whatever the host renders |

A row has one pill group. Passing both `tabs:` and `anchors:` raises `ArgumentError`, and
so does an `action:` that is not one Hash.

### The Links menu

The menu is a disclosure, not an ARIA menu: a button and a list of links that Tab walks.

- The button opens the list with the browser's popover (`popovertarget`, `popover="auto"`).
  The browser closes it on Escape and on a click outside, and gives focus back to the
  button. None of this needs a script, so the menu still works when the `page-header`
  controller fails to load.
- The `page-header` controller sets `aria-expanded` on the button and keeps it in step.
  ArrowDown on the button opens the list and moves focus to the first link.
- Where the browser has CSS anchor positioning, the list hangs under the button, its right
  edge on the button's, and flips when there is no room. Elsewhere the controller places it
  (`menuPlacement` in `studio/page_header`) and moves it on scroll. Chromium was measured in
  the e2e lane; Safari and Firefox were not measured here.

**The Links menu or the links line?** Both hold pages elsewhere.

- Use the **menu** for a few related pages, about two to six, that a reader wants now and
  then. It costs one button of width.
- Use the **links line** (`links:`) for many sibling pages, a section's whole set, that a
  reader moves between often. It is always visible, on its own line under the title.
- A page can have both. Do not list one page in both.

### Moving off actions_html

`actions_html` renders for one more release, where it always stood: after the pill group,
before the menu. In development, the first render that passes it writes one warning to the
log for each call site (`Studio::PageHeader.deprecate_actions_html`). Other environments
say nothing. Move each control to its kind: a pill group of views to `tabs:`, a "Links"
dropdown to `menu:`, a primary button to `action:`, local-only controls to `tools_html:`,
and a badge or count to `meta:`.

## Crumbs

Alex McRitchie's ruling of 2026-11-05: every admin page has a standard crumb trail above an
h2-size title, left-aligned. The page's sub-sections and its most important links go on the
right, as tabs, with at most one primary action. Its other links go on the line under the
title, to be organized later. [The four kinds of control](#the-four-kinds-of-control) is
that convention in full.

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
`Studio::Crumbs::Cycle`. `studio_crumbs` lets them raise only in development and test.
In any other environment (QA and production alike) it reports the error to `ErrorLog`, or
else `Rails.logger`, once per message per process, and the page draws no trail.

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

These are CSS alone. A click on a tab is a scroll by `studio/in_page_links` (below), which
reads the same margin. No script moves the page after a jump has settled, so a Back, a reload,
a Turbo visit and a scroll by the reader or the app all keep their place.

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

### In-page links

Alex McRitchie, 2026-11-06, on the style guide's tabs: "The system needs to understand when a
scroll down is the solution rather than a page change." Turbo 8 makes a click on `#tricks` a
full visit: a fetch, a render, `turbo:visit` and the page transition. So the engine takes that
click itself, on every page of every app. Code: `app/javascript/studio/in_page_links.js`,
imported by `studio/application`.

A click is taken when all of these hold:

- It is a plain click: the main button, no modifier key, and no handler took it first.
- The link's address is this page: the same origin, path and query.
- The link has a `#fragment`, and an element on the page has that id (or is an `<a name>`).
- The link has no `target` other than `_self`, no `download`, no `data-turbo="false"` on it
  or an ancestor, no `data-turbo-method`, `data-method` or `data-turbo-stream`, and no
  `data-turbo-frame` other than `_top`.

Every other link is left to Turbo or the browser, as before.

| Step | What happens |
|------|--------------|
| Scroll | A smooth scroll to the target. Its own `scroll-margin-top` (`section-target`, `section-subtarget`) sets where it stops. With none, it stops under the pinned stack, measured at the click. Under reduced motion, it jumps. |
| A target that moves | Content that grows on the way (a lazy frame, the navbar's collapse) moves the target, so the scroll aims again until it lands, or until the reader scrolls, touches, presses or types. |
| After the end | For 3 seconds (`HOLD_MS`) the target keeps its place on the screen: content above it that grows or shrinks (a lazy frame whose page lands after the scroll) moves the page by the same amount, in the frame before it paints, as scroll anchoring would. The body has scroll anchoring off (`studio/_head`), so the browser does not do this. The first wheel, touch, key or press, any scroll the module did not make, the next jump, or Back ends the hold. Growth later than 3 seconds is not followed. |
| History | The fragment is pushed, with Turbo's own state, and `hashchange` fires. Back and Forward between this page's entries scroll to the reader's earlier place, or to the fragment, with no Turbo restore visit. A Back from another page is Turbo's. |
| Focus | The target takes focus with `preventScroll`. One that is not focusable gets `tabindex="-1"` and `data-in-page-focus` (no ring) until it loses focus. |
| Events | `studio:in-page-scroll` bubbles from the link when the scroll starts (`detail: { link, target, hash }`). `studio:in-page-scroll-end` fires on the document when it settles (the browser's `scrollend`, or 400 ms after the last scroll event when `scrollend` never comes; a quiet spell of 150 ms in a browser without `scrollend`) or the reader takes over. The hold after the end runs past this event. |

The style guide's tab row holds the clicked tab as current from the first event to the second,
so the highlight does not run through every tab the scroll passes. A component that changes
a panel by its hash keeps its own click: its handler runs first and prevents the default.

## In a plain-CSS app

The row is styled by the engine's Tailwind layer (`engine.css`). An app that does not
build that layer, such as rantly (plain CSS, the engine taken for the site footer only),
turns on the self-styled row:

```ruby
# config/initializers/studio.rb
Studio.configure do |config|
  config.page_header_self_styled = true   # or ->(view) { ... }
end
```

Then the first `studio/_page_header` on a page also renders `studio/page_header/_assets`,
once (`studio_page_header_assets`, `Studio::PageHeaderHelper`). It is the site footer's
pattern (`studio/site_footer/_assets`):

- **Scoped CSS.** Every rule is under `.page-header`, and each colour reads a theme token
  with a fallback beside it. The rules are the ones `engine.css` gives the row, the `.btn`
  family at `.btn-sm`, and `.label-upper`. The default bleed (`row_class: "-mx-4 px-4"`)
  is defined on the row alone, so it fits a plain container with a 1rem gutter.
- **A small module, no Stimulus and no import map.** `studio/page_header_self_styled` imports
  nothing and loads by its own `<script type="module">` tag (no inline script). It marks the row stuck, fades an end
  of the tabs that hides a tab, shows the open tab on a phone, keeps each Links menu's
  `aria-expanded` in step (with ArrowDown into the list), and places the menu where the
  browser has no anchor positioning. With no pinned stack on the page, it publishes
  `--nav-bottom` from the document's first `<header>`, when that header is sticky or
  fixed, so the row sticks under the app's own masthead. An app whose CSS sets
  `--nav-bottom` or `--pin-page-top` itself keeps its value.
- **Without the script** the row keeps its bar at all times (a `<noscript>` rule). The
  menu is the browser's popover and the tabs are links, so both still work.
- **The CSP nonce.** The `<style>` and the module tag carry the request's nonce when the
  app sets one. The module is served from the asset path (`asset_path`), which the engine
  adds for propshaft and sprockets alike.

Off (the default), the partial renders exactly what it always has: the helper returns
nil on the sentinel's own line, so a Tailwind app's row is the same to the byte
(`test/views/page_header_self_styled_test.rb`). Do not turn it on in an app that builds
`engine.css`: the two sheets say the same thing twice.

**The tokens it reads.** Map them onto the app's own colours on `:root`, light and dark:

| Token | Used for | Fallback |
|-------|----------|----------|
| `--color-text` | The title, the current crumb, a hovered link, the neutral button's label | `currentColor` |
| `--color-text-body` | The menu's links | `currentColor` |
| `--color-text-muted` | The crumbs, the parent link, the links line, the meta | `--color-text-secondary`, then `currentColor` |
| `--color-surface` | The stuck bar, the menu's panel | `Canvas` |
| `--color-surface-alt` | The neutral button, a hovered menu link | `--color-surface` |
| `--color-border` | The stuck bar's edges, the menu's border, the neutral button's border | a 25% grey |
| `--color-primary` | The primary button (the open tab, the action), the focus ring | violet |
| `--btn-primary-fg` | The primary button's label | `#fff` |

`--color-cta`, `--color-cta-fill`, `--color-cta-hover`, `--color-border-strong`,
`--color-primary-ink` and `--type-base` are read first where an app has them. A light
primary that fails 4.5:1 under white sets `--btn-primary-fg` to a dark ink.

`e2e/page_header_self_styled.spec.js` drives it in a plain-CSS host
(`layouts/plain_css_lab`), light and dark, at 1280px and at an emulated 390px.

## The legal page

`studio/_legal_page` is the standard frame for an app's privacy policy and terms: the page
header (the page's one `h1`), a "Last updated" line and a readable column, 46rem at most.
Render it as a layout around the page's sections:

```erb
<%= render layout: "studio/legal_page",
      locals: { title: "Privacy Policy", updated: "November 8, 2026",
                links: [{ label: "Terms of Service", href: terms_path }],
                data: { legal_page: "privacy" } } do %>
  <section>
    <h2>1. Who We Are</h2>
    <p>...</p>
  </section>
<% end %>
```

| Local | What it does |
|-------|--------------|
| `title` | The page's one `h1`, in the header. Required. |
| `updated` | The date the text last changed. Printed as "Last updated" and the date. |
| `crumbs`, `links` | The header's trail and links line, as `studio/_page_header` takes them. |
| `data` | Data attributes for the column, such as `data-legal-page`. |

The column brings its own scoped CSS, once per page, reading the same tokens, so it reads
the same in a Tailwind app and a plain-CSS one. Its `h2`, `h3`, paragraphs, lists, links
and `strong` are styled; write plain elements inside it. A plain-CSS app also sets
`config.page_header_self_styled`, so the header is styled too.

## Who has adopted it

The page row: `style/index`, `studio/admin_models/show` and `studio/admin_surveys/index`.
The section header: `style/index`, every section.
The four kinds of control: `style/index` passes its sections as `anchors:`.

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
