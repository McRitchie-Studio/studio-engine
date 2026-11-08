# App-to-app page transitions

Each app moves its pages one way, in one style. Inside an app every page change plays the
same move, on every route, in both directions of travel. Nothing is drawn at random. Alex
McRitchie's rulings: 2026-11-03, "There should be consistency with each app but a difference
between each app." 2026-11-04, replacing the random draw of the day before: "The random should
be standard across the app." Code: `Studio.page_transition_direction` and
`Studio.page_transition_style` (`lib/studio.rb`), `app/javascript/studio/page_transitions.js`,
and the "App-to-app page transitions" block in `engine.css`. The effects are from the Codrops
Page Transitions demo (700ms, ease, perspective 1200px). The keyframes were written fresh.

## Turn it on

In `config/initializers/studio.rb`:

```ruby
config.page_transition_direction = :left   # :left, :right, :top or :bottom. Default nil.
config.page_transition_style = :slide      # :slide or :unfold. Default :slide.
```

The direction is the one switch. A set direction also turns smooth-load on, whatever
`Studio.smooth_load` says: the view-transition and no-preview metas render, and the
engine navbar pins itself. An unknown direction or style raises at boot.

**The default style is `:slide`.** It is the plainer of the two, so an app that sets only a
direction gets one steady move. A missing setting never means a draw. The style does nothing
without a direction.

With no direction, an app keeps the engine's fade. Apart from the loader's template in the head
(docs/LOADER.md), the HTML is the same bytes, with one exception every new engine module shares: the import map lists
`studio/page_transitions`. The browser never fetches it, since no tag imports it and it
is not preloaded. The CSS bundle grows by rules that no page can match. The full-load sheet
and script (below) are two more files in a host's assets. No page links them, so no browser
fetches them, and neither one adds an import map entry.

**The cost of smooth-load.** `no-preview` holds the old page until the fresh response
arrives. An app with multi-second pages should fix those first. See
`config.smooth_load` in [`NEW_APP_SETUP.md`](NEW_APP_SETUP.md).

## What plays

| Direction | The page leaves | `:slide` plays | `:unfold` plays |
|---|---|---|---|
| `:left` | to the left | `slide-left` | `unfold-right` |
| `:right` | to the right | `slide-right` | `unfold-left` |
| `:top` | upward | `slide-top` | `unfold-bottom` |
| `:bottom` | downward | `slide-bottom` | `unfold-top` |

The last two columns are the `data-page-transition` values on `<html>`. An unfold is named for
the way the new page turns, so `:unfold` with `:right` plays `unfold-left`. Set the two
settings, never the value. Nothing remembers the route. Back plays the move the other way
(below), Forward plays the app's own, and Turbo restores the scroll position.

## Back

Alex McRitchie's ruling of 2026-11-05: each app has a standard direction and a back direction.
A Back plays the app's move with the direction reversed, in the same style. `:left` and
`:right` swap, and so do `:top` and `:bottom`. So a `:left` slide goes back as `slide-right`,
and `:unfold` with `:right` goes back as `unfold-right`.

| The visit | Way |
|---|---|
| Browser Back, a Turbo restore that Turbo marks `data-turbo-visit-direction="back"` | Back |
| Browser Forward, a restore marked `forward` | The app's own |
| A click on a link with `data-page-transition-back`, to that link's address | Back |
| Browser Back by a full load: the `pageswap` activation traverses to an earlier entry | Back |
| A full load from a link with `data-page-transition-back`, to its address | Back |
| A redirect | The first half's way; Turbo's replace to the final address draws nothing |
| Anything else | The app's own |

`studio/_page_header` puts `data-page-transition-back` on every ancestor crumb and on the
phone's parent link ([`PAGE_HEADER.md`](PAGE_HEADER.md#crumbs)). A host can put it on any
link that leads back up a page's trail. The mark is matched by address and lasts one visit,
so a modifier click or a cancelled visit cannot turn a later visit around.

Every other rule holds: a same-path visit plays nothing, a shared morph name plays the fade,
and reduced motion plays nothing. The theme toggle is untouched.

