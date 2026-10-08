const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The link sidebar's open flag (studio/link_sidebar,
// $store.sidebars.linkTreeOpen) on a page that renders components/link_sidebar.
//
// What a browser shows and a unit test cannot: the panel's x-show reads the flag
// as Alpine walks the page, before Stimulus connects a controller; a Turbo visit
// brings a panel without a new alpine:init; and the trigger carries its own
// Alpine @click beside the document's capture handler, so a click that both
// handled would open the panel and close it again.
//
// CONTROLS, each run against this file and e2e/sidebar_panel_close.spec.js:
//   - drop claim(event) from the toggle in handleLinkSidebarClick: the trigger's
//     own @click toggles the flag back, and the first spec fails.
//   - drop the alpine:init registration: every spec that opens the panel fails
//     with Alpine's expression error.
//   - drop `javascript_import_module_tag "studio/link_sidebar"` from the head:
//     the failed-boot spec fails.
//   - drop the controller's connect, or its registration in studio/application:
//     the late-anchor spec fails.
// The module's outside click, its Escape key and its turbo:before-render
// registration each have a second cover on the page (the panel's own
// @click.outside and @keydown.escape, the controller's connect), so no spec here
// fails without them; test/javascript/link_sidebar.test.mjs holds each.

const BOOT_MODULE = /\/studio\/application(?:-[0-9a-f]+)?\.js(?:\?|$)/;

const panel = (page) => page.locator("#studio-link-sidebar");
const trigger = (page) => page.locator("[data-link-sidebar-trigger]").first();
const flag = (page) =>
  page.evaluate(() => {
    const sidebars = window.Alpine && window.Alpine.store("sidebars");
    return sidebars ? sidebars.linkTreeOpen : null;
  });

test("the trigger opens the sidebar once per click; Escape and an outside click close it", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/sidebar_panels");
  await expect(page.locator('template[data-studio-controller="link-sidebar"]')).toHaveCount(1);
  await expect(panel(page)).toBeHidden();
  expect(await flag(page)).toBe(false);

  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  await expect(trigger(page)).toHaveAttribute("aria-expanded", "true");

  await page.keyboard.press("Escape");
  await expect(panel(page)).toBeHidden();
  await expect(trigger(page)).toHaveAttribute("aria-expanded", "false");

  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  // A click inside the panel leaves it open.
  await panel(page).locator("h3").click();
  await expect(panel(page)).toBeVisible();
  await page.locator("[data-test='lab-body']").click();
  await expect(panel(page)).toBeHidden();

  // The trigger closes what it opened.
  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  await trigger(page).click();
  await expect(panel(page)).toBeHidden();
  expect(errors).toEqual([]);
});

test("a page with no link sidebar has no sidebars store; a Turbo visit to one that has registers it", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);

  await page.goto("/lab/toast_flash");
  await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
  await page.locator("[data-test='toast-flash-page']").click();
  await page.keyboard.press("Escape");
  expect(await flag(page), "a click and a key press register nothing").toBeNull();

  await page.evaluate(() => { window.__sameDocument = true; });
  await page.evaluate(() => window.Turbo.visit("/lab/sidebar_panels_turbo"));
  await expect(page.locator("[data-test='lab-body']")).toBeVisible();
  expect(await page.evaluate(() => window.__sameDocument), "a Turbo visit").toBe(true);
  expect(await flag(page)).toBe(false);
  await expect(panel(page)).toBeHidden();

  await trigger(page).click();
  await expect(panel(page)).toBeVisible();

  // Leave with the sidebar open; Back restores the page closed.
  await page.locator("[data-survey-lab-away]").click();
  await expect(page).toHaveURL(/site_footer\/terms/);
  await page.goBack();
  await expect(page.locator("[data-test='lab-body']")).toBeVisible();
  await expect(panel(page)).toBeHidden();
  expect(await flag(page)).toBe(false);

  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  expect(errors).toEqual([]);
});

test("a link sidebar anchor that arrives after load registers the flag through its controller", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/toast_flash");
  await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
  expect(await flag(page)).toBeNull();

  await page.evaluate(() => {
    const anchor = document.createElement("template");
    anchor.setAttribute("data-studio-controller", "link-sidebar");
    document.body.appendChild(anchor);
  });

  await expect.poll(() => flag(page)).toBe(false);
  expect(errors).toEqual([]);
});

test("the sidebar opens and closes when the boot fails to load", async ({ page }) => {
  await blockOffsiteRequests(page);
  const aborted = [];
  await page.route((url) => BOOT_MODULE.test(url.pathname + url.search), (route) => {
    aborted.push(route.request().url());
    return route.abort();
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    if (BOOT_MODULE.test(message.location().url || "")) return;
    errors.push(`console.error: ${message.text()}`);
  });

  await page.goto("/lab/sidebar_panels");
  await expect(page.locator("[data-test='lab-body']")).toBeVisible();
  expect(aborted.length, "studio/application was never requested, so nothing failed").toBeGreaterThan(0);
  expect(await page.evaluate(() => typeof window.navCollapse), "the boot did fail").toBe("undefined");
  expect(await flag(page)).toBe(false);

  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
  await page.locator("[data-test='lab-body']").click();
  await expect(panel(page)).toBeHidden();
  expect(errors).toEqual([]);
});
