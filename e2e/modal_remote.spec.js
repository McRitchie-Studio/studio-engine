const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] On-demand modals (Studio.modals): studio/modal_host fetches a
// registered modal the first time it opens, inserts it into the shared host,
// and opens it, with no change to the open() call. /lab/modal_remote renders
// the host under Turbo with one layout-rendered registration (lab-local); the
// lab-* ids are registered in e2e/boot.rb and reach the page only through
// GET /_studio/modals/:id.

const DIALOG = '[role="dialog"]';
const ENDPOINT = /\/_studio\/modals\/lab-rules$/;

// Requests to one modal's endpoint, counted from the page's own network.
const countRequests = (page, pattern) => {
  const seen = [];
  page.on("request", (req) => { if (pattern.test(new URL(req.url()).pathname)) seen.push(req.url()); });
  return seen;
};

// How many copies of a fetched registration the host template carries.
const insertedCopies = (page, id) =>
  page.evaluate((modalId) => {
    const host = document.querySelector("template[data-modal-host-remote-value]");
    return host ? host.content.querySelectorAll(`template[data-studio-remote-modal="${modalId}"]`).length : -1;
  }, id);

test.beforeEach(async ({ page }) => {
  await blockOffsiteRequests(page);
});

test("a registered modal loads on its first open, then opens from the page with no second fetch", async ({ page }) => {
  const errors = watchPageErrors(page);
  const fetched = countRequests(page, ENDPOINT);
  await page.goto("/lab/modal_remote");

  expect(await insertedCopies(page, "lab-rules")).toBe(0);
  await page.locator('[data-test="open-rules"]').click();
  await expect(page.locator('[data-test="remote-rules"]')).toBeVisible();
  await expect(page.locator('[data-test="remote-greeting"]')).toHaveText("Hello from the registered locals");
  await expect(page.locator(DIALOG).locator("h2")).toHaveText("Rules card");
  expect(fetched).toHaveLength(1);

  await page.locator('[data-test="remote-close"]').click();
  await expect(page.locator(DIALOG)).toHaveCount(0);
  await page.locator('[data-test="open-rules"]').click();
  await expect(page.locator('[data-test="remote-rules"]')).toHaveCount(1);
  expect(fetched).toHaveLength(1);
  expect(await insertedCopies(page, "lab-rules")).toBe(1);

  expect(errors).toEqual([]);
});

test("a layout-rendered modal still opens at once and fetches nothing", async ({ page }) => {
  const errors = watchPageErrors(page);
  const fetched = countRequests(page, /\/_studio\/modals\/lab-local$/);
  await page.goto("/lab/modal_remote");

  await page.locator('[data-test="open-local"]').click();
  await expect(page.locator('[data-test="local-card"]')).toBeVisible();
  expect(await page.evaluate(() => window.Alpine.store("modals").isOpen("lab-local"))).toBe(true);
  expect(fetched).toHaveLength(0);
  expect(errors).toEqual([]);
});

test("a slow first fetch shows the loading card, then the modal", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.route(ENDPOINT, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 900));
    await route.continue();
  });
  await page.goto("/lab/modal_remote");

  await page.locator('[data-test="open-rules"]').click();
  await expect(page.locator('[data-modal-remote-state="loading"]')).toBeVisible();
  await expect(page.locator('[data-test="remote-rules"]')).toHaveCount(0);
  await expect(page.locator('[data-test="remote-rules"]')).toBeVisible({ timeout: 5000 });
  await expect(page.locator('[data-modal-remote-state="loading"]')).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("a modal whose fetch fails shows the error card, which closes", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.goto("/lab/modal_remote");

  await page.locator('[data-test="open-broken"]').click();
  const card = page.locator('[data-modal-remote-state="error"]');
  await expect(card).toBeVisible();
  await card.getByRole("button", { name: "Close" }).click();
  await expect(page.locator(DIALOG)).toHaveCount(0);

  // A signed-in-only modal, signed out: the endpoint's 401 is the same card.
  await page.locator('[data-test="open-member"]').click();
  await expect(page.locator('[data-modal-remote-state="error"]')).toBeVisible();
  await expect(page.locator('[data-test="remote-member"]')).toHaveCount(0);

  // The failures are network answers (500, 401), not page errors.
  expect(errors.filter((e) => !/status of (500|401)/.test(e))).toEqual([]);
});

