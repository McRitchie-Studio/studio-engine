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

**Today.** ViewComponent is a runtime dependency of the engine, so every app
has it through the engine and lists it nowhere else. Lookbook, the gallery, is
opt-in by bundle (below). The badge is the first component: `Studio::BadgeComponent`, with its
unit test in `test/components/studio` and its preview in
`app/components/previews/studio`. The rest are still ERB partials, 17 in
`app/views/components/` and more under `app/views/studio/` (the board, the hold
button, modals, banners); each documents its locals in a header comment. View
tests in `test/views` render partials, and `/admin/style` frames hand-written
specimens with `style/_specimen` beside a Components section that lists every
preview.

**The gallery.** Lookbook serves the previews at `/admin/style/components`,
drawn by `Studio.routes` (`Studio::ComponentGallery`):

- Lookbook is not a runtime dependency. Loaded in production it costs each
  process tens of megabytes, and most apps run on 512 MB dynos. The engine never
  requires it; an app that wants the gallery bundles it **after** studio-engine
  (so ViewComponent loads first):
  `gem "lookbook", group: [:development, :test]` for a development gallery, or
  ungrouped plus `Studio.lookbook_in_production = true` for a live one. The hub
  is the one live gallery: it bundles lookbook ungrouped and sets the flag.
- An app without lookbook in its bundle draws no gallery route, serves no
  Lookbook asset, and loads no Lookbook code. A production app without the flag
  draws none of it either, and no app draws ViewComponent's preview routes in
  production.
- The router admits a signed-in admin whose session token is live. Anyone else
  gets 404, not a redirect.
- It shows output only: the rendered preview and its HTML. The Source and Params
  panels, embeds and pages are off, and previews declare no `@param` tags.
