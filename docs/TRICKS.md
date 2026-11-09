# Tricks

<!-- Generated from config/studio_tricks.yml by bin/tricks-doc. Edit the YAML, then run it. -->

The names of the specimens on `/admin/style`. Say the name and an agent writes the
token: "add a Sheen" means `.sheen` on a `.btn`; "make it Sheen · loop" adds
`.sheen--loop`.

A name is one or two Title-case words. A variant is the name, a middle dot and a
lower-case word (`Border Glow · clear`). Every name is unique across the guide.

## Buttons

| Name | Write | What it does |
|------|-------|--------------|
| **Button** | `.btn .btn-primary (or -secondary, -success, -danger, -warning, -neutral, -outline, -google)` | A button: .btn plus one role. |
| Button · size | `.btn-sm / .btn-lg` | Smaller or larger; the default size needs no class. |

## Button tricks

| Name | Write | What it does |
|------|-------|--------------|
| **Edge Glow** | `.edge-rotate-glow` | Adds a glow that rotates around the button's edge. |
| Edge Glow · two-color | `--edge-rotate-glow-color / --edge-rotate-glow-color-b` | Two colors chase each other round the ring. |
| **Border Glow** | `.studio-border-glow` | Adds a moving rainbow border with a soft halo. |
| Border Glow · clear | `.studio-border-glow--clear` | The same ring and halo on a clear button. |
| **Sheen** | `.sheen` | Adds a band of light that sweeps across the button. |
| Sheen · loop | `.sheen--loop` | Repeats the sweep. |
| **Pulse** | `.pulse-cta` | Adds a slow beat with a ring that spreads from the edge. |
| Pulse · color | `--pulse-cta-color (and --pulse-cta-speed, --pulse-cta-scale)` | Sets the ring's color, speed and size. |
| **Fizz** | `render layout: "studio/fizz" around the button` | Adds bubbles that rise from behind the button. |
| Fizz · colors | `colors: [...]` | Picks the bubbles' colors. |
| **Hold** | `render "studio/hold_button"` | Makes the button confirm only after a two-second hold. |
| Hold · recolor | `--hold-* on a parent` | Recolors a hold button from any parent element. |
| **Burst** | `window.studioConfetti.burst(el)` | Fires confetti out from behind the button. |
| Burst · cannons | `window.studioConfetti.cannons()` | Fires confetti in from both sides of the screen. |

## Page header

| Name | Write | What it does |
|------|-------|--------------|
| **Page Header** | `render "studio/page_header"` | Crumbs above the title, tabs on the right, links under it. |
| Page Header · stuck | `[data-stuck]` | How it looks once pinned under the navbar. |
| Page Header · controls | `tabs: or anchors:, menu:, action:, tools_html:` | Tabs or anchors, a Links menu, one action, then tools, at one height. |

## Section header

| Name | Write | What it does |
|------|-------|--------------|
| **Section Header** | `render "studio/section_header"` | A section's title that sticks until the next one takes its place. |
| Section Header · stuck | `[data-stuck]` | How it looks once pinned under the page row. |

## Carousel

| Name | Write | What it does |
|------|-------|--------------|
| **Carousel** | `render layout: "studio/carousel"` | Shows a set too long to grid, a few slides at a time. |
| **Spotlight Carousel** | `render layout: "studio/carousel", style: :spotlight` | Centres one slide with its caption; its neighbours shrink and fade. |
| **Cascade Carousel** | `render layout: "studio/carousel", style: :cascade` | A 3D stack: the open slide in front, the others stepping back either side. |

## Surfaces, text & form

| Name | Write | What it does |
|------|-------|--------------|
| **Card** | `.card` | The standard surface. |
| Card · hover | `.card-hover` | A card that lifts under the pointer. |
| **Badge** | `.badge` | A small outlined pill; set its color and border-color for a status. |
| **Input** | `.input-field` | The text field. |
| **Label** | `.label-upper` | Small upper-case text above a group. |
| **Empty State** | `.empty-state` | The box a list shows when it has nothing in it. |

## Glass

| Name | Write | What it does |
|------|-------|--------------|
| **Glass** | `config.surface_style = :glass` | Frosts the cards and lights the controls from above; opt-in per app. |
| Glass · lit | `.btn, .badge, .input-field under surface_style = :glass` | Buttons, badges and inputs lit from above, in every state. |
| **Glass Sidebar** | `config.sidebar_style = :glass` | A frosted link sidebar; opt-in per app. |
| **Icon** | `studio_icon("rocket", size: 22)` | A line icon by name. |

## Tints & shades

| Name | Write | What it does |
|------|-------|--------------|
| **Scrim** | `.scrim` | Theme-aware: a tint in light mode, a shade in dark. |
| Scrim · soft | `.scrim .scrim-soft` | A lighter wash: more of the media shows. |
| Scrim · strong | `.scrim .scrim-strong` | A heavier wash, for long or small text. |
| **Tint** | `.scrim-tint .scrim` | Forced tint, in either theme. Dark ink. |
| **Shade** | `.scrim-shade .scrim` | Forced shade, in either theme. Light ink. |

