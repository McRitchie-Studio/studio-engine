const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The branded loader (docs/LOADER.md) on /lab/loader.
//
// WHY THE BROWSER. The markup is the same whether any loader moves, takes its
// brand's colours, or stands still for a reader who asked for less motion; each
// of those is a computed style. And the overlay's show and hide are a program.
//
//   1. Each picked style renders, and its moving part is animating.
//   2. The colours come from the theme the card sets, not a hex in the engine.
//   3. Reduced motion: every loader is a still icon (no animation, no moving part).
//   4. A pending loader shows inside a busy button, in the button's text colour.
//   5. window.StudioLoader shows and hides the page-load overlay.

const STYLES = { breathe: ".studio-loader-icon", liquid: ".studio-loader-fill", orbit: ".studio-loader-orb",
                 steel: ".studio-loader-icon", "weld-bead": ".studio-loader-bead", sparkle: ".studio-loader-sparkle" };

function stageLoader(page, style) {
  return page.locator(`[data-test="loader-stage"] .studio-loader[data-loader-style="${style}"]`);
}

test("every picked style renders on its brand and its moving part animates", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto("/lab/loader");

  for (const [style, part] of Object.entries(STYLES)) {
    const loader = stageLoader(page, style);
    await expect(loader, style).toHaveCount(1);
    const box = await loader.boundingBox();
    expect(Math.round(box.width), `${style} is 96px`).toBe(96);
    const animation = await loader.locator(part).first().evaluate((el) => getComputedStyle(el).animationName);
    expect(animation, `${style} animates its ${part}`).toMatch(/studio-loader-/);
  }
  expect(errors).toEqual([]);
});

test("the loader takes its colours from the theme the page sets", async ({ page }) => {
  await page.goto("/lab/loader");
  const colours = await stageLoader(page, "orbit").evaluate((el) => {
    const style = getComputedStyle(el);
    return { color: style.getPropertyValue("--studio-loader-color").trim(), hot: style.getPropertyValue("--studio-loader-hot").trim() };
  });
  // The welding card sets --color-primary #2D5E8E and --color-accent #F08A5A.
  expect(colours.color.toLowerCase()).toBe("#2d5e8e");
  expect(colours.hot.toLowerCase()).toBe("#f08a5a");
});

test.describe("under reduced motion", () => {
  test("every loader is a still icon", async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto("/lab/loader");
    const moving = await page.evaluate(() =>
      [...document.querySelectorAll(".studio-loader, .studio-loader *")]
        .filter((el) => getComputedStyle(el).animationName !== "none")
        .map((el) => el.className.baseVal ?? el.className));
    expect(moving).toEqual([]);

    for (const part of [".studio-loader-orb", ".studio-loader-art", ".studio-loader-halo"]) {
      const shown = await page.locator(`[data-test="loader-stage"] ${part}`).evaluateAll((els) => els.filter((el) => getComputedStyle(el).display !== "none").length);
      expect(shown, `${part} is not drawn`).toBe(0);
    }
    await expect(stageLoader(page, "sparkle").locator("img.studio-loader-icon")).toBeVisible();
  });
});

test("a pending loader shows inside a busy button, in the button's text colour", async ({ page }) => {
  await page.goto("/lab/loader");
  const pending = page.locator('button[aria-busy="true"] .studio-loader[data-loader-pending]').first();
  await expect(pending).toBeVisible();
  const look = await pending.locator(".studio-loader-icon").evaluate((el) => ({
    background: getComputedStyle(el).backgroundColor,
    text: getComputedStyle(el.closest("button")).color
  }));
  expect(look.background).toBe(look.text);

  await page.evaluate(() => document.querySelectorAll("button[aria-busy]").forEach((b) => b.removeAttribute("aria-busy")));
  await expect(pending).toBeHidden();
});

test("StudioLoader shows and hides the page-load overlay", async ({ page }) => {
  await page.goto("/lab/loader");
  const overlay = page.locator("[data-studio-loader-overlay]");
  await expect(overlay).toBeHidden();

  await page.evaluate(() => window.StudioLoader.show("Building your page…"));
  await expect(overlay).toBeVisible();
  await expect(overlay.locator("[data-studio-loader-caption]")).toHaveText("Building your page…");
  await expect(overlay).toHaveAttribute("data-state", "shown");
  await expect(overlay.locator('.studio-loader[data-loader-style="sparkle"]')).toBeVisible();

  await page.evaluate(() => window.StudioLoader.hide());
  await expect(overlay).toBeHidden();
});
