// Shared helpers for the engine's browser lane.

// watchPageErrors, and the answered-not-aborted offsite block below, come from the
// engine's Node tooling package (lib/studio/node_tooling/e2e_helpers.js), the one
// every host links. Their WHY lives there.
//
// IT HEARS EVERY FRAME ON THE PAGE, a third party's included. The measured instance
// here is Google's booking frame, which logs `requestStorageAccess: Permission
// denied` from calendar.google.com on its own; specs on the booking lab pass
// `ownOriginOnly: true`.
const shared = require("../lib/studio/node_tooling/e2e_helpers.js");
const { watchPageErrors } = shared;

// Assert the lane is actually looking at a STYLED page before it measures anything
// about layout.
//
// THIS IS THE LANE'S OWN FAILURE MODE, AND IT IS THE ONE THAT WOULD BE INVISIBLE.
// Tailwind emits only the utilities it can see used. If e2e/tailwind_input.css ever
// stops scanning app/views — a moved directory, a renamed @source, a build that
// silently wrote an empty file — then `sticky` and `top-0` stop existing, every
// header lays out as ordinary static flow, and a spec asserting "the pinned header
// never moves" passes triumphantly over a page that has no pinned header at all.
// Green, meaningless, and indistinguishable from working.
//
// So every spec that measures geometry calls this FIRST. It asserts the computed
// style the CSS is supposed to produce, which is a claim about the real page rather
// than about the build.
async function expectStickyChromeIsLive(page, expect) {
  const chrome = await page.evaluate(() => {
    const header = document.querySelector("header");
    if (!header) return null;
    const style = window.getComputedStyle(header);
    return { position: style.position, top: style.top };
  });

  expect(chrome, "the lab page rendered no <header> — layouts/_navbar did not render").not.toBeNull();
  expect(
    chrome.position,
    `the header is not pinned (position: ${chrome.position}). The Tailwind build did not ` +
      "emit `sticky`, so this page cannot exhibit a paint-time offset defect and every " +
      "measurement below would be vacuously green. Check e2e/tailwind_input.css @source globs."
  ).toBe("sticky");

  return chrome;
}

// Sample a value once per animation frame, `frames` times.
//
// WHY FRAMES AND NOT A SINGLE READ. A single post-load read sees only the SETTLED
// value, and the defect this lane exists for is a value that settles CORRECTLY after
// being wrong for one or more painted frames. The hub's existing navbar spec
// (e2e/navbar_layout.spec.js) takes exactly one sample, and it would have been green
// on the broken build — it measures containment, not motion.
//
// The perturbation runs INSIDE the same evaluate as the sampling loop, so the first
// sample lands on the frame immediately after the mutation. Doing it from Node
// across two round-trips leaves an unbounded gap in which a ResizeObserver can fire
// and settle unobserved, which would hide the defect.
async function sampleAcrossFrames(page, { perturb, read, frames = 30 }) {
  return await page.evaluate(
    async ({ perturbSrc, readSrc, frames }) => {
      const perturbFn = eval(`(${perturbSrc})`);
      const readFn = eval(`(${readSrc})`);
      const samples = [];

      perturbFn();

      for (let i = 0; i < frames; i++) {
        await new Promise((resolve) => requestAnimationFrame(resolve));
        samples.push(readFn());
      }

      return samples;
    },
    { perturbSrc: perturb.toString(), readSrc: read.toString(), frames }
  );
}

