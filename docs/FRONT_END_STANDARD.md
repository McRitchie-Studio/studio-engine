# Front-end standard

One way to build the front end of every app on this engine: the hub, Turf
Monster, Cyvasse, McRitchie Industries and every new app. Each section gives the
rule, what the code does today, and how existing code reaches the rule. New work
follows the rule from its first commit.

## A page

A page is a layout, the engine shell, and components. The shell is the navbar
(`layouts/_navbar`), the user nav (`components/_user_nav`), the auth card, the
toast host (`layouts/studio/_flash`) and the footer (`studio/site_footer`). A
page view composes components and passes them data; it draws no chrome of its
own, holds no script, and picks no colour.

## Components

**Rule.** A shared component is a ViewComponent class in the engine,
`app/components/studio/<name>_component.rb` with its template beside it. Its
keyword initializer is its interface: every input is named, required inputs
have no default, and nothing reaches it through `local_assigns`, instance
variables or globals. Each component has a unit test (`render_inline`, then
assertions on the markup the interface promises) and a Lookbook preview for
every state it can show. `/admin/style` is the gallery, and it renders those
previews, so the gallery cannot drift from the component. A component used by
one app lives in that app's `app/components` under the same rules and moves to
the engine when a second app needs it.

**Today.** Components are ERB partials: 17 in `app/views/components/`, more
under `app/views/studio/` (the board, the hold button, modals, banners). Each
documents its locals in a header comment; 14 of the engine's 144 partials
declare strict locals. View tests in `test/views` render partials, and
`/admin/style` frames hand-written specimens with `style/_specimen`. ViewComponent
and Lookbook are not dependencies of the engine yet; piece 4b of the
platform-audit-refactors epic adds them.

**Until 4b lands**, a new or edited partial takes the shape a component will:

- It declares strict locals on its first line:
  `<%# locals: (title:, tone: :neutral, actions: []) -%>`. A render with a
  missing or unknown local raises.
- It has a test in `test/views` that renders it and asserts on its output.
- It has a specimen on `/admin/style`.

**From partial to component.** The strict locals become the initializer's
keywords, the header comment becomes the class comment, the `test/views` test
becomes the component test, and the specimen becomes a preview. The partial
stays for one release as a single `render Studio::NameComponent.new(...)` line,
then goes.

## Behaviour

**Rule.** Behaviour is ES modules pinned by importmap. Each behaviour is one
Stimulus controller, thin glue that reads its `values`, finds its `targets`
and handles its `actions`. Logic lives in a plain module with no DOM access,
and that module has `node:test` unit tests. Cyvasse is the reference: 11
controllers in `app/javascript/controllers`, 27 logic modules in
`app/javascript/cyvasse`, and 31 test files in `test/javascript` that
`bin/test-js` runs with `node --test` and no npm install, through a loader hook
that maps the importmap's specifiers onto the files.

Alpine stays only as the binding layer inside a component's template:
`x-show`, `x-bind`, `x-model` and `x-on` over state the template owns. Logic
that needs a name, a branch or a test is a module.

**Forbidden in new code:**

- an inline `<script>` in ERB, and any script without the CSP nonce;
- a `window.*` factory or global as an API between files;
- JavaScript passed as a string local and evaluated at runtime;
- a multi-line `x-data` object literal in a template.

The nonce rule has a reason: every inline script is what keeps `unsafe_inline`
in an app's `script_src` (Turf Monster's policy carries it today).

**Today.** The engine ships behaviour as scripts inside partials. The board's
Alpine factory, `window.studioBoard`, is 454 lines in `studio/_board_assets`;
the hold button takes `guard:`, `on_success:` and `validate:` as JavaScript
strings that `Alpine.evaluate` runs; the shared head carries inline scripts.
The engine vendors Alpine and loads it with `javascript_include_tag`; it has no
importmap pins and no Stimulus. Every app pins its modules with importmap.
Cyvasse and Industries pin Stimulus; the hub has `stimulus-rails` in its
Gemfile but no Stimulus pin and no controllers, four modules in
`app/javascript`, and 35 inline script tags across 31 views, the largest being
`tasks/_deployments_live_fx` at 772 lines. Turf Monster pins modules and no
Stimulus.

**From script to module.** Move the pure logic into a module first and pin
it with tests (the behaviour does not change). Then write the controller that
calls it, swap the markup to `data-controller`, and delete the script tag.

## Styling

**Rule.** Views use engine tokens only.

