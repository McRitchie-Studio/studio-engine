const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The stale-modal sweep survives a boot that fails to load.
//
// A modal left open must not come back from Turbo's snapshot on Back.
// studio/modal_host binds that sweep itself (pageshow and turbo:before-cache),
// and layouts/studio/_head loads the module by its own tag, so the sweep holds
// when studio/application, and with it the modal-host controller, never loads.
//
// /admin/surveys renders in layouts/survey_turbo_lab (the survey_lab_turbo
// cookie), so Turbo is on the page; /lab/birthday_gate brings `labModals`.
//
// The CONTROL: remove the turbo:before-cache listener from installModalHost and
// the first spec fails, with the dialog back on the page after Back. Bind the
// sweep in the controller's connect() as well and the second fails on a count
// of 2.
//
// NOT COVERED: the bfcache half (pageshow with persisted: true). Playwright's
// Chromium does not restore from bfcache; test/javascript/modal_host.test.mjs
// drives that listener.

const BOOT_MODULE = /\/studio\/application(?:-[0-9a-f]+)?\.js(?:\?|$)/;
const DIALOG = '[role="dialog"]';
const HOST = '[data-modal-host-store-value="labModals"]';

// Called after blockOffsiteRequests: the route registered last answers first.
async function breakTheBoot(page) {
  const aborted = [];
  await page.route((url) => BOOT_MODULE.test(url.pathname + url.search), (route) => {
    aborted.push(route.request().url());
    return route.abort();
  });
  return aborted;
}

// Sign in, Turbo-visit the page with the scoped host, and open a dismissible card.
async function openModalOnATurboPage(page, context, baseURL) {
  await context.addCookies([{ name: "survey_lab_turbo", value: "1", url: baseURL }]);
  await page.goto("/survey_lab/sign_in?to=/admin/surveys");
  await expect(page.locator("[data-admin-survey-row='first-game']")).toBeVisible();

  await page.evaluate(() => { window.__sameDocument = true; });
  await page.evaluate(() => window.Turbo.visit("/lab/birthday_gate"));
  await expect(page.locator(HOST)).toBeAttached();
  await page.evaluate(() => window.Alpine.store("labModals").open("birthday-underage", {}));
  await expect(page.locator(DIALOG)).toBeVisible();
}

const openCards = (page) => page.evaluate(() => window.Alpine.store("labModals").stack.length);

test("with studio/application aborted, an open modal is closed after a Turbo visit and Back", async ({ page, context, baseURL }) => {
  await blockOffsiteRequests(page);
  const aborted = await breakTheBoot(page);
  await openModalOnATurboPage(page, context, baseURL);

  // The failure happened: the boot was refused and nothing it installs is here.
  expect(aborted.length, "studio/application was never requested, so nothing failed").toBeGreaterThan(0);
  expect(await page.evaluate(() => typeof window.navCollapse)).toBe("undefined");

  await page.evaluate(() => window.Turbo.visit("/admin/surveys"));
  await expect(page.locator("[data-admin-survey-row='first-game']")).toBeVisible();
  expect(await openCards(page)).toBe(0);

  await page.goBack();
  await expect(page.locator(HOST)).toBeAttached();
  await expect(page).toHaveURL(/\/lab\/birthday_gate$/);
  // One document throughout, so Back restored Turbo's snapshot.
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
  expect(await openCards(page)).toBe(0);
  await expect(page.locator(DIALOG)).toHaveCount(0);
});

test("with the boot loaded, a Turbo visit sweeps the store once", async ({ page, context, baseURL }) => {
  await blockOffsiteRequests(page);
  await openModalOnATurboPage(page, context, baseURL);
  expect(await page.evaluate(() => typeof window.navCollapse)).toBe("function");

  // Count the store's sweeps, whichever method the sweep calls.
  await page.evaluate(() => {
    const store = window.Alpine.store("labModals");
    window.__sweeps = 0;
    for (const method of ["closeAllDismissible", "closeAll"]) {
      if (typeof store[method] !== "function") continue;
      const original = store[method];
      store[method] = function (...args) { window.__sweeps += 1; return original.apply(this, args); };
    }
  });

  await page.evaluate(() => window.Turbo.visit("/admin/surveys"));
  await expect(page.locator("[data-admin-survey-row='first-game']")).toBeVisible();
  expect(await page.evaluate(() => window.__sweeps)).toBe(1);
  expect(await openCards(page)).toBe(0);
});
