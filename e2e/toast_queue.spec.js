const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The toast queue (studio/toast, $store.toasts) on a page that renders
// layouts/studio/flash the way a host layout does.
//
// What a browser shows and a unit test cannot: Alpine reads $store.toasts as it
// walks the page, before Stimulus connects a controller, so the store has to be
// registered by then; a Turbo visit swaps the root without a new alpine:init; and
// a page restored from Turbo's cache is a clone of the one that left.
//
// CONTROLS, each run against this file:
//   - drop the `toast` listener in installToast: the event specs fail.
//   - drop both seeding listeners (alpine:initialized, turbo:load) and the
//     controller's connect: the flash specs fail.
//   - drop the turbo:before-cache listener: the Back spec shows the first page's
//     flash again.
//   - drop `javascript_import_module_tag "studio/toast"` from the head: the
//     failed-boot spec fails with Alpine's expression error.

const BOOT_MODULE = /\/studio\/application(?:-[0-9a-f]+)?\.js(?:\?|$)/;

const wrappers = (page) => page.locator("#toast-container .toast-wrapper");
const titles = (page) => page.locator("#toast-container .toast-wrapper span.text-heading");
const messages = (page) => page.locator("#toast-container .toast-wrapper p");

const raise = (page, detail) =>
  page.evaluate((d) => window.dispatchEvent(new CustomEvent("toast", { detail: d })), detail);

test("a page's flash enters as toasts: a notice and an alert", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);

  await page.goto("/lab/toast_flash?notice=Saved&alert=Nope");

  await expect(page.locator('[data-studio-controller="toast"]')).toHaveCount(1);
  await expect(wrappers(page)).toHaveCount(2);
  // Newest first: the alert is seeded after the notice.
  await expect(titles(page)).toHaveText(["Error", "Success"]);
  await expect(messages(page)).toHaveText(["Nope", "Saved"]);
  expect(errors).toEqual([]);
});

test("the toast window event raises a toast, and a sixth drops the oldest", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/toast_flash");
  await expect(page.locator('[data-studio-controller="toast"]')).toHaveCount(1);
  await expect(wrappers(page)).toHaveCount(0);

  await raise(page, { type: "alert", title: "Blocked", message: "Not from here", duration: 0 });
  await expect(titles(page)).toHaveText(["Blocked"]);
  await expect(messages(page)).toHaveText(["Not from here"]);

  for (let n = 2; n <= 6; n += 1) await raise(page, { title: `Toast ${n}`, duration: 0 });
  await expect(titles(page)).toHaveText(["Toast 6", "Toast 5", "Toast 4", "Toast 3", "Toast 2"]);

  // Dismiss takes the newest out; the rest stay.
  await page.locator('#toast-container button[aria-label="Dismiss"]').first().click();
  await expect(titles(page)).toHaveText(["Toast 5", "Toast 4", "Toast 3", "Toast 2"]);
  expect(errors).toEqual([]);
});

test("a toast leaves on its own at its duration", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/toast_flash");
  await expect(page.locator('[data-studio-controller="toast"]')).toHaveCount(1);

  await raise(page, { title: "Brief", duration: 300 });
  await expect(titles(page)).toHaveText(["Brief"]);
  await expect(wrappers(page)).toHaveCount(0);
});

test("a toast root that arrives after load is seeded by its controller", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/toast_flash");
  await expect(wrappers(page)).toHaveCount(0);

  // A second root, as a frame or a stream would bring it: no alpine:init, no
  // turbo:load, only Stimulus sees it connect.
  await page.evaluate(() => {
    const root = document.createElement("div");
    root.setAttribute("data-studio-controller", "toast");
    root.setAttribute("data-toast-initial-value", JSON.stringify([{ type: "notice", message: "Arrived late" }]));
    document.body.appendChild(root);
  });

  await expect(messages(page)).toHaveText(["Arrived late"]);
  expect(errors).toEqual([]);
});

test("a Turbo visit swaps the queue for the next page's flash, and Back replays nothing", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);

  await page.goto("/lab/toast_flash?notice=First+page");
  await expect(messages(page)).toHaveText(["First page"]);
  await raise(page, { title: "Sticky", duration: 0 });
  await expect(titles(page)).toHaveText(["Sticky", "Success"]);

  await page.evaluate(() => { window.__sameDocument = true; });
  await page.locator('[data-test="next-page"]').click();
  await expect(page).toHaveURL(/notice=Second\+page/);
  expect(await page.evaluate(() => window.__sameDocument), "the link was a Turbo visit").toBe(true);

  // The sticky toast belonged to the page that left.
  await expect(messages(page)).toHaveText(["Second page"]);
  await expect(wrappers(page)).toHaveCount(1);

  await page.goBack();
  await expect(page).toHaveURL(/notice=First\+page/);
  await expect(page.locator('[data-studio-controller="toast"]')).toHaveCount(1);
  // Long enough for a replayed flash to enter (50ms), and for the second
  // page's own toast to have been carried over if the queue had not gone.
  await page.waitForTimeout(400);
  await expect(wrappers(page)).toHaveCount(0);
  expect(await page.evaluate(() => window.__sameDocument), "Back restored from Turbo's cache").toBe(true);

  // The restored page still raises toasts.
  await raise(page, { title: "After Back", duration: 0 });
  await expect(titles(page)).toHaveText(["After Back"]);
  expect(errors).toEqual([]);
});

test("the flash and the toast event survive a boot that fails to load", async ({ page }) => {
  await blockOffsiteRequests(page);
  const aborted = [];
  await page.route((url) => BOOT_MODULE.test(url.pathname + url.search), (route) => {
    aborted.push(route.request().url());
    return route.abort();
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    if (BOOT_MODULE.test(message.location().url || "")) return;
    errors.push(`console.error: ${message.text()}`);
  });

  await page.goto("/lab/toast_flash?notice=Saved");

  await expect(messages(page)).toHaveText(["Saved"]);
  expect(aborted.length, "studio/application was never requested, so nothing failed").toBeGreaterThan(0);
  expect(await page.evaluate(() => typeof window.navCollapse), "the boot did fail").toBe("undefined");

  await raise(page, { title: "Still here", duration: 0 });
  await expect(titles(page)).toHaveText(["Still here", "Success"]);
  expect(errors).toEqual([]);
});
