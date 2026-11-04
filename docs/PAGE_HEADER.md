# The page header and the triple stack

## The rule

A page has three pinned layers, each below the last, and none overlaps another:

1. The navbar (`layouts/_navbar`).
2. The page row (`components/_page_header`): the title, then optional meta and tabs.
3. A table's sticky header (`config.sticky_table_headers`).

An admin page uses `components/_page_header` for its title. It does not draw its
own sticky row, and it does not write a pixel height. Each layer takes its place
from the pinned stack ([`NAVBAR_SETUP.md`](NAVBAR_SETUP.md#reading-the-pinned-stack)).

## Using it

```erb
<div class="max-w-7xl mx-auto px-4 pt-6 pb-8 space-y-6">
  <%= render "components/page_header",
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
the head partial; a table's own `position: sticky` header cells also read
`--pin-stack-bottom`.

At rest the row's bottom edge is part of the stack, so `--pin-stack-bottom` is lower
at the top of the page than once the row has stuck. A sticky reader under the row
sees no difference. A `fixed` reader that must sit right under the navbar reads
`--nav-bottom` instead.

The row is never a `<header>`: the publisher takes the document's first `<header>` as
the navbar.

## Who has adopted it

`style/index`, `studio/admin_models/show`, `studio/admin_surveys/index`,
`studio/geo_settings/edit` and `studio/site_identities/edit`.

These engine pages have not. Each needs more than the row has today:

- `studio/admin_surveys/show`: a back link and a mono subtitle.
- `studio/models/show`: an eyebrow and a mono subtitle.
- `studio/knowledge_docs/_browser`, `_coverage_table` and `show`: a title with a live
  badge, filters that wrap, a subtitle.
- `navbar/show`: a review page for the navbar itself, with its own controls.

Public pages (`studio/bookings/show`, `studio/public_users/show`, `studio/surveys/*`)
and the sign-in pages have no admin chrome, so the rule does not apply to them.