test("Turbo visits re-insert a loaded modal once, from the cache, and never twice", async ({ page }) => {
  const errors = watchPageErrors(page);
  const fetched = countRequests(page, ENDPOINT);
  await page.goto("/lab/modal_remote");
  await page.evaluate(() => { window.__sameDocument = true; });

  await page.locator('[data-test="open-rules"]').click();
  await expect(page.locator('[data-test="remote-rules"]')).toBeVisible();
  await page.locator('[data-test="remote-close"]').click();
  await expect(page.locator(DIALOG)).toHaveCount(0);

  // To page B by Turbo: a fresh host, the cache still warm.
  await page.locator('[data-test="other-page"]').click();
  await expect(page.locator('[data-test="remote-page"]')).toHaveText("Remote modals B");
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
  expect(await insertedCopies(page, "lab-rules")).toBe(0);
  await page.locator('[data-test="open-rules"]').click();
  await expect(page.locator('[data-test="remote-rules"]')).toHaveCount(1);
  await page.locator('[data-test="remote-close"]').click();
  await expect(page.locator(DIALOG)).toHaveCount(0);
  expect(await insertedCopies(page, "lab-rules")).toBe(1);

  // Back to A: Turbo restores its snapshot, which already carries the insert.
  await page.goBack();
  await expect(page.locator('[data-test="remote-page"]')).toHaveText("Remote modals A");
  await page.locator('[data-test="open-rules"]').click();
  await expect(page.locator('[data-test="remote-rules"]')).toHaveCount(1);
  expect(await insertedCopies(page, "lab-rules")).toBe(1);

  expect(fetched).toHaveLength(1);
  expect(errors).toEqual([]);
});

test("a prefetch-flagged modal is fetched when the browser idles and opens with no wait", async ({ page }) => {
  const errors = watchPageErrors(page);
  const prefetched = countRequests(page, /\/_studio\/modals\/lab-prefetch$/);
  await page.goto("/lab/modal_remote");

  await expect.poll(() => prefetched.length, { timeout: 6000 }).toBe(1);
  // Let the response land before opening.
  await page.waitForLoadState("networkidle");
  await page.evaluate(() => window.Alpine.store("modals").open("lab-prefetch", { title: "Prefetched" }));
  expect(await page.evaluate(() => window.Alpine.store("modals").isOpen("lab-prefetch"))).toBe(true);
  await expect(page.locator('[data-test="remote-rules"]')).toBeVisible();
  expect(prefetched).toHaveLength(1);
  expect(errors).toEqual([]);
});

// ---- engine-modals-fetch-hardening -------------------------------------------
// The lab sets Studio.modals.fetch_timeout_ms to 2500 (e2e/boot.rb).