- Previews live in `app/components/previews` (their own autoload root, so the
  badge's preview is `Studio::BadgeComponentPreview`) and render in the
  `studio/component_preview` layout, which carries the host's stylesheets.

**Tailwind.** A component keeps its class strings in Ruby, and each host's
Tailwind config scans only the engine's `app/views`. `engine.css` adds
`@source "../../../components"`, so every host that imports it compiles the
engine's component classes with no edit of its own.

**Until a partial is converted**, a new or edited partial takes the shape a
component will:

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

## A primitive's public surface

A shared primitive's public surface is three things:

- its component inputs (the initializer's keywords and the values each takes);
- its `data-*` hooks (`data-board-count` on the badge, for one);
- its named CSS classes (`badge`, `card`, `btn` and their variants).

Everything else is internal and may change in any release: the template's
structure, its wrapper elements, its utility classes. A consumer that selects
on an internal (a nested `span`, a utility class) is relying on something no
release promises.

A change to the public surface is a breaking change. It gets a **Breaking**
line in the changelog naming the input, hook or class, and a consumer-CI run
(`.github/workflows/consumer-ci.yml`) against every consumer before the gem is
published. The badge's public surface is written in its class comment.

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

**The engine's modules.** The engine pins its own ES modules, and a host draws
them with no edit: the engine's `config/importmap.rb` pins each module under
`app/javascript/studio` as `studio/<name>`, and the `studio.importmap`
initializer adds that file to importmap-rails' maps before the host's own, so a
host that pins the same name wins. A module's logical asset path shares the
`studio/` prefix with the classic scripts in `app/assets/javascripts/studio`, so
it may not reuse one of their names. `studio/local_path`, the browser twin of
`Studio::LocalPath.local?`, is held to the Ruby rule by
`test/lib/studio/local_path_js_parity_test.rb`, which also runs every
`node:test` file in `test/javascript` in the engine suite.

**The engine's boot.** `layouts/studio/_head` imports `studio/application` on
every page with `javascript_import_module_tag`, which carries the request's CSP
nonce. The engine runs its own Stimulus application (`studio/stimulus`) on its
own attributes (`data-studio-controller`, `data-studio-action`,
`data-studio-target`), so a host's Stimulus application, and its lazy loader,
never sees an engine controller. Stimulus
is vendored (`studio/vendor/stimulus.js`, pinned as `@hotwired/stimulus`); a
host that pins its own wins. The boot graph, every `studio/` module
`studio/application` imports, is preloaded
(`Studio::Engine.javascript_boot_graph`); every other engine pin is fetched
only when something imports it.

**Two ways a controller registers.** A controller on every page (nav collapse,
modal host, toast, link sidebar) is imported statically by `studio/application`,
which puts it in the preloaded boot graph. The hold button is imported
statically too, by `studio/stimulus`: it confirms real actions, so it arrives
with the page and no later request stands between a press and its hold. A
page-specific controller (the board) is listed in `LAZY` in `studio/stimulus` as
a dynamic import, and `studio/lazy_controllers` registers it the first time an
element names it, so a page with no such element never fetches it. Until a lazy
controller registers, its element's actions do nothing.

**A page's own module tag.** A page that must find its controller connected
the moment it has loaded registers it from its own nonced module tag: the style
guide's Modals section imports `studio/style_guide`, which registers
`style-modals` on the engine's application. The tag runs with the page, in
document order, so only that page fetches the module and nothing waits on a
dynamic import. The sign-in interstitial, a document with no layout and no
import map, loads `studio/confirm_interstitial` the same way, by its asset path.

**A lazy load that fails is final for the document.** A browser keeps a failed
module fetch and rejects every later `import()` of it without a new request,
across DOM changes and Turbo visits; only a full page load fetches it again. So
`studio/lazy_controllers` imports a controller once, reports a failure once, and
marks every element that names the failed controller, on the page and arriving
later, with `data-studio-controller-failed="<identifier>"`. A lazy controller's
page styles or announces that state: a board whose controller failed shows
"This board could not load its controls. Reload the page." above its cards,
which stay readable. A control that must work whenever its page does is not
lazy.

**An Alpine factory cannot be lazy.** Alpine evaluates an `x-data` as it meets
the element: at start for a page's own markup (`x-data="studioBoard(...)"`, and
a host reads the scope's methods in its own first tick), at mount for a modal
card (`x-data="birthdayModal(...)"`). A factory that is not defined by then
leaves the element dead, and no dynamic import can promise to have resolved. So
a factory a consumer still binds is a module imported statically, in the
preloaded boot graph:

- `studioBoard` and `levelingActionModal` are imported by `studio/alpine_shims`.
  What is lazy is the controller beside the board and the library it loads:
  only a page with a board fetches the board controller and SortableJS (the
  `sortablejs` pin). `window.Sortable` is a shim until then, whose `create`
  loads the library first.
- The photo crop, the upload hosts, the birthday card and row and the profile
  form are `studio/alpine_scopes`, which the head also loads by its own module
  tag, so a boot that fails to load keeps a page its photo upload, its birthday
  gate and its profile form.

What a factory needs later (Cropper.js, SortableJS) may arrive late, and the
page says so when it never does: a control never takes a press that does
nothing.

A static module can fail too, and a browser keeps that failure for the life of
the document: one failed request among `studio/alpine_scopes` and the four
modules it imports leaves every factory it publishes undefined. The head
therefore carries a second nonced inline guard beside the hold button's,
`studio/_alpine_scopes_guard`, which imports nothing. Once the page's boot is
over it marks each element whose `x-data` names a missing factory
(`data-studio-scope-failed`), puts "This did not load. Reload the page." first
inside it as a `role="status"` line, shows every `[data-studio-scope-fallback]`
inside it (the profile form's plain Save) and puts the server's values back in
the text fields Alpine emptied, so a form is never left with no way to submit.
A factory added to `studio/alpine_scopes` is added to the guard's list;
`test/javascript/alpine_scopes_guard.test.mjs` holds the two to each other.

**The hold button says so when it cannot work.** It is imported statically, so
the one way it fails is a module request that fails as the page loads. The head
carries an inline, nonced guard (`studio/_hold_button_guard`) that imports
nothing: a `.hold-stack` whose controller has not written
`data-hold-button-connected` once the boot is over is marked
`data-studio-controller-failed="hold-button"`, reads as unavailable, and shows
"This button could not load. Reload the page." A late connect clears it.

Alpine loads after the module tags. Deferred classic scripts and module scripts
run in document order, so by the time Alpine starts, the boot has installed the
Alpine shims (`studio/alpine_shims`): the `window.*` globals and Alpine stores
consumers still bind to, each a thin delegate to the module that owns the
behaviour. A shim stays while a consumer binds to it. The engine's converted
components:

| Behaviour | Module | Bound by | Shim kept for consumers |
|---|---|---|---|
| Navbar collapse | `studio/nav_collapse` | `nav-collapse` | `x-data="navCollapse()"` |
| Pinned stack (`--pin-*`, `--nav-h`, `--nav-bottom`) | `studio/pinned_stack` | the boot | none needed (CSS only) |
| Theme and dev mode | `studio/alpine_stores` | its own module tag, and the boot | `$store.theme`, `$store.devMode` |
| Nav spinner, success confetti | `studio/head_chrome` | the boot | `showNavSpinner`, `hideNavSpinner`, `fireSuccessConfetti` |
| Modal host, scoped host | `studio/modal_host` | `modal-host`, its own module tag | `$store.modals`, each scoped `$store.<name>`, `window.ModalAnimations`, `window.StudioModals` |
| Toast queue (`layouts/studio/_flash`) | `studio/toast` | `toast`, its own module tag | none needed: the API is the `toast` window event; the queue is `$store.toasts` |
| Link sidebar flag | `studio/link_sidebar` | `link-sidebar`, its own module tag | `$store.sidebars.linkTreeOpen` |
| Hold button | `studio/hold_button`, `studio/hold_button_hooks` | `hold-button`, registered by `studio/stimulus` | `window.studioFizzPortal` |
| Board primitive (`studio/board/_board`) | `studio/board` | `board` (lazy), which loads SortableJS | `x-data="studioBoard({...})"`, `window.Sortable.create` until SortableJS loads |
| Leveling activity modals | `studio/leveling_activity` | the Alpine scope alone | `x-data="levelingActionModal({...})"` |
| Crop photo modal (`studio/modals/_crop_photo`) | `studio/cropper` | the Alpine scope, published by `studio/alpine_scopes` | `x-data="cropPhotoModal({...})"` |
| Image upload hosts, avatar cropper | `studio/image_upload` | the Alpine scope, published by `studio/alpine_scopes` | `x-data="imageUploadHost({...})"`, `x-data="avatarCropperHost()"`, `submitFormWithProgress(form, opts)` |
| Birthday card, profile birthday row | `studio/birthday` | the Alpine scope, published by `studio/alpine_scopes` | `x-data="birthdayModal({...})"`, `x-data="studioBirthdayFields('...')"` |
| Profile form | `studio/profile_form` | the Alpine scope, published by `studio/alpine_scopes` | `x-data="studioProfileForm({...})"` |
| Compact identity bar (`studio/profiles/_identity_mini`) | `studio/identity_mini` | `identity-mini`, registered by `studio/application` | none needed |
| Sign-in interstitial (`studio/_confirm_interstitial`) | `studio/confirm_interstitial` | its own module tag; the fallback button by CSS | none needed |
| Style guide modal demos (`style/_modals`) | `studio/style_modals` | `style-modals`, registered by `studio/style_guide` from the section's own module tag; the store by `modal-host` | `$store.dsModals`, `window.dsModalDemos` on the style guide |

The stores load by their own nonced module tag as well as the boot, because
every host's `<body>` binds `$store.devMode`: a boot that fails to load must
not make that binding throw. `studio/alpine_stores` imports nothing, and
registers a store only where Alpine has none of that name. `studio/modal_host`,
`studio/toast` and `studio/link_sidebar` have their own tag for the same
reason, and so does `studio/stimulus`, whose only imports are Stimulus,
`studio/lazy_controllers` and the hold button's controller: a failure elsewhere
in the boot's graph leaves a page its hold button. `studio/alpine_scopes` has
its own tag too; its imports are the modules that own a factory, and those
import nothing.

**The hold button's events.** The button dispatches `hold-button:guard`,
`hold-button:start`, `hold-button:validate`, `hold-button:early` and
`hold-button:success`, which bubble; a page answers with `preventDefault()` or
`$event.detail.waitUntil(answer)` (the partial's header lists each). The
events are the whole API: the button takes no JavaScript and
`studio/hold_button_hooks` evaluates none. The `guard:`, `on_hold_start:`,
`validate:`, `early_action:`, `early_action_guard:` and `on_success:` locals
are removed. `studio/_hold_button` raises `ArgumentError` when one is passed
(`Studio::HoldButton`), and a button that carries one of their attributes by
hand (`data-guard`, `data-on-hold-start`, `data-validate`, `data-early-action`,
`data-early-action-guard`, `data-on-success`) refuses every press with a
console error naming the attribute and its event.

**Today.** The shared head carries three inline
scripts, all nonced: the pre-paint theme, the hold button's guard and the
x-data factories' guard; its behaviour is the modules above. The engine
vendors Alpine and loads it with `javascript_include_tag`. Every app pins its
modules with importmap.
Cyvasse and Industries pin Stimulus; the hub has `stimulus-rails` in its
Gemfile but no Stimulus pin and no controllers, four modules in
`app/javascript`, and 35 inline script tags across 31 views, the largest being
`tasks/_deployments_live_fx` at 772 lines. Turf Monster pins modules and no
Stimulus.

**From script to module.** Move the pure logic into a module first and pin
it with tests (the behaviour does not change). Then write the controller that
calls it, swap the markup to `data-controller` (`data-studio-controller` in the
engine), and delete the script tag. In the engine,
`test/views/no_inline_script_test.rb` lists every view that still carries an
inline script, each beside the task that owns it; delete the view's line with
its script.

## Styling

**Rule.** Views use engine tokens only.

- Colour comes from the semantic tokens `Studio::ThemeResolver` emits and
  `tailwind/studio.tailwind.config.js` maps: `page`, `surface`,
  `surface-alt`, `inset`, `primary-50..900`, the text and border ladders, and
  `success`, `warning`, `danger` with their `-ink` and `-fill` variants. In CSS,
  `var(--color-*)`; for alpha, `rgb(var(--color-primary-rgb) / 0.4)`.
- Status colour (a stage, a grade, a run result) comes from one status tone
  helper, `status_tone(:success)` and its siblings, never from hand-picked
  classes. An engine component that shows a status takes `tone:`, one of the
  same five roles (`success`, `warning`, `danger`, `primary`, `muted`), as
  `Studio::BadgeComponent` does.
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
`dark:` in 24. The hub's `StatusToneHelper` maps status words onto the five
roles, and the badge's `tone:` renders the same chip classes. The badge's older
`scheme:` palette, which uses the brand scales, stays for existing callers.

## Tests by layer

| Layer | Test | Where |
|-------|------|-------|
| Component | Unit: render, assert on the interface's output | `test/components` (a partial: `test/views`) |
| Component states | Lookbook preview, one per state | `app/components/previews` |
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
2. **The two kanban implementations.** The engine's board (`studio/board`,
   on its `board` controller) and the hub's `kanbanBoard` in
   `tasks/_deploy_board` become one board component with one controller.
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

## Decisions and open questions

Decided by Alex:

- ViewComponent is a runtime dependency of the engine, and every app takes it
  through the engine.
- Lookbook runs in production on the hub only, behind the admin wall; every
  other app draws it in development and test.
- The engine supplies its modules through its own importmap pins; no app lists
  them.
- The Stimulus migration proceeds, engine behaviour first.

Still open, recorded on the task `front-end-standard-page`:

1. **The CSP target.** Once inline scripts are gone, does every app drop
   `unsafe_inline` from `script_src`?
2. **One Node version.** The engine's `package.json` pins Node 20; the hub
   pins 22.
