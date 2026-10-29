const { test, expect } = require("@playwright/test");

// [e2e] A data-turbo="false" submit, then Back (studio/loader, docs/LOADER.md):
// the restored page has no busy button and no overlay.
//
// WHY ITS OWN FILE. Without the bfcache, Back reloads the page fresh, the stuck
// state cannot happen, and the spec would pass on nothing. Playwright launches
// Chromium with --disable-back-forward-cache, and its default headless shell
// refuses the cache anyway (BackForwardCacheDisabledForDelegate). So this file
// runs the full Chromium build in new headless mode (`channel: "chromium"`,
// which `npx playwright install chromium` installs beside the shell) without
// that flag. Both are launch options, so top level: they force their own
// worker. The spec asserts the restore really came from the cache. It goes
// Back through history.back(): page.goBack() waits for a load event that a
// bfcache restore never fires.
//
// CONTROL: drop the pagehide and pageshow settle() listeners in
// installStudioLoader and this spec fails, the submit still aria-busy.

test.use({ channel: "chromium", launchOptions: { ignoreDefaultArgs: ["--disable-back-forward-cache"] } });

const overlay = (page) => page.locator("[data-studio-loader-overlay]");

test("a data-turbo=false submit, then Back, leaves no busy button and no overlay", async ({ page }) => {
  await page.goto("/lab/loader_visits");
  await page.evaluate(() => { window.__restored = false; addEventListener("pageshow", (e) => { if (e.persisted) window.__restored = true; }); });
  await page.locator('[data-test="plain-submit"]').click();
  await expect(page).toHaveURL(/ms=300/);

  await page.evaluate(() => history.back());
  await expect(page).toHaveURL(/\/lab\/loader_visits$/);
  expect(await page.evaluate(() => window.__restored), "Back restored the page from the bfcache").toBe(true);
  const submit = page.locator('[data-test="plain-submit"]');
  await expect(submit).not.toHaveAttribute("aria-busy", "true");
  await expect(submit.locator(".studio-loader[data-loader-pending]")).toBeHidden();
  await expect(overlay(page)).toBeHidden();
});