test("a stalled fetch turns into the error card; Try again recovers, and Close works on a non-dismissible card", async ({ page }) => {
  const errors = watchPageErrors(page);
  let stall = true;
  await page.route(ENDPOINT, async (route) => {
    if (stall) return; // never answered: the request hangs until the timeout aborts it
    await route.continue();
  });
  await page.goto("/lab/modal_remote");

  await page.locator('[data-test="open-rules-locked"]').click();
  const loading = page.locator('[data-modal-remote-state="loading"]');
  await expect(loading).toBeVisible();
  await expect(loading).toHaveAttribute("role", "status");
  const card = page.locator('[data-modal-remote-state="error"]');
  await expect(card).toBeVisible({ timeout: 6000 });
  await expect(card).toContainText("did not answer in 2500ms");

  // Escape does not close a dismissible: false card; Try again does recover it.
  await page.keyboard.press("Escape");
  await expect(card).toBeVisible();
  stall = false;
  await card.getByRole("button", { name: "Try again" }).click();
  // The button unmounted under focus; focus is back inside the dialog, not on body.
  await expect.poll(() => page.evaluate(() => {
    const dialog = document.querySelector('[role="dialog"]');
    return !!dialog && dialog.contains(document.activeElement);
  })).toBe(true);
  await expect(page.locator('[data-test="remote-rules"]')).toBeVisible({ timeout: 5000 });
  await expect(card).toHaveCount(0);
  expect(await page.evaluate(() => document.querySelector('[role="dialog"]').contains(document.activeElement))).toBe(true);
  await page.locator('[data-test="remote-close"]').click();
  await expect(page.locator(DIALOG)).toHaveCount(0);

  expect(errors).toEqual([]);
});

