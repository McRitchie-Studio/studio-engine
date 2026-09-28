const { test } = require("@playwright/test");

// THROWAWAY probe — deleted before commit.
test("PROBE: what toast_over_banner renders", async ({ page }) => {
  const out = [];
  for (const vp of [{ width: 390, height: 844 }, { width: 1280, height: 720 }]) {
    await page.setViewportSize(vp);
    await page.goto("/lab/toast_over_banner");
    await page.waitForFunction(() =>
      getComputedStyle(document.documentElement).getPropertyValue("--nav-h").trim() !== "");
    out.push(await page.evaluate((w) => ({
      viewport: w,
      triggers: document.querySelectorAll("[data-link-sidebar-trigger]").length,
      panels: document.querySelectorAll("#studio-link-sidebar, #studio-link-sidebar-mobile").length,
      navH: getComputedStyle(document.documentElement).getPropertyValue("--nav-h").trim()
    }), vp.width));
  }
  console.log("PROBE RESULT " + JSON.stringify(out));
});