| The visit | What plays |
|---|---|
| A change of path, Forward included | The direction |
| Back, or a back link (see [Back](#back)) | The direction reversed |
| The same path: a refresh, a poll, a change of query only, with no morph name shared | Nothing |
| A link to a `#fragment` on this page, or Back and Forward between such entries | No visit at all: a scroll by `studio/in_page_links` ([`PAGE_HEADER.md`](PAGE_HEADER.md#in-page-links)) |
| The same path, an advance visit, with a morph name on both sides | The engine's fade and the morph |
| A GET that redirects | The direction once, for the first render. The follow-up visit draws nothing |
| Two pages that share a morph name | The engine's fade and the morph |
| Reduced motion, or a browser without view transitions | The plain swap, with no image pause. A loader that showed still keeps its minimum (docs/LOADER.md) |
| Arriving at a page whose layout has no metas | The plain swap, with no pause. By a full load, the plain load |
| Leaving a page whose layout has no metas | The plain swap. An image on the new page can pause it, up to the cap. By a full load, the plain load |
| A full load to another path: a link with `data-turbo="false"`, `location.assign`, a form that posts natively, a redirect, a Turbo visit answered by `turbo-visit-control: reload` | The direction, once. See [Full page loads](#full-page-loads) |
| A full load to the same path | Nothing |
| Reload, or a URL typed in the address bar | Nothing. The browser offers no transition |
| A theme toggle | No page transition. One 160ms crossfade of the whole page (`data-theme-flip`, `studio/alpine_stores`). During a visit, or with reduced motion or no view transitions, the theme flips at once and the visit's motion plays on |

**The app's page color sits behind the move** (`--color-page`, so it follows the theme). Each
page stays opaque as it slides, so a blank area reads as the page, in light and in dark. Any
gap shows the page color: the corners an unfold opens, a seam between the two pages, a scrollbar
gutter. In the 1280px frames of the hub and Turf, in both themes, no pixel of the page area at
the right edge was black. The black backdrop and the 0.3 opacity of 2026-11-03 are gone: they
darkened blank areas, and left a dark strip beside a full-width hero. Only the new page in an
unfold still fades, from 0 while it is edge-on.

## Full page loads

A page under a strict Content-Security-Policy must stay its own document, because a browser
applies a new policy only on a real load. So a Turbo view transition cannot reach it. These
loads play the same move through the browser's cross-document view transition. They use the
same settings, the same keyframes and the same 700ms.

**The new document draws the motion, so the old one only plans it.**

1. `studio/page_transition_full_load.css` carries `@view-transition { navigation: auto }`,
   inside `@media (prefers-reduced-motion: no-preference)`. This at-rule takes no selector, so
   it cannot sit in `engine.css`: there it would act on every host. Only a page with a
   direction links the file. Both documents must have it.
2. `pageswap`, on the old page: `studio/page_transitions` reads the style with `planVisit`, the
   rule a Turbo visit uses. It writes the style to `sessionStorage`, names the held stack and
   hides the page-load overlay, and the browser then takes the old picture.
3. `pagereveal`, on the new page: `studio/page_transition_reveal` reads the style, sets
   `data-page-transition`, and names the stack. The browser then takes the new picture and
   `engine.css` plays the motion. When it ends, the script removes the marks.

**Why a classic script.** `pagereveal` fires before the first render, and a listener bound
after that misses it. A module is deferred, so it can be too late. `blocking="render"` on a
module would make the first render wait for every module ahead of it. The script holds no
table of styles, so the module stays the one source. It is a named file, because a file is
cached, tested under node, and adds no inline script to the engine's register. It also carries
the request's nonce, and a strict policy with `'self'` accepts it either way.

**Names.** The stack has its name only during the motion, on both pages. The two pages cannot
share a morph: the old page takes its picture before it can read the new page's names. So on
a full load every `data-vt-morph` name is off, and the direction plays. A host's inline name
with no marker still floats over the moving page, as on a Turbo visit.

**Turbo.** A plain visit stays in one document, so no full-load event fires. Turbo opens its
view transition before it reads `turbo-visit-control`, and a response it will not render
(`turbo-visit-control: reload`, or a changed `data-turbo-track="reload"` asset) is then answered
by a full load, which can skip that transition while its `ready` promise is pending. Turbo
awaits only `finished`, so the skip was an unhandled "Transition was skipped" error.
`studio/reload_visits` asks Turbo's own `PageRenderer` about each response at
`turbo:before-fetch-response` and, for one Turbo will not render, takes the view-transition meta
out of the HTML Turbo parses. So Turbo opens no transition, and the full load plays the one
motion. As a fallback, `data-page-transition="still"` stands from `turbo:visit` until
`turbo:before-render`, so a transition that still opens draws nothing.

**What a full load does in Chrome.**

| Action | What plays |
|---|---|
| Reload | Nothing (`viewTransition` is null on both sides) |
| Back, the page loads fresh | The direction reversed, and the scroll position returns |
| Forward, the page loads fresh | The direction |
| Back or Forward, the page returns from the back/forward cache | As above. `pagereveal` fires on the restored page, and the script first removes what it wore when it left |
| Reduced motion | Nothing |
| The old page's module has not run yet (a very fast click) | The plain load, not the browser's own fade |
| A browser without cross-document view transitions | The plain load. Nothing throws |

**A slow page.** The old page stays live until the response commits. After that the browser
holds its last frame until the new page's first render, as it does for any load.

The first render waits for the end of parsing, through `<link rel="expect" blocking="render">`,
and only on a planned arrival: a render of half a body has no navbar or stack to hold still. The
browser sets no limit on this hold, so the script removes the link after 3 seconds. A body slower
than that paints at 3 seconds, and the motion plays with the page as far as it has arrived.
The navbar and the stack hold still only if they have arrived by then. One that arrives during the
motion moves with the new page until the motion ends. One that arrives after it appears in place,
as on a plain load.

The browser has its own limit on the transition, and it does not release the hold. In Chromium
151, with no cap, a page that held for 3 seconds played, and one that held for 4.5 seconds loaded
with no motion. A hold with no cap reached 15 seconds to first paint on a 15-second body. The cap
sits inside that limit.

Chromium prints one console warning for that link on each arrival ("Did not find element expected
to be parsed"). It is expected: no element has that id, so the hold lasts to the end of parsing.

**Images do not wait across a full load.** The 500ms image cap in [Images and fonts](#images-and-fonts)
applies only to a Turbo visit. There, the script holds the swap and loads the images from the
response it already has. A browser gives a page no way to hold its first render for images it
has not parsed, so on a full load an image that is not ready loads in during the motion.

**The policy.** The script and the sheet add no source to a host's policy. The sheet needs
`style-src 'self'`. The script takes the request's nonce and matches `'self'` as well. Nothing
copies a nonce from one document to another, and nothing here makes a Turbo visit run a script.

## What holds still

The navbar (`vt-pinned-header`, the group it has always been) and the banner stack
(`.studio-bar-stack`) hold still while the page moves. The stack's name goes on the first
stack in the page, through a `data-vt-held` mark, so a page that renders two stacks has
one name. A duplicate name silently cancels the whole transition. The name lasts for the
visit: from `turbo:visit` to `turbo:load`. At rest the stack has no name, because a name
makes it a stacking context, and its tooltip then paints under the navbar.

When the old navbar is taller than the new one, as on Back to a scrolled page, only the new one
draws. On a visit that plays a style, the rule hides the old navbar's picture. A shared-name visit
plays the engine's fade and keeps its old behaviour there.

## Images and fonts

Before the swap, the render pauses while the incoming page's eager images load and decode
(at most 12), with the fonts. The cap is 500ms, so a slow image never holds a click, and a
failed image does not hold it at all. A `loading="lazy"` image does not count.

A full load cannot wait for images. See [Full page loads](#full-page-loads).

## Named elements: `data-vt-morph`

A named element on one of the two pages moves with the page. Two pages that share a name
play no style, so the element morphs between them. The engine knows a name by its marker,
never by reading style text:

```erb
<div style="view-transition-name: agent-portrait;" data-vt-morph="agent-portrait">
```

The value is the name. The engine's `agent_chat` portrait and composer carry it, only with
a direction set, so an app without one renders the bytes it always did. **A host that sets
a direction must mark its own inline names**, or those elements float still over the moving
page. Without a direction the marker does nothing, so a host can mark ahead.
The studio-header name and any class-named element that should stay still need no marker.

The browser takes the old page's picture before `turbo:before-render` fires, so the
decision is made ahead of it. The script reads the marks from the response, and from a
remembered list for a page in Turbo's cache. Turbo reads the response through the script's
own read, so it cannot start the transition before the marks are known, however slow the
device. A response the script cannot parse morphs nothing and still renders.

An advance visit to the page's own path counts as two pages: a launch panel can give way to
the chat at the same address, and the portrait they share morphs. A replace is a refresh,
so the same names on the same path play nothing.

## What a host should know

- **`turbo:load` waits for the transition.** Turbo fires it when the view transition ends,
  so about 700ms after the swap and not 220ms. `turbo:render` and Stimulus `connect` come
  at the swap. Move a `turbo:load` listener that must run sooner.
- **Clicks during the motion do nothing.** The browser's transition overlay takes them for
  the 700ms, in Chromium, and `pointer-events: none` on it does not help (measured).
- **A second pause on `turbo:before-render`.** Turbo's `resume` starts the render at its
  first call, so this script binds in capture and gives later listeners a `resume` that
  does nothing. Their hold ends with this one. A hold longer than the cap is cut short.
- **A forked navbar** pins itself by hand: put `vt-pinned-header` on the sticky header,
  exactly once per page. The engine navbar does this itself.
- **A host's own `::view-transition-*(root)` rule** loses to these on specificity, so it
  can stay. It still applies to the engine's fade on a shared-name visit.

## Known limits

- A GET to the current path that redirects away plays nothing on either render: the first is
  a same-path visit, and the second is the redirect's own replace.

## What each host changes on adoption

Each sets `config.page_transition_direction`, and `config.page_transition_style` if it wants
the unfold. A host whose app PR lands before its engine bump guards the style:
`config.page_transition_style = :unfold if config.respond_to?(:page_transition_style=)`. The gem
ships later, so the app keeps booting, and the setting takes effect on the relock. Beyond that:

| Host | Also |
|---|---|
| McRitchie Studio (hub) | Mark `agent_chats/_header` (2), `_shell`, `_form`, `build/_launch` (2) and `build/_first_form` with `data-vt-morph` |
| Turf Monster | No inline names to mark. Run `e2e/cart_survives_turbo_restore.spec.js` with motion on: the pause widens the window for a Back press inside a render. Its signing pages play by a full load with nothing further: `style-src` has `'self'`, and the script takes the nonce. Run its signing specs with `signing_csp_enforced` on |
| moms-app | Its forked navbar has no pin. Add `vt-pinned-header`, once per page |
| McRitchie Industries | It is on engine 0.122.0, below 0.124.0, where the setter first exists. So it needs the engine bump first (its pin is `~> 0.118`). Then `config.page_transition_direction = :top` and no style line. `smooth_load` is on, its navbar is the engine's, its body is `bg-page`, and it has no inline names to mark |
| Commercial Welding | Its wrapper has `data-studio-bar-stack` and no `.studio-bar-stack`, so its utility bar moves with the page. Add the class to the wrapper. Its forked navbar is pinned already |
| alex-build, Voicebox, Cyvasse | Nothing further. Check that pages answer fast, because of `no-preview` |
| Rantly | Its layout has its own head, not `layouts/studio/_head`, so a direction does nothing there |

## Proposed assignment

A proposal for Alex McRitchie to change, not a ruling.

| App | Direction | Style | State |
|---|---|---|---|
| McRitchie Studio (hub) | `:left` | `:slide` | Set by task `hub-sets-transition-style` |
| Turf Monster | `:right` | `:unfold` | Set by task `turf-sets-transition-flip`. The flip suits a game |
| McRitchie Industries | `:top` | `:slide` | Not adopted. See the table above |
| alex-build | `:right` | `:slide` | Not adopted |
| Cyvasse, moms-app | `:top` | `:slide` | Not adopted |
| Commercial Welding, Voicebox | `:bottom` | `:slide` | Not adopted |

## Tests

`test/javascript/page_transitions.test.mjs` (the pure half, and that neither script draws at random),
`test/views/smooth_load_convention_test.rb` and
`test/integration/page_transition_direction_test.rb` (the setting and its bytes),
`e2e/page_transitions.spec.js` on `/lab/page_transitions` (what a browser plays), and
`e2e/page_transitions_full_load.spec.js` for a full load under an enforced strict policy.
Playwright cannot drive the back/forward cache: its flag turns the cache off, and without the
flag its calls hang on the restored page. The restored page's cleanup is a unit test here, and
the behaviour was measured twice by hand in Chromium 151, with no debugger attached.
