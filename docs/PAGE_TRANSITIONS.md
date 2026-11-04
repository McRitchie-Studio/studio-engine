# App-to-app page transitions

Each app moves its pages one way. One app moves left, another moves up. Inside an app
every page change moves the same way, on every route, in both directions of travel. Alex
McRitchie's ruling, 2026-11-03: "There should be consistency with each app but a
difference between each app." Code: `Studio.page_transition_direction` (`lib/studio.rb`),
`app/javascript/studio/page_transitions.js`, and the "App-to-app page transitions" block
in `engine.css`. The effects are from the Codrops Page Transitions demo, at its values
(700ms, ease, opacity 0.3 and 0, perspective 1200px). The keyframes were written fresh.

## Turn it on

In `config/initializers/studio.rb`:

```ruby
config.page_transition_direction = :left   # :left, :right, :top or :bottom. Default nil.
```

This is the one switch. A set direction also turns smooth-load on, whatever
`Studio.smooth_load` says: the view-transition and no-preview metas render, and the
engine navbar pins itself. An unknown direction raises at boot.

With no direction, an app renders as before and keeps the engine's fade. The HTML is the
same bytes, with one exception every new engine module shares: the import map lists
`studio/page_transitions`. The browser never fetches it, since no tag imports it and it
is not preloaded. The CSS bundle grows by rules that no page can match. The full-load sheet
and script (below) are two more files in a host's assets. No page links them, so no browser
fetches them, and neither one adds an import map entry.

**The cost of smooth-load.** `no-preview` holds the old page until the fresh response
arrives. An app with multi-second pages should fix those first. See
`config.smooth_load` in [`NEW_APP_SETUP.md`](NEW_APP_SETUP.md).

## What plays

| Direction | The page leaves | The two styles |
|---|---|---|
| `:left` | to the left | `fade-left`, `unfold-right` |
| `:right` | to the right | `fade-right`, `unfold-left` |
| `:top` | upward | `fade-top`, `unfold-bottom` |
| `:bottom` | downward | `fade-bottom`, `unfold-top` |

Each page change draws one of the app's two styles at random. Nothing remembers the
route. Back and Forward play the same direction, and Turbo restores the scroll position.

| The visit | What plays |
|---|---|
| A change of path, Back or Forward included | The direction |
| The same path: a refresh, a poll, a change of query only, with no morph name shared | Nothing |
| The same path, an advance visit, with a morph name on both sides | The engine's fade and the morph |
| A GET that redirects | The direction once, for the first render. The follow-up visit draws nothing |
| Two pages that share a morph name | The engine's fade and the morph |
| Reduced motion, or a browser without view transitions | The plain swap, with no pause |
| Arriving at a page whose layout has no metas | The plain swap, with no pause. By a full load, the plain load |
| Leaving a page whose layout has no metas | The plain swap. An image on the new page can pause it, up to the cap. By a full load, the plain load |
| A full load to another path: a link with `data-turbo="false"`, `location.assign`, a form that posts natively, a redirect, a Turbo visit answered by `turbo-visit-control: reload` | The direction, once. See [Full page loads](#full-page-loads) |
| A full load to the same path | Nothing |
| Reload, or a URL typed in the address bar | Nothing. The browser offers no transition |

**A black backdrop gives the shading:** a page at opacity 0.3 darkens as it moves. In a
light theme the page goes grey as it moves, and an unfold shows black wedges at its edges.
That is a stronger contrast than in a dark theme, and it is the ruled look.

## Full page loads

A page under a strict Content-Security-Policy must stay its own document, because a browser
applies a new policy only on a real load. So a Turbo view transition cannot reach it. These
loads play the same look through the browser's cross-document view transition. They use the
same pair of styles, the same keyframes and the same 700ms. The switch is the same one.

**The new document draws the motion, so the old one only plans it.**

1. `studio/page_transition_full_load.css` carries `@view-transition { navigation: auto }`,
   inside `@media (prefers-reduced-motion: no-preference)`. This at-rule takes no selector, so
   it cannot sit in `engine.css`: there it would act on every host. Only a page with a
   direction links the file. Both documents must have it.
2. `pageswap`, on the old page: `studio/page_transitions` draws the style with `planVisit`, the
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
view transition before it reads `turbo-visit-control`. So `data-page-transition="still"` stands
from `turbo:visit` until `turbo:before-render`. A response that Turbo will not render draws
nothing, and the full load after it plays the one motion.

**What a full load does in Chrome.**

| Action | What plays |
|---|---|
| Reload | Nothing (`viewTransition` is null on both sides) |
| Back or Forward, the page loads fresh | The direction, and the scroll position returns |
| Back or Forward, the page returns from the back/forward cache | The direction. `pagereveal` fires on the restored page, and the script first removes what it wore when it left |
| Reduced motion | Nothing |
| The old page's module has not run yet (a very fast click) | The plain load, not the browser's own fade |
| A browser without cross-document view transitions | The plain load. Nothing throws |

**A slow page.** The old page stays live until the response commits. After that the browser
holds its last frame until the new page's first render, as it does for any load.

The first render waits for the end of parsing, through `<link rel="expect" blocking="render">`,
and only on a planned arrival: a render of half a body has no navbar or stack to hold still. The
browser sets no limit on this hold, so the script removes the link after 3 seconds. A body slower
than that paints at 3 seconds, and the motion plays with the page as far as it has arrived.

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
remembered list for a page in Turbo's cache. If the response is late, the visit plays the
fade with the element fading across, and no morph.

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

Each sets `config.page_transition_direction`. Beyond that:

| Host | Also |
|---|---|
| McRitchie Studio (hub) | Mark `agent_chats/_header` (2), `_shell`, `_form`, `build/_launch` (2) and `build/_first_form` with `data-vt-morph` |
| Turf Monster | No inline names to mark. Run `e2e/cart_survives_turbo_restore.spec.js` with motion on: the pause widens the window for a Back press inside a render. Its signing pages play by a full load with nothing further: `style-src` has `'self'`, and the script takes the nonce. Run its signing specs with `signing_csp_enforced` on |
| moms-app | Its forked navbar has no pin. Add `vt-pinned-header`, once per page |
| Commercial Welding | Its wrapper has `data-studio-bar-stack` and no `.studio-bar-stack`, so its utility bar moves with the page. Add the class to the wrapper. Its forked navbar is pinned already |
| alex-build, Voicebox, Rantly, Cyvasse, Industries | Nothing further. Check that pages answer fast, because of `no-preview` |

## Proposed assignment

A proposal, not a ruling. No host changes in the engine task; each app sets its direction
after the gem ships.

| Direction | Apps |
|---|---|
| `:left` | McRitchie Studio (hub), McRitchie Industries |
| `:right` | Turf Monster, alex-build |
| `:top` | Cyvasse, moms-app |
| `:bottom` | Commercial Welding, Voicebox |

## Tests

`test/javascript/page_transitions.test.mjs` (the pure half),
`test/views/smooth_load_convention_test.rb` and
`test/integration/page_transition_direction_test.rb` (the setting and its bytes),
`e2e/page_transitions.spec.js` on `/lab/page_transitions` (what a browser plays), and
`e2e/page_transitions_full_load.spec.js` for a full load under an enforced strict policy.
Playwright cannot drive the back/forward cache: its flag turns the cache off, and without the
flag its calls hang on the restored page. The restored page's cleanup is a unit test here, and
the behaviour was measured twice by hand in Chromium 151, with no debugger attached.
