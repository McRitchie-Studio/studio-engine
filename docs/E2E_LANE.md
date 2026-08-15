# The browser lane

The engine runs a real browser against real engine partials. This is what it
covers, what it deliberately does not, and what it costs.

## Why a gem has one

Measured across 40 merged engine feature units, **12 (30%) add an imperative
browser program** — an inline `<script>` or a served `.js` — and **zero have ever
carried browser evidence**. The hub, by comparison, is 8 of 247 (3.2%). The
client-side risk in this ecosystem concentrates here, and until this lane existed
the engine was the one repo with no way to observe it.

Two of the three defects that motivated the ecosystem's browser-evidence gate were
engine-side, and both reached a human:

| Defect | What shipped | What every green tier saw |
|---|---|---|
| `fix-navbar-offset-jump` | The header painted at a server-rendered estimate of the bar stack's height, then moved when a `ResizeObserver` published the real one. | Two markup tests asserting "exactly one pinned header". Both correct. Neither can observe a post-paint move. |
| `propagate-at-format-gem` | An ERB comment terminated early; the leaked prose contained a literal script open tag, which opened a phantom element that swallowed the real script. Dead in every browser, on every page of every host. | `assert_includes html, "__atTimeFmt"` — **green**, because the token survived inside the text the phantom element ate. |

The second one is the whole argument for this lane. The guard written to catch
"stamps without a working script" was itself an instance of the disease it named.

## What it is

| Piece | Path | Role |
|---|---|---|
| Specs | `e2e/*.spec.js` | Drive a real Chromium against the lab pages |
| Lab pages | `test/dummy/app/views/e2e_lab/` | Render **engine partials by name** in a real layout |
| Lab controller | `test/dummy/app/controllers/e2e_lab_controller.rb` | Sets up partial locals; supplies the host's asset delivery |
| Server | `e2e/boot.rb` | Compiles Tailwind, copies the engine's served assets (Alpine among them), boots Puma |
| Config | `playwright.config.js` | One chromium project, `workers: 1`, webServer |
| Contract | `config/e2e_lane.yml` | How many specs the lane must execute |
| Runtime gate | `bin/e2e-executed-set-check` | Reads Playwright's own receipt and asserts the executed set |
| Static guard | `test/lib/e2e_lane_contract_test.rb` | Refuses any edit that could narrow the set |

Run it locally:

```bash
npm ci
npx playwright install chromium
npx playwright test                 # ~4s, boots its own server
npx playwright test --headed        # watch it
```

The lane is **not** in `bin/release-check`. That is deliberate — see *Cost*.

## The invariant that keeps it honest

**A lab page may set up a partial's locals and nothing else.**

The moment a lab page hand-rolls what a partial does — its own sticky header, its
own copy of the re-stamper — the specs start grading the lab, and the lane reports
green over engine code no browser ever touched. That failure would be invisible:
every spec still passes.

`test/lib/e2e_lane_contract_test.rb#test_integration_the_lab_pages_render_engine_partials`
asserts each lab page renders its engine partials by name and carries no `<script>`
of its own.

## Can it actually see the defects it exists for?

Yes, and both were verified by reintroducing the defect and watching the lane go
red. The scripts that do it live in the task record; the traces:

**Defect 1 — the paint-time jump.** With the two-publisher mechanism restored
(the `<style>` estimate, the `ResizeObserver`, and a header whose `top` reads
`var(--studio-bars-h)`), sampling the pinned header's offset once per animation
frame after growing a bar by 80px:

```
header top across 30 frames: [47,127,127,127,127,127,127,127, … ,127]

The pinned header MOVED 80px after paint.  Distinct values observed: [47,127].
```

Frame 1 paints at the stale estimate; frame 2 lands the measurement. **A
single-sample spec reads `127` and passes** — which is why the hub's existing
`navbar_layout.spec.js` would have been green on the broken build, and why this
spec samples across frames rather than once.

On the fixed code the same measurement is `[0,0,0, … ,0]`.

**Defect 3 — the swallowed script.** With the original header comment restored, all
three at-time specs fail:

```
data-at-zone  →  expected "Asia/Tokyo", got null      (stamp() never ran)
window.__atTimeFmt  →  expected true, got false
[data-at-text]  →  still reads the SERVER's clock
```

