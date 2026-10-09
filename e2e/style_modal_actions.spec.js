const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The style guide's Modals section on its controller (style-modals) and
// on the engine's own modal stack.
//
// e2e/style_modal_simulators.spec.js drives the demos by name. This file
// presses the BUTTONS: each carries a Stimulus action in place of an inline
// handler, and a button whose action names nothing does nothing, with no error
// anywhere. It also holds the two things the section's wiring rests on: only
// the style guide fetches the section's modules, and $store.dsModals is the
// stack studio/modal_host builds.
//
// CONTROLS, each run against this file:
//   - remove data-studio-controller="style-modals" from the section: the
//     first three specs fail, the buttons opening nothing.
//   - remove the modal-host attributes from the overlay's template: the two
//     specs that open a card and the store's own spec fail, $store.dsModals
//     undefined.

const GUIDE_MODULES = /\/studio\/(style_guide|style_modals|controllers\/style_modals_controller)\.js(?:\?|$)/;

const stack = (page) =>
  page.evaluate(() => Alpine.store("dsModals").stack.map((entry) => ({ id: entry.id, state: entry.props.state })));

test("a stack demo's button opens the guide's vehicle through its action", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/style_modals");
  expect(await stack(page)).toEqual([]);

  await page.locator("#modals-stack-mechanics button", { hasText: "Dismissible processing" }).click();
  await expect.poll(() => stack(page)).toEqual([{ id: "ds-stack-demo", state: "processing" }]);
  await expect(page.locator('[role="dialog"]')).toBeVisible();

  await page.keyboard.press("Escape");
  await expect.poll(() => stack(page)).toEqual([]);
  expect(errors).toEqual([]);
});

test("every demo button names a driver the controller has", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/style_modals");

  const wiring = await page.evaluate(() =>
    [...document.querySelectorAll('#modals [data-studio-action="click->style-modals#demo"]')].map((button) => ({
      name: button.getAttribute("data-style-modals-name-param"),
      known: typeof window.dsModalDemos[button.getAttribute("data-style-modals-name-param")] === "function"
    }))
  );

  expect(wiring.length).toBeGreaterThanOrEqual(12);
  expect(wiring.filter((button) => !button.known)).toEqual([]);
  expect(await page.locator("#modals [onclick]").count(), "a demo button still carries an inline handler").toBe(0);
});

test("the simulator's Open button opens the demo card on the chosen entrance", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/style_modals");

  await page.locator("#modal-anim-enter-select").selectOption("shake");
  await page.locator("#modals-motion-registry button", { hasText: /^Open$/ }).click();

  await expect
    .poll(() => page.evaluate(() => {
      const current = Alpine.store("dsModals").current();
      return current && { id: current.id, enterAnim: current.props.enterAnim };
    }))
    .toEqual({ id: "email-change-pending", enterAnim: "shake" });
});

test("the guide's store is the engine's stack, registered before Alpine reads it", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/style_modals");

  const api = await page.evaluate(() => {
    const store = Alpine.store("dsModals");
    return ["open", "swap", "advance", "close", "closeAll", "closeAllDismissible", "cardClasses", "isLive"]
      .filter((name) => typeof store[name] !== "function");
  });
  expect(api, "the guide's store is missing part of the stack's API").toEqual([]);
  expect(errors, "a binding read $store.dsModals before it was registered").toEqual([]);
});

test("only the style guide fetches the section's modules", async ({ page }) => {
  await blockOffsiteRequests(page);
  const fetched = [];
  page.on("request", (request) => { if (GUIDE_MODULES.test(request.url())) fetched.push(new URL(request.url()).pathname); });

  await page.goto("/lab/profile_edit");
  await page.waitForLoadState("networkidle");
  expect(fetched, "a page with no style guide on it fetched the guide's modules").toEqual([]);

  await page.goto("/lab/style_modals");
  await expect.poll(() => fetched.length).toBe(3);
});
