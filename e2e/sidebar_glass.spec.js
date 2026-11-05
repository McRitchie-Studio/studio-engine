const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The glass link sidebar (Studio.sidebar_style = :glass): where the panel sits, what its
// rows draw, a hover that moves nothing, and both ways it closes.
//
// CONTROLS, each red for its reason: padding-top back on the frame (the top-corners spec); the blur
// moved to the aside or removed (the shell spec); edge left on (the shell spec); a portrait left
// at the host's 20px (the column spec); --glass-row-height below 32px (the hover spec);
// pointer-events left on the frame (the inset spec); width: 100% dropped at the phone's
// breakpoint (the phone spec).

const panel = (page) => page.locator("#studio-link-sidebar");
const phonePanel = (page) => page.locator("#studio-link-sidebar-mobile");
const shell = (scope) => scope.locator("[data-sidebar-glass-shell]");
const trigger = (page) => page.locator("[data-link-sidebar-trigger]:visible").first();
const row = (scope, label) => scope.locator("nav a", { hasText: label });

const openGlass = async (page) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/sidebar_panels?glass=1&signed_in=1&admin=1");
  await page.waitForFunction(() => window.Alpine);
  await trigger(page).click();
  await page.waitForTimeout(450);
};

test("the shell holds the blur, the frame slides, and the old edge is off", async ({ page }) => {
  const errors = watchPageErrors(page);
  await openGlass(page);

  await expect(panel(page)).toHaveAttribute("data-sidebar-glass", "");
  await expect(panel(page)).not.toHaveAttribute("data-sidebar-edge", /.*/);
  expect(await panel(page).evaluate((el) => getComputedStyle(el).backdropFilter)).toBe("none");
  expect(await shell(panel(page)).evaluate((el) => getComputedStyle(el).backdropFilter)).toContain("blur(24px)");
  expect(errors).toEqual([]);
});

// The lab has no navbar, so this reads the frame: its top is where a real navbar's bottom edge
// is, from --nav-bottom and data-pin-edge. The shell starts exactly there.
test("the shell starts at the frame's top with square top corners, and keeps its other insets", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await openGlass(page);

  const fit = await page.evaluate(() => {
    const frame = document.querySelector("#studio-link-sidebar");
    const el = frame.querySelector("[data-sidebar-glass-shell]");
    const box = el.getBoundingClientRect();
    const css = getComputedStyle(el);
    return {
      top: box.top - frame.getBoundingClientRect().top,
      right: innerWidth - box.right,
      bottom: innerHeight - box.bottom,
      topRadius: css.borderTopLeftRadius,
      bottomRadius: css.borderBottomLeftRadius,
    };
  });
  expect(fit).toEqual({ top: 0, right: 12, bottom: 12, topRadius: "0px", bottomRadius: "18px" });
});

test("a line icon replaces the swap, an app keeps its portrait and rocket, and they share a column", async ({ page }) => {
  await openGlass(page);
  const scope = panel(page);

  await expect(row(scope, "Terms").locator("[data-sidebar-row-icon] svg")).toHaveCount(1);
  await expect(row(scope, "Terms").locator(".studio-emoji-swap")).toHaveCount(0);
  await expect(row(scope, "Team Voice").locator(".studio-emoji-swap-hover")).toHaveText("🚀");
  await expect(row(scope, "Unknown icon")).toContainText("🔒");

  const portrait = await row(scope, "Team Voice").locator("img").boundingBox();
  const icon = await row(scope, "Terms").locator("svg").boundingBox();
  expect(portrait.x).toBe(icon.x);
  expect(portrait.width).toBe(icon.width);
});

test("the row for this page is marked, and only that row", async ({ page }) => {
  await openGlass(page);

  await expect(panel(page).locator('a[aria-current="page"]')).toHaveCount(1);
  await expect(panel(page).locator('a[aria-current="page"]')).toContainText("This page");
});

test("a hover moves no row and keeps both lines inside the row", async ({ page }) => {
  await openGlass(page);
  const tops = () => panel(page).locator("nav a").evaluateAll((rows) => rows.map((el) => el.getBoundingClientRect().top));
  const before = await tops();

  await row(panel(page), "Terms").hover();
  await page.waitForTimeout(500);

  expect(await tops()).toEqual(before);
  const fit = await row(panel(page), "Terms").evaluate((el) => {
    const box = el.getBoundingClientRect();
    const label = el.querySelector("[data-sidebar-row-label]").getBoundingClientRect();
    const desc = el.querySelector("[data-sidebar-row-desc]");
    return { above: label.top - box.top, below: box.bottom - desc.getBoundingClientRect().bottom, shown: getComputedStyle(desc).opacity };
  });
  expect(fit.shown).toBe("1");
  expect(fit.above).toBeGreaterThanOrEqual(5);
  expect(fit.below).toBeGreaterThanOrEqual(5);
});

test("a long name truncates inside its row", async ({ page }) => {
  await openGlass(page);
  const fit = await row(panel(page), "Team Voice").evaluate((el) => {
    const label = [...el.querySelectorAll("span")].pop();
    return { over: label.scrollWidth > label.clientWidth, inside: label.getBoundingClientRect().right <= el.getBoundingClientRect().right };
  });
  expect(fit).toEqual({ over: true, inside: true });
});

test("a click in the inset closes it, and it opens again in place", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await openGlass(page);
  const box = await shell(panel(page)).boundingBox();

  await page.mouse.click(box.x + box.width + 6, box.y + 200);
  await expect(panel(page)).toBeHidden();

  await trigger(page).click();
  await page.waitForTimeout(450);
  expect((await panel(page).boundingBox()).x).toBe(1280 - 312);
  expect(await panel(page).getAttribute("class")).not.toMatch(/translate-x/);
});

test("the two themes each carry their own ink", async ({ page }) => {
  await openGlass(page);
  const ink = () => shell(panel(page)).evaluate((el) => getComputedStyle(el).color);

  await page.evaluate(() => document.documentElement.classList.remove("dark"));
  const light = await ink();
  await page.evaluate(() => document.documentElement.classList.add("dark"));
  expect(await ink()).not.toBe(light);
});

test.describe("on a phone", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("an 8px inset at the sides and bottom, no sideways overflow", async ({ page }) => {
    await blockOffsiteRequests(page);
    await page.goto("/lab/sidebar_panels?glass=1&signed_in=1&admin=1");
    await page.waitForFunction(() => window.Alpine);
    await page.evaluate(() => { window.Alpine.store("sidebars").linkTreeOpen = true; });
    await page.waitForTimeout(450);

    const fit = await page.evaluate(() => {
      const box = document.querySelector("#studio-link-sidebar-mobile [data-sidebar-glass-shell]").getBoundingClientRect();
      return { left: box.left, right: innerWidth - box.right, bottom: innerHeight - box.bottom, wide: document.documentElement.scrollWidth <= innerWidth };
    });
    expect(fit).toEqual({ left: 8, right: 8, bottom: 8, wide: true });
    await expect(phonePanel(page)).toBeVisible();
  });
});

test("the default style keeps the drawer and its edge", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/sidebar_panels?sidebar=1");
  await page.waitForFunction(() => window.Alpine);

  await expect(panel(page)).toHaveAttribute("data-sidebar-edge", "");
  await expect(panel(page)).not.toHaveAttribute("data-sidebar-glass", /.*/);
  await expect(panel(page).locator("[data-sidebar-row-icon]")).toHaveCount(0);
});
