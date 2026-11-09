const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The UI primitives look the way their baselines say, at phone and desktop
// width, in light and dark.
//
// The unit tests (test/components/studio/*_component_test.rb) pin the markup each
// component promises: its classes, its aria, its data hooks. They cannot see what
// those classes paint. A btn-* utility that stops compiling, a token renamed in
// theme.css, a spinner that loses its colour on a filled tone: each leaves the
// markup exactly as it was. So this spec screenshots every specimen the style
// guide draws (style/_primitives, through the lab page /lab/ui_primitives) and
// compares it to a committed baseline, failing on drift.
//
// LINUX BASELINES ONLY. Fonts rasterise differently on macOS and Linux, so a
// baseline is only good on the platform that drew it. The baselines are the
// lane's own: drawn in the CI lane image (ghcr.io/mcritchie-studio/ci-rails),
// committed under e2e/ui_primitives_screenshots.spec.js-snapshots/ with the
// -chromium-linux suffix. Off Linux the pixels are not compared (see COMPARES).
// To update them after a deliberate visual change, see docs/E2E_LANE.md,
// "Screenshot baselines".
//
// CONTROLS, run against this file:
//   - btn-danger's fill changed in engine.css: button-tones and button-sizes fail.
//   - EmptyStateComponent's MESSAGE back on text-lg: both empty-state specimens fail.

const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };

// One per [data-specimen] block in style/_primitives. A specimen added there
// without a name here is caught by the census below.
const SPECIMENS = [
  "button-tones",
  "button-sizes",
  "button-states",
  "empty-state",
  "empty-state-action",
  "table",
  "table-empty",
];

// Off Linux the page still renders and the specimen list is still checked; only
// the pixel comparison waits for the lane, and the run's annotations say so. Not
// a skip: the lane refuses any spec that leaves its executed set.
const COMPARES = process.platform === "linux";

async function capture(page, viewport, theme) {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(viewport);
  await page.goto("/lab/ui_primitives");
  // The lab layout is dark; light is the same page with the class off.
  await page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), theme === "dark");
  await page.evaluate(() => document.fonts.ready);

  const found = await page.locator("[data-specimen]").evaluateAll((nodes) => nodes.map((n) => n.dataset.specimen));
  expect(found, "style/_primitives and SPECIMENS disagree").toEqual(SPECIMENS);
  expect(errors).toEqual([]);

  if (!COMPARES) {
    test.info().annotations.push({ type: "note", description: "screenshot baselines are Linux-only; compared in the lane (docs/E2E_LANE.md)" });
    return;
  }

  for (const name of SPECIMENS) {
    await expect(page.locator(`[data-specimen="${name}"]`)).toHaveScreenshot(`${name}-${viewport.width}-${theme}.png`, {
      animations: "disabled",
      // A few anti-aliased pixels at a glyph edge are not drift; a colour or a
      // size change moves thousands.
      maxDiffPixelRatio: 0.002,
    });
  }
}

test("the UI primitives match their baselines at phone width, light", async ({ page }) => {
  await capture(page, PHONE, "light");
});

test("the UI primitives match their baselines at phone width, dark", async ({ page }) => {
  await capture(page, PHONE, "dark");
});

test("the UI primitives match their baselines at desktop width, light", async ({ page }) => {
  await capture(page, DESKTOP, "light");
});

test("the UI primitives match their baselines at desktop width, dark", async ({ page }) => {
  await capture(page, DESKTOP, "dark");
});
