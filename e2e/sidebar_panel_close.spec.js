const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] THE SHARED PANEL'S CLOSE BUTTON BELONGS TO THE PANEL THAT RENDERED IT.
//
// components/_sidebar_panel is shared — the link sidebar renders through it, and so
// does any host panel — and it stamps every close button `data-link-sidebar-close`.
// components/_link_sidebar's bridge claims that attribute on the DOCUMENT, in the
// CAPTURE phase, with stopImmediatePropagation. Unscoped, it claimed a host panel's ×
// as well: the click never reached that panel's own @click, so the button did nothing
// at all — no error, no console line, no failing assertion anywhere.
//
// WHY ONLY A BROWSER CAN SEE IT. Both panels render byte-identically whether the
// bridge is scoped or not; the defect is entirely in which listener runs first at
// click time. Every server-side tier passed while the button was dead — measured
// 2026-09-18 in the hub, where a /deployments sidebar's × left the panel open and the
// hub had to ship a close button of its own.
//
// The two halves are a pair on purpose: scoping the bridge must free the host panel's
// button WITHOUT taking the link sidebar's own close with it.

test("a host panel's close button closes that panel, and leaves the link sidebar alone", async ({ page }) => {
  const pageErrors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/sidebar_panels");

  const host = page.locator("#lab-host-panel");
  const linkSidebar = page.locator("#studio-link-sidebar");
  await expect(page.locator("[data-test='lab-body']")).toBeVisible();
  await expect(host).toBeHidden();

  await page.locator("[data-test='open-host-panel']").click();
  await expect(host).toBeVisible();

  // The × the SHARED partial rendered for this panel — the same attribute the link
  // sidebar's bridge listens for.
  await host.locator("[data-link-sidebar-close]").click();

  await expect(host).toBeHidden();
  // …and the click must not have been spent on the other sidebar: it was never open,
  // and closing a host panel is no reason to open it.
  await expect(linkSidebar).toBeHidden();
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("the link sidebar's own close button still closes the link sidebar", async ({ page }) => {
  const pageErrors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/sidebar_panels");

  const linkSidebar = page.locator("#studio-link-sidebar");
  const host = page.locator("#lab-host-panel");
  await expect(page.locator("[data-test='lab-body']")).toBeVisible();

  // The trigger the navbar renders — the bridge's other claimed control.
  await page.locator("[data-link-sidebar-trigger]").first().click();
  await expect(linkSidebar).toBeVisible();

  await linkSidebar.locator("[data-link-sidebar-close]").first().click();

  await expect(linkSidebar).toBeHidden();
  await expect(host).toBeHidden();
  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