- Colour comes from the semantic tokens `Studio::ThemeResolver` emits and
  `tailwind/studio.tailwind.config.js` maps: `page`, `surface`,
  `surface-alt`, `inset`, `primary-50..900`, the text and border ladders, and
  `success`, `warning`, `danger` with their `-ink` and `-fill` variants. In CSS,
  `var(--color-*)`; for alpha, `rgb(var(--color-primary-rgb) / 0.4)`.
- Status colour (a stage, a grade, a run result) comes from one status tone
  helper, `status_tone(:success)` and its siblings, never from hand-picked
  classes. Piece 4g builds it.
- Buttons, cards, badges and inputs use the engine utilities in
  `engine.css`: `btn` and its variants, `card`, `badge`, `input-field`,
  `label-upper`, `empty-state`.
- Stacking uses the `--z-*` scale; type uses the Tailwind scale plus
  `text-2xs` and `text-3xs`.

**Forbidden:** a raw hex in a view; a `dark:` variant (the resolver writes
both themes' values into the same tokens, so a token is already right in
both); a palette private to one page; an arbitrary size such as `text-[11px]`;
the fixed brand scales (`mint`, `navy`, `violet`) for surfaces or status.

**Today.** The tokens exist and most engine UI uses them. Engine views still
carry a raw hex in 29 files and `dark:` in 2; hub views carry a hex in 36 and
`dark:` in 24. No shared status helper exists: the hub has several per-feature
tone maps in its helpers (`pipeline_chip_classes`, `merit_reason_classes`,
`release_meter_tone` among them).

## Tests by layer

| Layer | Test | Where |
|-------|------|-------|
| Component | Unit: render, assert on the interface's output | `test/components` (today `test/views`) |
| Component states | Lookbook preview, one per state | `test/components/previews` |
| Logic module | `node:test`, no DOM | `test/javascript` |
| Controller wiring | System or e2e, only where the wiring is the risk | the app's system or e2e lane |
| Page | System or e2e, as the task's shape demands | the app's lane |

The hub's `docs/agents/modules/testing.md` names the tiers each shape requires.

## Migration order

Existing code moves in this order, one task each, highest traffic first:

1. **The hub's task card and deploy board.** `tasks/_task_card` (484 lines)
   renders through three paths; it becomes one component with one
   constructor (piece 4c). The board effects move out of ERB into
   `app/javascript/board/` with Node tests (piece 4d).
2. **The two kanban implementations.** The engine's `window.studioBoard` and
   the hub's `kanbanBoard` in `tasks/_deploy_board` become one board
   component with one controller.
3. **The three toast systems.** The engine's `toast` window event (the
   `_flash` host), the toast list inside `studioBoard`, and the hub board's
   `showToast` become one toast API on the engine host (piece 4e).
4. **The auth card.** The engine ships no sign-in card; each app draws its
   own, four variants in all, with Turf Monster's
   `app/views/modals/_auth.html.erb` as the authority. It becomes one engine
   shell component (piece 4e).
5. **The heartbeat pages' private palette.** `heartbeat/insights` and
   `heartbeat/pipeline` share one dark palette of 11 raw hex values; they
   move to tokens and the status tone helper (piece 4g).

**New work** follows the standard from day one. **Edited code** leaves no
further from it: a partial you touch gains strict locals, and a script you
touch loses its logic to a module.

## What a reviewer checks

- The page composes the shell and components; it draws no chrome of its own.
- Every new or edited component or partial declares its interface, has a unit
  test, and has a preview or specimen.
- No new inline script, nonce-less script, `window.*` API, string-evaluated
  JavaScript or large `x-data` literal.
- No raw hex, `dark:` variant, arbitrary size or hand-picked status colour.
- Logic modules have `node:test` tests, and the app's lane runs them.

## Open questions for Alex

These are recorded on the task `front-end-standard-page` and decided before
piece 4b starts:

1. **ViewComponent and Lookbook as dependencies.** Does ViewComponent
   become a runtime dependency of the gem, since every app renders its
   components? Does Lookbook run only in development and test, or also in production
   behind the admin wall so `/admin/style` serves the previews?
2. **How the engine ships modules.** The engine gains its own importmap pins
   that each app draws in, or each app pins the engine's modules itself.
3. **Alpine's future.** Alpine stays as the binding layer, or retires in
   favour of Stimulus once the migration ends. Alpine's standard build needs
   `unsafe_eval` in `script_src`.
4. **The CSP target.** Once inline scripts are gone, does every app drop
   `unsafe_inline` from `script_src`?
5. **One Node version.** The engine's `package.json` pins Node 20; the hub
   pins 22.
