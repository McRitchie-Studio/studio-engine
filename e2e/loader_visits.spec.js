const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The page-load overlay under Turbo (studio/loader, docs/LOADER.md):
// WHEN it shows, and that it, and a busy button, always clear.
// /lab/loader_visits?ms=N answers N ms late; its overlay waits 100ms.
//
//   1. A background Turbo "replace" visit (the hub's usage_countdown.js polls
//      this way) never shows the overlay; a user's slow navigation does.
//   2. A data-turbo="false" submit, then Back, leaves no busy button and no
//      overlay: e2e/loader_bfcache.spec.js, which needs its own browser.
//   3. A Turbo link to a download with no extension leaves no overlay up.
//   4. A data-turbo="false" form that downloads clears its button at the cap.
//   5. The shown overlay is not aria-busy, so its Loading status is announced.
//
// CONTROLS, each run against this file once:
//   - drop the userVisit() check in installStudioLoader: spec 1 fails.
//   - drop the pagehide and pageshow settle() listeners: loader_bfcache fails.
//   - drop 'turbo:reload' from the hide list: spec 3 fails.
//   - drop armCap() from markBusy: spec 4 fails.
//   - set aria-busy on the overlay in show(): spec 5 fails.

const overlay = (page) => page.locator("[data-studio-loader-overlay]");

test("a background replace visit never shows the overlay; a user's slow navigation does", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto("/lab/loader_visits");
  await page.waitForFunction(() => window.Turbo);

  // Count every unhide while the page waits, so a flash cannot slip between polls.
  const watch = () => page.evaluate(() => {
    window.__overlayShown = 0;
    const el = document.querySelector("[data-studio-loader-overlay]");
    new MutationObserver(() => { if (!el.hidden) window.__overlayShown++; }).observe(el, { attributes: true });
  });

  await watch();
  await page.evaluate(() => window.Turbo.visit("/lab/loader_visits?ms=1200", { action: "replace" }));
  await page.waitForTimeout(800);
  expect(await page.evaluate(() => window.__overlayShown), "a replace visit showed the overlay").toBe(0);
  await expect(page.locator('[data-test="arrived"]')).toHaveText("1200");
  await expect(overlay(page)).toBeHidden();

  await page.locator('[data-test="slow-link"]').click();
  await expect(overlay(page)).toBeVisible();
  await expect(page).toHaveURL(/ms=1200/);
  await expect(overlay(page)).toBeHidden();
  expect(errors).toEqual([]);
});

test("a Turbo link to a download with no extension leaves no overlay up", async ({ page }) => {
  await page.goto("/lab/loader_visits");
  await page.waitForFunction(() => window.Turbo);
  const download = page.waitForEvent("download");
  await page.locator('[data-test="download-link"]').click();
  await download;
  // Past the overlay's 100ms delay, well inside the 15s cap.
  await page.waitForTimeout(600);
  await expect(overlay(page)).toBeHidden();
  await expect(page).toHaveURL(/\/lab\/loader_visits$/);
});

test("a data-turbo=false form that downloads clears its busy button at the cap", async ({ page }) => {
  await page.goto("/lab/loader_visits?max_wait=1000");
  const submit = page.locator('[data-test="download-submit"]');
  const download = page.waitForEvent("download");
  await submit.click();
  await download;
  await expect(submit).toHaveAttribute("aria-busy", "true");
  await expect(submit).not.toHaveAttribute("aria-busy", "true", { timeout: 3000 });
  await expect(submit.locator(".studio-loader[data-loader-pending]")).toBeHidden();
});

test("the shown overlay is not aria-busy, so its Loading status is announced", async ({ page }) => {
  await page.goto("/lab/loader_visits");
  await page.waitForFunction(() => window.StudioLoader);
  await page.evaluate(() => window.StudioLoader.show(""));
  await expect(overlay(page)).toBeVisible();
  const status = overlay(page).getByRole("status");
  await expect(status).toHaveText("Loading");
  const busy = await status.evaluate((el) => { for (let n = el; n; n = n.parentElement) if (n.getAttribute("aria-busy") === "true") return n.className; return null; });
  expect(busy, "an aria-busy ancestor mutes the status").toBeNull();
});
