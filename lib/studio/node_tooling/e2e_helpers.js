// studio-engine's shared browser-lane helpers. Requires only node: builtins, so it
// loads from the gem's directory (see README.md).

const fs = require("node:fs");

const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost"]);

function isOffOrigin(url) {
  if (!url || !/^https?:/.test(url)) return false;
  return !LOCAL_HOSTS.has(new URL(url).hostname);
}

// Collect everything the page THREW or logged as an error.
//
// `pageerror` is the cheapest detector there is for a script that never ran: the
// phantom-element defect threw a SyntaxError on every load while the response
// bytes were valid and the server-side guard passed.
//
// It hears every frame on the page, a third party's included: Playwright delivers a
// cross-origin frame's console to the page's `console` event. `ownOriginOnly: true`
// scopes that out BY ORIGIN, never by message text. A console error is dropped only
// when the script that logged it was served from another host, and a thrown error
// only when every frame of its stack was. An error with no location or no stack is
// kept, because it cannot be shown to be someone else's. The default counts
// everything.
function watchPageErrors(page, { ownOriginOnly = false } = {}) {
  const errors = [];
  page.on("pageerror", (error) => {
    if (ownOriginOnly) {
      const sources = (error.stack || "").match(/https?:\/\/[^\s)]+/g) || [];
      if (sources.length > 0 && sources.every(isOffOrigin)) return;
    }
    errors.push(`pageerror: ${error.message}`);
  });
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    if (ownOriginOnly && isOffOrigin(message.location().url)) return;
    errors.push(`console.error: ${message.text()}`);
  });
  return errors;
}

// Answer every request that leaves this origin, so the lane cannot depend on the
// public internet.
//
// ANSWERED, NOT ABORTED. route.abort() makes Chromium log `Failed to load resource:
// net::ERR_FAILED`, which watchPageErrors counts. An empty 200 logs nothing, and
// the page falls back as it would offline.
//
// `pinned` maps an off-origin URL to `{ file, contentType }`: a file loaded with
// Subresource Integrity cannot be answered empty (the digest fails and Chromium
// logs it), so it is answered with a byte-exact local copy. The response carries
// `access-control-allow-origin: *`, because a `crossorigin` tag refuses a CORS
// response without it before checking the digest.
async function blockOffsiteRequests(page, { pinned = {} } = {}) {
  await page.route("**/*", (route) => {
    const url = new URL(route.request().url());
    if (LOCAL_HOSTS.has(url.hostname)) return route.continue();

    const copy = pinned[url.href];
    if (copy) {
      return route.fulfill({
        status: 200,
        contentType: copy.contentType,
        headers: { "access-control-allow-origin": "*" },
        body: fs.readFileSync(copy.file),
      });
    }

    return route.fulfill({ status: 200, body: "" });
  });
}

// ---- Full-load page transitions (docs/PAGE_TRANSITIONS.md, "Full page loads") ----
//
// These wait on events the browser fires, never on a clock. Nothing here sleeps.

// Marks each document's pagereveal, for revealed(), settled() and arrivalSettled() below.
// Call it before the first navigation: it is an init script, so every new document gets it,
// and it must be bound before the first render to hear pagereveal at all.
//
// `window.__studioReveal` holds { revealed, transition, done }: `done` is true once the
// arrival's view transition has finished or been skipped, at once when there is none.
function watchReveal(target) {
  return target.addInitScript(() => {
    const state = { revealed: false, transition: false, done: false };
    window.__studioReveal = state;
    window.addEventListener("pagereveal", (event) => {
      state.revealed = true;
      const transition = event.viewTransition;
      state.transition = !!transition;
      if (!transition) { state.done = true; return; }
      const done = () => { state.done = true; };
      transition.finished.then(done, done);
    });
  });
}

// The new page has revealed. VISIBLE IS NOT REVEALED: its DOM parses, and Playwright sees it
// as visible, before its first render. A render-blocking sheet, or the reveal script's own
// hold to the end of parse, keeps pagereveal back, and until then no mark is set and no
// pseudo runs (engine CI run 42503970890 read an empty log at 312 ms).
async function revealed(page, selector) {
  if (selector) await page.locator(selector).first().waitFor({ state: "visible" });
  await page.waitForFunction(() => window.__studioReveal && window.__studioReveal.revealed === true);
}

// Past the whole motion: revealed, and the document's own marks and every
// ::view-transition animation are gone when this returns.
async function settled(page, selector) {
  await revealed(page, selector);
  await page.waitForFunction(() => document.documentElement.dataset.pageTransition === undefined
    && !document.getAnimations().some((a) => ((a.effect && a.effect.pseudoElement) || "").startsWith("::view-transition")));
}

// Two rendered frames. A recorder that samples document.getAnimations() on every
// requestAnimationFrame has run at least once past anything that was live before this call.
function frames(page, count = 2) {
  return page.evaluate((n) => new Promise((done) => {
    const step = (left) => (left === 0 ? done() : requestAnimationFrame(() => step(left - 1)));
    step(n);
  }), count);
}

// For a spec that asserts NOTHING PLAYED: the arrival's view transition has finished or been
// skipped, and two frames have rendered since. A transition that wrongly plays keeps `done`
// false until its last frame, and every frame it draws comes before this returns, so a
// per-frame recorder has logged it. A fixed pause only hoped for that.
async function arrivalSettled(page, selector) {
  await revealed(page, selector);
  await page.waitForFunction(() => window.__studioReveal.done === true);
  await frames(page);
}

// A log kept in sessionStorage, so it outlives each document of a full load.
function sessionLog(page, key = "pt-log") {
  return page.evaluate((name) => JSON.parse(sessionStorage.getItem(name) || "[]"), key);
}

// A red carries its evidence: registers an afterEach that, on a failed test only, prints the
// log `read(page)` returns and attaches it to the report the CI uploads. A red with no log
// once left its cause unprovable. `test` is the host's own @playwright/test `test`, since
// this file cannot require Playwright (see README.md).
function logOnRed(test, read = (page) => sessionLog(page), { name = "pt-log" } = {}) {
  test.afterEach(async ({ page }, testInfo) => {
    if (testInfo.status === testInfo.expectedStatus) return;
    const lines = await Promise.resolve()
      .then(() => read(page))
      .catch((error) => [`(the log could not be read: ${error.message})`]);
    console.log(`${name} for "${testInfo.title}":\n${lines.join("\n")}`);
    await testInfo.attach(name, { body: lines.join("\n"), contentType: "text/plain" });
  });
}

module.exports = {
  isOffOrigin,
  watchPageErrors,
  blockOffsiteRequests,
  watchReveal,
  revealed,
  settled,
  frames,
  arrivalSettled,
  sessionLog,
  logOnRed,
};
