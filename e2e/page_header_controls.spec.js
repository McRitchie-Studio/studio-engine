const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests, expectStickyChromeIsLive } = require("./helpers");

// [e2e] studio/_page_header's four kinds of right-side control (docs/PAGE_HEADER.md,
// "The four kinds of control"): tabs or anchors, the quick-links menu, the one action
// and the tools. Alex McRitchie, 2026-11-06: the /deployments header showed a grey
// pill, a purple button and a black button side by side, three looks for one row.
//
// Every claim here is a box, a computed style or a focus, so no markup test can
// answer it.
//
// CONTROLS, each run against this file with the lab server restarted:
//   - .btn-sm dropped from the menu button: 1 red, the one height.
//   - the cluster's order changed (action before menu): 1 red, the fixed order.
//   - popover="auto" changed to "manual": 1 red, Escape no longer closes the list.
//   - the anchor-positioning block removed from .page-header-menu-list: 1 red, the
//     list sits at the screen's corner, not under the button.
//   - connectMenus not called: 1 red, aria-expanded never set.

const DESKTOP = { width: 1280, height: 800 };
const LAB = "/lab/page_header_kinds";
const row = (page) => page.locator(".page-header");

const box = (locator) => locator.evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, height: r.height };
});

test("the four kinds share one control height and stand in one fixed order", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(LAB);
  await expectStickyChromeIsLive(page, expect);

  const tab = row(page).locator(".page-header-tab").first();
  const menu = row(page).locator(".page-header-menu-button");
  const action = row(page).locator(".page-header-action");
  const tool = row(page).locator(".page-header-tools button");
  const boxes = await Promise.all([tab, menu, action, tool].map(box));

  const heights = boxes.map((b) => Math.round(b.height));
  expect(new Set(heights).size, `heights ${heights.join(", ")}`).toBe(1);
  expect(heights[0]).toBeGreaterThan(20);
  // One line, left to right: the pills, the menu, the action, the tools.
  for (let i = 1; i < boxes.length; i++) {
    expect(boxes[i].left, `control ${i} is right of control ${i - 1}`).toBeGreaterThanOrEqual(boxes[i - 1].right);
    expect(Math.abs(boxes[i].top - boxes[0].top)).toBeLessThan(1);
  }
  // The menu is neutral and the action is primary: two looks, not three.
  const fill = (locator) => locator.evaluate((el) => getComputedStyle(el).backgroundColor);
  expect(await fill(menu)).not.toBe(await fill(action));
  // The tools are muted.
  expect(Number(await row(page).locator(".page-header-tools").evaluate((el) => getComputedStyle(el).opacity))).toBeLessThan(1);

  // Anchors are the same pill group, at the same height.
  await page.goto(`${LAB}?pills=anchors`);
  const anchorHeight = Math.round((await box(row(page).locator(".page-header-tab").first())).height);
  expect(anchorHeight).toBe(heights[0]);
  expect(errors).toEqual([]);
});

test("the quick-links menu opens and closes by keyboard and gives focus back", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(LAB);
  await expectStickyChromeIsLive(page, expect);

  const button = row(page).locator(".page-header-menu-button");
  const list = row(page).locator(".page-header-menu-list");
  await expect(button).toHaveAttribute("aria-expanded", "false");
  await expect(list).toBeHidden();

  await button.focus();
  await page.keyboard.press("Enter");
  await expect(list).toBeVisible();
  await expect(button).toHaveAttribute("aria-expanded", "true");

  // It hangs under the button, its right edge on the button's.
  const b = await box(button);
  const l = await box(list);
  expect(l.top).toBeGreaterThanOrEqual(b.bottom);
  expect(l.top - b.bottom).toBeLessThan(12);
  expect(Math.abs(l.right - b.right)).toBeLessThan(2);

  // Tab walks into the list's links.
  await page.keyboard.press("Tab");
  await expect(list.locator("a").first()).toBeFocused();

  await page.keyboard.press("Escape");
  await expect(list).toBeHidden();
  await expect(button).toHaveAttribute("aria-expanded", "false");
  await expect(button).toBeFocused();

  // ArrowDown opens it and lands on the first link; a click outside closes it.
  await page.keyboard.press("ArrowDown");
  await expect(list).toBeVisible();
  await expect(list.locator("a").first()).toBeFocused();
  await page.mouse.click(40, 700);
  await expect(list).toBeHidden();
  await expect(button).toHaveAttribute("aria-expanded", "false");
  expect(errors).toEqual([]);
});

test("an anchor scrolls to its section on this page, with no visit", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(`${LAB}?pills=anchors`);
  await expectStickyChromeIsLive(page, expect);

  await page.evaluate(() => { window.__noVisit = "same document"; });
  const documents = [];
  page.on("request", (request) => { if (request.resourceType() === "document" || request.resourceType() === "fetch") documents.push(request.url()); });

  await row(page).locator(".page-header-tab", { hasText: "Buttons" }).click();
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(500);
  await expect.poll(() => page.evaluate(() => Math.round(document.getElementById("buttons").getBoundingClientRect().top))).toBeLessThan(300);
  expect(new URL(page.url()).hash).toBe("#buttons");
  expect(await page.evaluate(() => window.__noVisit)).toBe("same document");
  expect(documents.filter((url) => url.includes("page_header_kinds"))).toEqual([]);
  expect(errors).toEqual([]);
});
