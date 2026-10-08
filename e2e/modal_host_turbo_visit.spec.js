const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] A Turbo visit onto a page that brings its own scoped modal host.
//
// Alpine fires alpine:init once per document, so on a Turbo visit the incoming
// page's scoped host (studio/modals/_scoped_host) cannot register its store
// there. studio/modal_host registers it on turbo:before-render, before Alpine
// reads `$store.<name>.current()` off the host's <template x-if>, and the
// modal-host controller registers it again on connect.
//
// /admin/surveys carries no scoped host; /lab/birthday_gate carries `labModals`.
// The first renders in layouts/survey_turbo_lab (the survey_lab_turbo cookie), so
// Turbo is on the page and drives the visit.
//
// The CONTROL: with the turbo:before-render registration and the controller's
// connect() registration both removed, the store is never registered and this
// spec fails on it.

const DIALOG = '[role="dialog"]';

const storeShape = (page, name) =>
  page.evaluate((n) => {
    const store = window.Alpine && window.Alpine.store(n);
    return store ? { open: typeof store.open, current: typeof store.current } : null;
  }, name);

test("a Turbo visit registers the incoming page's scoped modal store", async ({ page, context, baseURL }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await context.addCookies([{ name: "survey_lab_turbo", value: "1", url: baseURL }]);

  await page.goto("/survey_lab/sign_in?to=/admin/surveys");
  await expect(page.locator("[data-admin-survey-row='first-game']")).toBeVisible();
  expect(await storeShape(page, "labModals")).toBeNull();

  // A marker on window survives a Turbo visit and dies with a full load.
  await page.evaluate(() => { window.__sameDocument = true; });
  await page.evaluate(() => window.Turbo.visit("/lab/birthday_gate"));
  await expect(page.locator('[data-modal-host-store-value="labModals"]')).toBeAttached();
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);

  expect(await storeShape(page, "labModals")).toEqual({ open: "function", current: "function" });

  // The store drives the host it registered for: open mounts the dialog, close
  // unmounts it.
  await page.evaluate(() => window.Alpine.store("labModals").open("birthday-underage", {}));
  await expect(page.locator(DIALOG)).toBeVisible();
  await page.evaluate(() => window.Alpine.store("labModals").close());
  await expect(page.locator(DIALOG)).toHaveCount(0);

  expect(errors).toEqual([]);
});
