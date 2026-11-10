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