// Refuse every request that leaves this origin, so the lane cannot depend on the
// public internet.
//
// WHY THIS IS NEEDED AND NOT PARANOIA. It was written for a real, measured flake:
// layouts/studio/_head — the engine's real head partial, which the lab renders on
// purpose — used to link Montserrat from fonts.gstatic.com, and a slow or refused
// fetch there surfaces to the page as `console.error: Failed to load resource`, which
// watchPageErrors counts, which fails a spec that has nothing to do with fonts.
// Measured: 2 runs in 10 on a normal connection, and the failure named the assertion
// rather than the cause.
//
// THAT PARTICULAR REQUEST IS GONE — the engine vendors Montserrat now — and the guard
// stays, because the property it holds was never about fonts. Any off-origin request
// any lab page ever grows has the same failure mode, and this is the only place that
// can close it once for all of them.
//
// ANSWERED, NOT ABORTED, and that distinction is the whole implementation. Calling
// route.abort() here fails the request, which Chromium reports to the page as
// `console.error: Failed to load resource: net::ERR_FAILED` — the same console error
// the flake produced, now fired deterministically. Measured: 3 of 9 specs red on
// every run. Answering the request with an empty 200 means nothing failed, so
// nothing is logged, and the page falls back to the next font in its stack.
//
// Filtering the message afterwards was the other candidate and is worse: it has to
// recognise a string Chromium chose, and it would also forgive a genuine 404 on an
// ENGINE asset — which is a defect this lane must fail on.
//
// THE COST THIS USED TO CARRY IS PAID OFF, and the change is worth knowing about
// because it opened a door. While Montserrat came from fonts.gstatic.com, every spec
// downstream of this helper saw the FALLBACK font, so nothing here could assert a
// measurement that depended on Montserrat's metrics. Montserrat is same-origin now, so
// it is no longer blocked — it arrives from the asset pipeline like any engine asset,
// and text measurements are fair game. e2e/vendored_montserrat.spec.js is the first
// spec to take one, and it could not have been written before.
//
// No off-origin file is pinned any more. Cropper.js was the one (cdnjs, with sha384
// integrity, answered here with byte-exact copies); since engine-vendors-cropper-assets
// the engine vendors it, so it arrives from the asset pipeline like Montserrat.
async function blockOffsiteRequests(page) {
  await shared.blockOffsiteRequests(page);
}

// ---- Waits on a real condition, in place of a pause ------------------------------------
//
// Scrolled to `y`, as the page's own scroll listeners heard it. Turbo records the restoration
// position in its scroll listener (bound when Turbo starts, so ahead of this one), and the
// navbar's collapse queues its frame there. A pause of 100-200ms only hoped both had run.
// A page that cannot scroll that far never fires the event at `y`, and the wait times out.
function scrolledTo(page, y) {
  return page.evaluate((target) => new Promise((done) => {
    if (Math.round(window.scrollY) === target) { done(); return; }
    const heard = () => {
      if (Math.round(window.scrollY) !== target) return;
      window.removeEventListener("scroll", heard);
      done();
    };
    window.addEventListener("scroll", heard);
    window.scrollTo(0, target);
  }), y);
}

