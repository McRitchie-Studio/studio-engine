const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The page-specific controllers studio/stimulus registers lazily, in a
// real browser: each is fetched by the page that names it and by no other, and
// one that fails to load leaves its element marked, never silently dead.
//
// These controllers carry what used to be inline scripts on their pages (the
// geo preview, the link preview card, the email banner scale, the booking frame
// and popup, the footer map, the survey stepper). A lazy controller is one more
// request, and a browser never fetches a failed module again in the same
// document (e2e/lazy_controller_failure.spec.js), so the failure has to be a
// state the page shows: data-studio-controller-failed on the element, which the
// stylesheet turns into a notice.
//
// CONTROLS, each run against this file:
//   - remove "geo-settings" from LAZY in app/javascript/studio/stimulus.js: the
//     first spec fails at the geo page (the controller is never fetched) and
//     the second at the mark.
//   - import studio/controllers/geo_settings_controller statically from
//     studio/stimulus: the first spec fails at the page that names none, which
//     now fetches it, and the second at the mark (the aborted import takes the
//     Stimulus application with it).

// identifier -> the lab page that names it. Module URLs are /e2e/modules/...
const PAGES = [
  ["geo-settings", "/lab/geo_settings", "geo_settings_controller"],
  ["link-preview-card", "/lab/site_identity", "link_preview_card_controller"],
  ["email-banner-scale", "/lab/email_banner_frames", "email_banner_scale_controller"],
  ["booking", "/lab/site_footer/schedule", "booking_controller"],
  ["footer-map", "/lab/site_footer", "footer_map_controller"],
  ["survey", "/surveys/first-game", "survey_controller"]
];

const CONTROLLER = /\/studio\/controllers\/([a-z_]+_controller)(?:-[0-9a-f]+)?\.js(?:\?|$)/;
const PAGE_CONTROLLERS = PAGES.map(([, , file]) => file);

// Every page-controller module the page asks for, by file name.
function watchControllers(page) {
  const asked = [];
  page.on("request", (request) => {
    const match = CONTROLLER.exec(new URL(request.url()).pathname);
    if (match && PAGE_CONTROLLERS.includes(match[1])) asked.push(match[1]);
  });
  return asked;
}

test("each lazily registered page controller is fetched by its own page, and by no page that names none", async ({ page }) => {
  await blockOffsiteRequests(page);
  const asked = watchControllers(page);

  for (const [identifier, path, file] of PAGES) {
    asked.length = 0;
    await page.goto(path);
    const element = page.locator(`[data-studio-controller~="${identifier}"]`).first();
    await expect(element, `${path} names no ${identifier} controller`).toHaveCount(1);
    await expect.poll(() => asked, `${path} never fetched ${file}`).toContain(file);
    await expect(element).not.toHaveAttribute("data-studio-controller-failed", /.*/);
  }

  // NOT VACUOUS: wait for `load` and one more beat, so a late fetch would be seen.
  asked.length = 0;
  await page.goto("/lab/bar_stack");
  await page.waitForLoadState("load");
  await page.waitForTimeout(300);
  expect(await page.locator("[data-studio-controller]").count(), "the control page renders no engine controller at all").toBeGreaterThan(0);
  expect(asked, "a page that names none of them fetched a page controller").toEqual([]);
});

test("a page controller whose module fails to load leaves its element marked, and the page usable", async ({ page }) => {
  await blockOffsiteRequests(page);
  const reports = [];
  const thrown = [];
  page.on("console", (message) => {
    if (message.type() === "error" && message.text().includes("[studio] the geo-settings controller failed to load")) reports.push(message.text());
  });
  page.on("pageerror", (error) => thrown.push(error.message));
  const aborted = [];
  const geoController = (url) => /\/studio\/controllers\/geo_settings_controller(?:-[0-9a-f]+)?\.js$/.test(url.pathname);
  await page.route(geoController, (route) => {
    aborted.push(route.request().url());
    return route.abort();
  });

  await page.goto("/lab/geo_settings");

  const geo = page.locator("[data-geo-page]");
  await expect(geo).toHaveAttribute("data-studio-controller-failed", "geo-settings");
  expect(aborted, "the controller's module was never requested, so nothing failed").toHaveLength(1);
  expect(reports).toHaveLength(1);
  expect(reports[0]).toContain("until the page is reloaded");
  expect(thrown).toEqual([]);

  // The live preview is what was lost: the root never learns a verdict.
  expect(await page.evaluate(() => document.documentElement.hasAttribute("data-geo-preview"))).toBe(false);

  // The editor is the page's own form and still works: a square ticks, paints
  // from its checkbox in CSS, and the form can be saved.
  const square = page.locator('.geo-grid label:has(input[value="WA"])');
  const ticked = await square.locator("input").isChecked();
  await square.click();
  await expect(square.locator("input")).toBeChecked({ checked: !ticked });
  await expect(page.locator('input[type="submit"][value="Save Settings"]')).toBeEnabled();

  // A full page load is the recovery.
  await page.unroute(geoController);
  await page.reload();
  await expect.poll(() => page.evaluate(() => document.documentElement.getAttribute("data-geo-preview"))).toMatch(/allowed|blocked/);
  await expect(geo).not.toHaveAttribute("data-studio-controller-failed", /.*/);
});