The two pages are not byte-identical — the broken one carries the leaked prose. What
matters is that no markup assertion in place could tell them apart: the guard written
for exactly this defect, `assert_includes html, "__atTimeFmt"`, is GREEN on the broken
page, because the token survives inside the text the phantom element ate. And the
stamp the server renders is identical whether or not the script later runs, since the
server cannot know where the reader sits. So the localisation itself is observable
only in a browser.

**The profile chrome — two programs the server cannot betray.** `/profile` splits
into a read page and an edit page, and the split added an `IntersectionObserver`
that swaps the identity card for a compact header on scroll, plus an Alpine dirty
check that raises a fixed save bar. Both sit in the document on **every** render
and are hidden by a computed value, so the response bytes are identical whether
either program works. Seven mutations, each verified red:

| Mutation | Specs red |
|---|---|
| the observer never decides "gone" (the script is inert) | 3 |
| the observer is pinned to "gone" (the bar never comes down) | 1 |
| the compact bar spans the viewport instead of matching the card | 1 |
| the dirty check stops trimming | 1 |
| Discard lowers the bar without restoring the fields | 1 |
| the save bar is `absolute`, not `fixed` | 1 |
| `dirty` is always true | 3 |

**Two things this run taught, both worth more than the specs.**

*A reused lab server serves cached templates.* `reuseExistingServer` is on
locally and `RAILS_ENV=test` caches template loading, so a mutation applied
between two runs reports the **previous** mutation's result. The first matrix was
built on that and was wrong in a way that read as a finding: the trim mutation
looked caught when it was not. Kill the server on port 3620 between mutations, or
you are grading a page that no longer exists.

*A negative asserted about a state the page is already in cannot fail.*
`toBeHidden()` immediately after typing is satisfied by the first poll, before
Alpine has reacted; polling for the compact header's opacity at load is satisfied
by the initial CSS, before the observer's first callback. Both passed under the
mutation that should have killed them. The fix is to assert a **transition** —
dirty the form (or scroll the page) first, so the spec watches something *become*
hidden. A third spec made the same claim as an existing transition spec and was
deleted rather than kept, following the precedent in `config/e2e_lane.yml`.

**The lane no longer touches the network.** `layouts/studio/_head` links Montserrat
from `fonts.gstatic.com`, and a slow fetch there surfaces as
`console.error: Failed to load resource`, which `watchPageErrors` counts — measured
at 2 failures in 10 runs, each naming an assertion that had nothing to do with
fonts. `blockOffsiteRequests` in `e2e/helpers.js` answers every off-origin request
with an empty 200. It **answers** rather than aborts on purpose: `route.abort()`
produces `net::ERR_FAILED`, which is the same console error fired deterministically
(3 of 9 specs red on every run). Filtering the message afterwards was rejected — it
would have to recognise a string Chromium chose, and it would forgive a genuine 404
on an engine asset, which this lane must fail on. The older spec files still make
the request and carry the same latent flake; adopting the helper there is a
follow-up, not a silent edit.

## One browser, and what that cannot see

The lane runs **Chromium only**. Named limits, rather than implied ones:

**Intl / timezone canonicalization.** This is not hypothetical — it is the third
motivating defect. `isUS()` matched tzdb long-form zone ids, but a browser returns
the CLDR-canonical id and the engines disagree about which that is: Chromium and
WebKit report `America/Indianapolis`, Firefox reports
`America/Indiana/Indianapolis`. US readers in Indiana saw an "abroad" globe in
Chrome and Safari and the correct bare clock in Firefox.

A Chromium-only lane is **structurally blind** to it: V8 canonicalizes the id
before `isUS()` runs, so a spec pinned to the long form is handed the short form and
passes over the bug.

**Running three engines would not close it either.** The defect only appears if a
spec happens to pick Indiana; every other US zone passes in all three browsers. So
the guard is a **table test** — `test/views/at_time_zone_table_test.rb` asserts both
spellings of every divergent zone resolve to the US, whatever any engine reports.
That is engine-independent, total rather than sampled, and runs in milliseconds on
every PR. It is the right tier for this defect, not a consolation prize.

The split is deliberate: **engine-independent facts are asserted in Ruby;
engine-dependent behavior — layout, paint, event ordering, does-the-script-run — is
asserted in the browser**, where one engine is enough, because those failures are
not engine-specific. Both defects this lane catches fail identically in every
browser.

Also not covered:

- **Cross-engine rendering and CSS-support divergence.** Adding projects to
  `playwright.config.js` is a three-line change if a real defect ever needs it.
  Note it doubles `executed:` in the contract — Playwright counts one test per spec
  per project.