test("Close on the error card closes a modal opened dismissible: false", async ({ page }) => {
  const errors = watchPageErrors(page);
  await page.route(ENDPOINT, () => {}); // stalls for good
  await page.goto("/lab/modal_remote");

  await page.locator('[data-test="open-rules-locked"]').click();
  const card = page.locator('[data-modal-remote-state="error"]');
  await expect(card).toBeVisible({ timeout: 6000 });
  await card.getByRole("button", { name: "Close" }).click();
  await expect(page.locator(DIALOG)).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("a fragment carrying a <script> is refused, never inserted, and logs nothing", async ({ page }) => {
  const errors = watchPageErrors(page);
  const consoleLines = [];
  page.on("console", (msg) => { if (msg.type() === "error" || msg.type() === "warning") consoleLines.push(msg.text()); });
  await page.goto("/lab/modal_remote");

  await page.locator('[data-test="open-script"]').click();
  const card = page.locator('[data-modal-remote-state="error"]');
  await expect(card).toBeVisible();
  await expect(card).toContainText("carries a <script>");
  await expect(page.locator('[data-test="remote-script"]')).toHaveCount(0);
  expect(await insertedCopies(page, "lab-script")).toBe(0);
  expect(await page.evaluate(() => window.__labScriptRan === true)).toBe(false);
  expect(consoleLines).toEqual([]);
  expect(errors).toEqual([]);
});

// The session marker the host advertises (Studio::Modals.session_marker).
const sessionMarker = (page) =>
  page.evaluate(() => {
    const host = document.querySelector("template[data-modal-host-remote-value]");
    return host ? JSON.parse(host.getAttribute("data-modal-host-remote-value")).session : null;
  });

test("sign-in and sign-out by Turbo visit drop the cached fragments, so the next open refetches", async ({ page }) => {
  const errors = watchPageErrors(page);
  const fetched = countRequests(page, ENDPOINT);
  await page.goto("/lab/modal_remote");
  await page.evaluate(() => { window.__sameDocument = true; });

  const openAndClose = async () => {
    await page.locator('[data-test="open-rules"]').click();
    await expect(page.locator('[data-test="remote-rules"]')).toHaveCount(1);
    await page.locator('[data-test="remote-close"]').click();
    await expect(page.locator(DIALOG)).toHaveCount(0);
  };

  await openAndClose();
  expect(fetched).toHaveLength(1);

  // Signed in, by Turbo (the session kept, a user id added): a fresh fetch.
  const anonymous = await sessionMarker(page);
  await page.locator('[data-test="sign-in"]').click();
  await expect(page.locator('[data-test="remote-page"]')).toHaveText("Remote modals B");
  await expect.poll(() => sessionMarker(page)).not.toBe(anonymous);
  await openAndClose();
  expect(fetched).toHaveLength(2);

  // Same session, another Turbo visit: from the cache. A was visited before,
  // so Turbo first shows its cached snapshot (the OLD marker) as a preview;
  // wait for the real render, not the heading, or the open lands on the preview.
  const signedIn = await sessionMarker(page);
  await page.locator('[data-test="other-page"]').click();
  await expect(page.locator('[data-test="remote-page"]')).toHaveText("Remote modals A");
  await expect.poll(() => page.evaluate(() => !document.documentElement.hasAttribute("data-turbo-preview"))).toBe(true);
  await expect.poll(() => sessionMarker(page)).toBe(signedIn);
  await openAndClose();
  expect(fetched).toHaveLength(2);

  // Signed out (reset_session), by Turbo: a fresh fetch again. The visit lands
  // on A, the page it left, so wait for the new host's marker, not the heading.
  const before = await sessionMarker(page);
  await page.locator('[data-test="sign-out"]').click();
  await expect.poll(() => sessionMarker(page)).not.toBe(before);
  await openAndClose();
  expect(fetched).toHaveLength(3);

  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
  expect(errors).toEqual([]);
});

test("prefetch runs again after a Turbo visit", async ({ page }) => {
  const errors = watchPageErrors(page);
  const prefetched = countRequests(page, /\/_studio\/modals\/lab-prefetch$/);
  await page.goto("/lab/modal_remote");
  await expect.poll(() => prefetched.length, { timeout: 6000 }).toBe(1);
  await page.waitForLoadState("networkidle");

  // A sign-in by Turbo changes the session, so the visited page's prefetch
  // cannot be served from the cache: it fetches on idle after turbo:load.
  await page.locator('[data-test="sign-in"]').click();
  await expect(page.locator('[data-test="remote-page"]')).toHaveText("Remote modals B");
  await expect.poll(() => prefetched.length, { timeout: 6000 }).toBe(2);
  expect(errors).toEqual([]);
});

test("an app with nothing registered: the host advertises nothing, fetches nothing, and still opens", async ({ page }) => {
  const errors = watchPageErrors(page);
  const fetched = countRequests(page, /\/_studio\/modals\//);
  await page.goto("/lab/modal_host");

  expect(await page.locator("template[data-modal-host-remote-value]").count()).toBe(0);
  expect(await page.locator("[data-modal-host-card]").count()).toBe(0);
  await page.evaluate(() => window.Alpine.store("modals").open("lab-first", { title: "First card" }));
  await expect(page.locator(DIALOG)).toBeVisible();
  expect(await page.evaluate(() => window.Alpine.store("modals").isOpen("lab-first"))).toBe(true);
  await page.evaluate(() => window.Alpine.store("modals").close());
  await expect(page.locator(DIALOG)).toHaveCount(0);

  // Idle passes (prefetch would have run): still no request.
  await page.waitForTimeout(2000);
  expect(fetched).toEqual([]);
  expect(errors).toEqual([]);
});

test("a session revalidation (first seating, stale -> authenticated) keeps an open fetched modal intact", async ({ page }) => {
  const errors = watchPageErrors(page);
  const fetched = countRequests(page, ENDPOINT);
  await page.goto("/lab/modal_remote");
  await page.locator('[data-test="open-rules-locked"]').click();
  await expect(page.locator('[data-test="remote-rules"]')).toBeVisible();

  // What studio/session sends when a hidden tab returns (session.js transition()).
  await page.evaluate(() => {
    const send = (previous, state) => document.dispatchEvent(new CustomEvent("session:changed", {
      detail: { previous, state, snapshot: { state, identities: { user: "lab" } } }
    }));
    send(null, "authenticated");
    send("authenticated", "stale");
    send("stale", "authenticated");
  });
  await expect(page.locator('[data-test="remote-rules"]')).toBeVisible();
  await page.locator('[data-test="remote-close"]').click();
  await expect(page.locator(DIALOG)).toHaveCount(0);
  await page.locator('[data-test="open-rules"]').click();
  await expect(page.locator('[data-test="remote-rules"]')).toBeVisible();
  expect(fetched).toHaveLength(1);
  expect(errors).toEqual([]);
});
