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
is not preloaded. The CSS bundle grows by rules that no page can match.

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
| Arriving at a page whose layout has no metas | The plain swap, with no pause |
| Leaving a page whose layout has no metas | The plain swap. An image on the new page can pause it, up to the cap |

**A black backdrop gives the shading:** a page at opacity 0.3 darkens as it moves. In a
light theme the page goes grey as it moves, and an unfold shows black wedges at its edges.
That is a stronger contrast than in a dark theme, and it is the ruled look.

## What holds still

The navbar (`vt-pinned-header`, the group it has always been) and the banner stack
(`.studio-bar-stack`) hold still while the page moves. The stack's name goes on the first
stack in the page, through a `data-vt-held` mark, so a page that renders two stacks has
one name. A duplicate name silently cancels the whole transition. The name lasts for the
visit: from `turbo:visit` to `turbo:load`. At rest the stack has no name, because a name
makes it a stacking context, and its tooltip then paints under the navbar.

## Images and fonts

Before the swap, the render pauses while the incoming page's eager images load and decode
(at most 12), with the fonts. The cap is 500ms, so a slow image never holds a click, and a
failed image does not hold it at all. A `loading="lazy"` image does not count.

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

## What each host changes on adoption

Each sets `config.page_transition_direction`. Beyond that:

| Host | Also |
|---|---|
| McRitchie Studio (hub) | Mark `agent_chats/_header` (2), `_shell`, `_form`, `build/_launch` (2) and `build/_first_form` with `data-vt-morph` |
| Turf Monster | No inline names to mark. Run `e2e/cart_survives_turbo_restore.spec.js` with motion on: the pause widens the window for a Back press inside a render |
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
`e2e/page_transitions.spec.js` on `/lab/page_transitions` (what a browser plays).
