const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The session-drift store in a real browser (docs/SESSION_DRIFT.md).
//
// WHY THIS IS IN THE BROWSER LANE. test/views/studio_session_store_test.rb executes
// the store's transitions under node, with a FAKE BroadcastChannel and a fake
// document. Those stubs are exactly what cannot vouch for three facts only a browser
// holds:
//
//   1. The ENGINE HEAD delivers a working store. The meta tag must be in the head,
//      the script must load and run without throwing, and it must run BEFORE the
//      deferred Alpine so Alpine.store('studioSession') exists. A string assertion
//      on the partial is green whether or not any of that happens.
//   2. Two pages really hear each other. BroadcastChannel delivery between two tabs
//      of one browser, with a structured-cloned message, is the whole cross-tab
//      feature, and a stub bus proves only that the store calls postMessage.
//   3. The warning event reaches a listener on the real document.
//
// The lab page (/lab/session_drift) takes the stamp's inputs from its query string.
// It has no rehydrate endpoint, so drift is final: the stale page stays `stale`.

test.beforeEach(async ({ page }) => {
  await blockOffsiteRequests(page);
});

function labUrl({ fp, issued, state }) {
  return `/lab/session_drift?fp=${encodeURIComponent(fp)}&issued=${issued}&state=${state}`;
}

test("the engine head seats the store and mirrors it into Alpine", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.goto(labUrl({ fp: "fp-alice", issued: 1000, state: "authenticated" }));

  const snapshot = await page.evaluate(() => window.StudioSession && window.StudioSession.current());
  expect(snapshot, "window.StudioSession was not published").not.toBeNull();
  expect(snapshot.state).toBe("authenticated");
  expect(snapshot.fingerprint).toBe("fp-alice");
  expect(await page.locator('meta[name="studio-session"]').count()).toBe(1);

  await expect
    .poll(() => page.evaluate(() => window.Alpine && Alpine.store("studioSession") && Alpine.store("studioSession").state))
    .toBe("authenticated");
  expect(errors).toEqual([]);
});

test("a newer session in another tab makes this tab stale and warns once", async ({ page, context }) => {
  const errorsA = watchPageErrors(page);
  await page.goto(labUrl({ fp: "fp-alice", issued: 1000, state: "authenticated" }));
  await page.evaluate(() => {
    window.__labMismatches = [];
    document.addEventListener("session:mismatch", (event) => window.__labMismatches.push(event.detail.state));
  });
  expect(await page.evaluate(() => StudioSession.current().state)).toBe("authenticated");

  const other = await context.newPage();
  const errorsB = watchPageErrors(other);
  await blockOffsiteRequests(other);
  await other.goto(labUrl({ fp: "anonymous", issued: 2000, state: "anonymous" }));

  // A TRANSITION, polled from the state the page was in before the other tab opened.
  await expect.poll(() => page.evaluate(() => StudioSession.current().state)).toBe("stale");
  expect(await page.evaluate(() => StudioSession.current().reason)).toBe("peer");
  expect(await page.evaluate(() => window.__labMismatches)).toEqual(["stale"]);

  // The newer tab heard the older one too, and an older truth never moves it.
  expect(await other.evaluate(() => StudioSession.current().state)).toBe("anonymous");
  expect(errorsA).toEqual([]);
  expect(errorsB).toEqual([]);
});