## Time stamps

| Name | Write | What it does |
|------|-------|--------------|
| **Time Stamp** | `at_time_tag(time)` | When it happened, on the reader's clock; the date joins only when not today. |
| Time Stamp · bare | `at_time_tag(time, prefix: nil)` | A bare clock, for a cell that already says at. |
| Time Stamp · abroad | `added in the browser, outside the US` | Outside the US a flag trails the clock; inside, nothing. |

## Branded loader

| Name | Write | What it does |
|------|-------|--------------|
| **Loader** | `studio_loader` | This app's icon in its theme colors. |
| Loader · breathe | `config.loader = :breathe` | The icon breathes in and out. |
| Loader · liquid | `config.loader = :liquid` | The icon fills like a glass. |
| Loader · orbit | `config.loader = :orbit` | A dot circles the icon. |
| Loader · steel | `config.loader = :steel` | A light sweeps across the icon. |
| Loader · weld bead | `config.loader = { style: :weld_bead, art: "/brand/loader-weld_bead.svg" }` | A signature style: needs this app's own art file. |
| Loader · sparkle | `config.loader = { style: :sparkle, art: "/brand/loader-sparkle.svg" }` | A signature style: needs this app's own art file. |

## Loaders

| Name | Write | What it does |
|------|-------|--------------|
| **Spinner** | `studio_loader style: :spinner` | A small ring for a short wait beside text or in a control. |
| Spinner · css | `.spinner (--spinner-size, --spinner-color)` | The bare ring, tuned inline. |
| **Skeleton** | `studio_skeleton :lines (or :avatar, :card, :media)` | Grey shapes of the content to come, so the page keeps its layout. |
| **Progress Bar** | `studio_loader style: :bar, percent: 62` | A bar for a wait you can measure; with no percent it sweeps. |
| Progress Bar · css | `.progress-meter (--progress)` | The bare bar, with its label inked both sides of the fill. |
| **Typing Dots** | `studio_loader style: :dots` | Three dots for a reply on its way, such as a chat answer. |
| Typing Dots · css | `.loading-dots with 3 span children` | The bare dots, tuned inline. |
| **Busy Button** | `studio_loader_pending inside the .btn` | The button keeps its place and shows that it is working. |
| **Overlay** | `window.StudioLoader.show("Caption") / .hide()` | The branded full-screen loader, for a page that takes longer than 350ms. |
| **Pull Refresh** | `studio_pull_to_refresh` | On a phone, pull down from the top of the page to reload it. |
| **Infinite Scroll** | `studio_infinite_scroll id:, page:, next_url:` | The next page loads as the list's end comes near. |

## Motion primitives

| Name | Write | What it does |
|------|-------|--------------|
| **Ping** | `.ping .ping--dot` | A dot with a ring that pings out from it. |
| **Edge Fade** | `.fade-edge-y (or -t, -b, -l, -r, -x)` | Fades a scroller's content out at its edges. |

## Effects

| Name | Write | What it does |
|------|-------|--------------|
| **Gradient Text** | `.text-gradient` | Fills the text with a gradient. |
| **Glow** | `.studio-glow` | A soft colored halo around the element. |
| Glow · pulse | `.studio-glow--pulse` | The halo breathes. |
| **Frost** | `.surface-glass` | A frosted panel over whatever is behind it. |
| **Conic Wash** | `.conic-surface` | A slow rotating gradient behind the content. |

## Leveling

| Name | Write | What it does |
|------|-------|--------------|
| **Level Badge** | `.level-badge .level-badge-1 … .level-badge-10` | The ten level pills, plainest to holographic. |
| **Level Pop** | `.level-up-pop` | Pops a level badge with a glow when it changes. |

## Site footer and booking

| Name | Write | What it does |
|------|-------|--------------|
| **Site Footer** | `studio_site_footer` | The public footer, in one line at the end of the layout body. |
| **Booking Link** | `studio_booking_link "Schedule a call"` | Opens the booking calendar in a popup. |
| **Booking Frame** | `studio_booking_frame` | The booking calendar on a page, whole at rest. |
| Booking Frame · cropped | `config.booking_crop = { top:, bottom:, frame_height: }` | Cropped to the slot picker at rest; bin/booking-crop-measure prints yours. |

## Pages

| Name | Write | What it does |
|------|-------|--------------|
| **Not Found** | `config.exceptions_app = Studio::ExceptionsApp.new` | A lost visitor's 404 page, with the app's brand and a button home. |

## Tasks

| Name | Write | What it does |
|------|-------|--------------|
| **Board** | `render "studio/board/board", columns:, card_partial:` | Columns of cards to drag between; a move saves itself. |