// The navbar's collapse is at rest: studio/nav_collapse eases --nav-p over about ten frames
// after a hard scroll and stops writing once it lands. Two frames with the header's height,
// --nav-p and its hold margin all unchanged is that landing.
function navAtRest(page) {
  return page.evaluate(() => new Promise((done) => {
    const header = document.querySelector("header");
    const read = () => (header
      ? `${header.offsetHeight} ${header.style.getPropertyValue("--nav-p")} ${getComputedStyle(header).marginBottom}`
      : "");
    let last = read();
    let still = 0;
    const tick = () => {
      const now = read();
      still = now === last ? still + 1 : 0;
      last = now;
      if (still >= 2) done(); else requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }));
}

// A panel Alpine's x-transition slid in (components/_sidebar_panel: duration-300). Alpine puts
// the enter classes on as it shows the panel and takes them off when the transition ends, so
// visible-and-still-carrying-them is mid-slide. Then no animation of its own is left.
function slidIn(locator) {
  return locator.evaluate((el) => new Promise((done) => {
    const moving = () => el.classList.contains("ease-out") || el.classList.contains("translate-x-full")
      || el.getAnimations().some((a) => a.playState === "running");
    const tick = () => (moving() ? requestAnimationFrame(tick) : done());
    tick();
  }));
}

// Every CSS transition on the element and inside it has finished: a hover's fade and lift, a
// colour easing to a new theme. getAnimations() flushes style first, so a transition the last
// input started is in the list. Keyframe animations are left out: a glow's ring or a spinner
// runs on its own clock (some forever, some paused), and none of them is a settling.
function transitionsDone(locator) {
  return locator.evaluate((el) => Promise.all(el.getAnimations({ subtree: true })
    .filter((a) => typeof CSSTransition === "function" && a instanceof CSSTransition)
    .map((a) => a.finished.catch(() => {}))).then(() => undefined));
}

// ---- In-page jumps and history (studio/in_page_links) ----------------------------------
//
// Counts, from the document's first script on: each jump the module starts
// (studio:in-page-scroll), each it ends (studio:in-page-scroll-end: its scrollend after the
// last aim, or the reader taking over), and each popstate. An init script, so the popstate
// listener is bound ahead of the module's own. Under Turbo the module stops the popstate
// (stopImmediatePropagation) after it has scrolled, so a listener bound later never hears it.
// Call before page.goto.
function watchInPageJumps(page) {
  return page.addInitScript(() => {
    const seen = { starts: 0, ends: 0, pops: 0 };
    window.__inPageJumps = seen;
    document.addEventListener("studio:in-page-scroll", () => { seen.starts += 1; });
    document.addEventListener("studio:in-page-scroll-end", () => { seen.ends += 1; });
    window.addEventListener("popstate", () => { seen.pops += 1; }, { capture: true });
  });
}

// The module's jump has ended: at least `count` jumps started since the document began, and
// every one has ended. The end is the module's own: the browser's scrollend after its last
// aim, so the target is in place, not a guess at how long a smooth scroll takes. A page
// without the module never starts one, and the wait times out.
function jumpEnded(page, count = 1) {
  return page.waitForFunction((n) => {
    const seen = window.__inPageJumps;
    return seen.starts >= n && seen.ends >= seen.starts;
  }, count);
}

// Back or Forward between two entries of one page, and the place it restored. A traversal
// fires popstate even when it does not move the page, where no scroll or scrollend event
// comes. The restore runs in the popstate's own task: the module's instant scroll under
// Turbo, the browser's own restore without it. So the read is two frames after the
// popstate, and it is the restored position whether the page moved or not.
async function traversed(page, go) {
  const before = await page.evaluate(() => window.__inPageJumps.pops);
  await go();
  await page.waitForFunction((n) => window.__inPageJumps.pops > n, before);
  return page.evaluate(() => new Promise((done) => {
    requestAnimationFrame(() => requestAnimationFrame(() => done(window.scrollY)));
  }));
}

// A NEGATIVE PROOF, so it has a window: every scrollY, each frame, for at least `ms` and at
// least 30 frames. Nothing fires for a move that does not happen, so the window is the app's
// own: callers pass the in-page module's longest timer, twice (inPageTimerWindow). A move
// and a move back cannot pass as stillness, since every frame is read.
function scrollYAcrossWindow(page, ms) {
  return page.evaluate((span) => new Promise((done) => {
    const ys = [];
    const start = performance.now();
    const tick = () => {
      ys.push(window.scrollY);
      if (ys.length >= 30 && performance.now() - start >= span) done(ys);
      else requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }), ms);
}

// The in-page module's longest timer (START_CAP_MS), twice, read from its source so the
// window follows the module.
function inPageTimerWindow() {
  const source = require("fs").readFileSync(require("path").join(__dirname, "../app/javascript/studio/in_page_links.js"), "utf8");
  return 2 * Number(source.match(/export const START_CAP_MS = (\d+)/)[1]);
}

module.exports = {
  watchPageErrors, expectStickyChromeIsLive, sampleAcrossFrames, blockOffsiteRequests,
  scrolledTo, navAtRest, slidIn, transitionsDone,
  watchInPageJumps, jumpEnded, traversed, scrollYAcrossWindow, inPageTimerWindow,
};
