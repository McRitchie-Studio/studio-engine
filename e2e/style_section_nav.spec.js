const { test, expect } = require("@playwright/test");

// [e2e] The style guide's sticky row: the title and the tabs share it, and the
// highlight follows the section in view.
//
// CONTROLS, each run against this file:
//   - style-section-nav not registered in studio/style_guide: the second spec
//     fails, Theme stays highlighted however far the page scrolls.

const LAB = "/lab/style_nav";
const row = (page) => page.locator("nav[aria-label='Style guide sections']");
const current = (page) => row(page).locator("a[aria-current='true']");

test("the title and the tabs sit on one row", async ({ page }) => {
  await page.goto(LAB);
  const title = await row(page).locator("h1").boundingBox();
  const tab = await row(page).locator("a", { hasText: "Theme" }).boundingBox();

  const titleMiddle = title.y + title.height / 2;
  expect(titleMiddle).toBeGreaterThan(tab.y);
  expect(titleMiddle).toBeLessThan(tab.y + tab.height);
  expect(tab.x).toBeGreaterThan(title.x + title.width);
});

test("the highlight follows the scroll and a tab's own jump", async ({ page }) => {
  await page.goto(LAB);
  await expect(current(page)).toHaveText("Theme");

  await page.evaluate(() => {
    const top = document.getElementById("tricks").getBoundingClientRect().top;
    window.scrollBy({ top: top - 60, behavior: "instant" });
  });
  await expect(current(page)).toHaveText("Tricks");
  await expect(current(page)).toHaveClass(/btn-primary/);
  await expect(row(page).locator("a", { hasText: "Theme" })).toHaveClass(/btn-neutral/);
  await expect(row(page).locator("a", { hasText: "Theme" })).not.toHaveAttribute("aria-current", "true");

  await row(page).locator("a", { hasText: "Modals" }).click();
  await expect(current(page)).toHaveText("Modals");

  await row(page).locator("a", { hasText: "Components" }).click();
  await expect(current(page)).toHaveText("Components");

  // The row stays put under the top of the window.
  const box = await row(page).boundingBox();
  expect(box.y).toBeLessThan(200);
});