- **Turbo navigation.** The lab serves Alpine but no Turbo, so `turbo:load` /
  `turbo:render` listeners never fire. Specs assert the synchronous first pass.
- **The engine's asset-pipeline integration.** The lab delivers assets by its own
  route (`E2eLabController::AssetDelivery`) rather than through sprockets/propshaft.
  The CSS and JS bytes are the engine's real ones; the delivery mechanism is not a
  consumer's. What the lane DOES see is whether the head asks for an asset at all and
  whether those bytes work in a browser — `vendored_alpine.spec.js` covers exactly
  that for Alpine, and the precompile entry a sprockets consumer needs is asserted
  statically in `test/lib/vendored_alpine_test.rb`.

  A stand-in that delivers something the engine also delivers makes the engine's own
  delivery UNOBSERVABLE, and this lane shipped that bug for a while: the importmap
  stand-in served its own Alpine from `node_modules`, so specs stayed green with the
  engine's Alpine removed entirely. It now delivers nothing. When adding to
  `AssetDelivery`, serve only what a HOST would serve and the engine does not.

## Cost

Measured on `ubuntu-latest`, from this lane's own first CI run
([run 31586075901](https://github.com/McRitchie-Studio/studio-engine/actions/runs/31586075901)):

| Job | Wall time |
|---|---|
| `engine-suite` (existing, `bin/release-check`) | **1m31s** |
| `playwright` (this lane) | **1m5s** — ~45s setup (`npm ci` + chromium), ~10s Rails boot + Tailwind compile, **~4s of specs** |
| `e2e_executed_set` | **10s** |

The lane is a **parallel job, not a step in `bin/release-check`**. As a step those
numbers add and every engine PR would wait ~2m45s. As a parallel job the PR waits
`max(1m31s, 1m5s)` = **1m31s, which is inside the 1m11s–1m30s band the engine lane
already ran in.** The lane costs **~1m15s of billable runner time and ~0s of
anyone's attention.**

Note where the minute actually goes: **the specs are 4 seconds.** Everything else is
`npm ci` and the chromium download. If this ever needs to be cheaper, cache the
browser — do not delete specs.

It is also kept out of `bin/release-check` so a local cert stays in its ~1 minute
budget and does not require a browser install.

### Why no path filter

`paths: ['app/views/**', 'app/assets/**']` would skip the job on a docs-only PR and
save the minute. Refused, for two reasons:

1. **A path-filtered required check reports SKIPPED, not passed** — and a skipped
   required check is the shape that has let a gate go quiet in this ecosystem before.
2. **The filter would have to be right about which paths change browser behavior**,
   and this lane's own history says that inference is hard: the phantom-element
   defect was introduced **by editing a comment**. A filter listing `app/views`
   catches that one, but the general claim — "we can predict from paths whether the
   browser is affected" — is the claim `ClientSurfaceDiff` refuses to make about
   hunks, for exactly the same reason.

At 1m5s in parallel, the saving does not buy that risk. If the lane ever grows
past the engine suite's wall time it becomes the critical path, and **that** is the
moment to shard (`config/e2e_lane.yml` → `shards:`), not to start filtering.

## No quarantine, deliberately

The hub's contract carries `quarantined`, a `quarantine_tag`, a `--grep-invert`, and
an `origin/release`-baselined ratchet to stop a branch raising its own ceiling. All
of it is machinery for 18 specs that had already rotted when that lane was switched
on.

This lane starts with none. Every spec here was written against code that is green
today, and each was verified to go red against its own defect reintroduced. Shipping
the quarantine anyway would hand a lane with nothing to exclude a documented,
tested, reviewed way to exclude things — and the first inconvenient spec would find
it.

There is deliberately no third option: a spec that cannot be fixed gets **deleted**,
with `total_specs` and `executed` lowered in the same commit. That is a diff a
reviewer reads as exactly what it is.

## What this unlocks

`ClientSurfaceDiff.lane_present?` (in mcritchie-studio's `bin/lib/`) returns true
when a repo has an `e2e/` directory or a `config/e2e_lane.yml`. The engine now has
both, so `bin/dor-check`'s browser-evidence gate **blocks** on an engine diff that
adds an imperative browser program with no spec, where it previously only reported
a hole. No change to that gate was needed — the branch was already written and
tested.
