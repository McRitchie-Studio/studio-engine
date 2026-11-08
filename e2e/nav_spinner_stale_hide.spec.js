const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] studio/head_chrome: a nav-spinner hide is bound to the show it ends
// (task engine-nav-spinner-stale-hide).
//
// THE REGRESSION. hideNavSpinner() waits out the minimum display time and then
// hides. A host's layout hydrates on load under the spinner and hides it when the
// read lands; a press that raised the spinner again inside that wait had its
// spinner dropped by the load's timer while its own work still ran (Turf's
// e2e/admin_stimulus_pages.spec.js:114 saw opacity 0.88 fall to 0). Each show now
// starts a generation, and a hide fires only if no later show has started.
//
// The spec drives the real module through the window globals studio/alpine_shims
// installs and reads the spinner's computed opacity, which only a live page has.

const DESKTOP = { width: 1280, height: 800 };
const MIN_MS = 600;

test("a hide still waiting out the minimum leaves a later show's spinner up", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto("/lab/bar_stack?signed_in=1");
  await page.waitForFunction(() => typeof window.showNavSpinner === "function" && typeof window.hideNavSpinner === "function");

  // Every spinner icon on the page takes the same style, so the first one speaks for all.
  const spinner = page.locator(".nav-spinner-icon").first();
  await expect(spinner).toHaveCSS("opacity", "0");

  // A short minimum keeps the spec quick; spinnerMinMs reads the meta on each hide.
  await page.evaluate((ms) => {
    document.querySelector('meta[name="studio-nav-spinner-min-ms"]').setAttribute("content", String(ms));
  }, MIN_MS);

  // The load's show and hide, then a press inside the hide's wait.
  await page.evaluate(() => { window.showNavSpinner(); window.hideNavSpinner() });
  await page.waitForTimeout(200);
  await page.evaluate(() => window.showNavSpinner());

  // Past the first hide's timer and the 300ms transition: the press's spinner stays.
  await page.waitForTimeout(MIN_MS + 400);
  expect(await spinner.evaluate((el) => getComputedStyle(el).opacity), "the stale hide dropped the later show").toBe("1");

  // The press's own hide still takes it down.
  await page.evaluate(() => window.hideNavSpinner());
  await expect(spinner).toHaveCSS("opacity", "0");
  expect(errors).toEqual([]);
});
