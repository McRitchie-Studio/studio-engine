const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// The booking primitives (studio/booking/_frame, _popup, _assets;
// docs/SITE_FOOTER.md).
//
// WHY A BROWSER TIER EARNS ITS PLACE HERE. The frame's URL waits in data-src and
// an inline script assigns src only after the window's `load` event, once the
// frame is near the viewport: a third-party frame that starts loading earlier
// holds `load` open for as long as Google takes to answer. The integration tier
// can see data-src in the markup. Only a browser shows the script moving it to
// src, and when. The crop that opens on focus and the dialog that opens in place
// are the same kind of fact.
//
// GOOGLE IS STUBBED. These specs are about WHEN the frame is asked for, and must
// not depend on whether a runner can reach calendar.google.com. Everything else
// off-origin is refused (blockOffsiteRequests), the stub is registered after it,
// and Playwright runs the last route registered first.

const frame = (page) => page.locator("iframe[data-booking-frame]");
const dialog = (page) => page.locator("dialog[data-booking-dialog]");

async function stubGoogle(page) {
  const asked = [];
  await blockOffsiteRequests(page);
  await page.route("https://calendar.google.com/**", (route) => {
    asked.push(route.request().url());
    return route.fulfill({
      contentType: "text/html",
      // 300px down: inside the window the cropped frame shows, so it can be clicked.
      body: "<p id='stub' style='margin-top:300px'>booking stub</p>",
    });
  });
  return asked;
}

test("a frame below the fold asks Google only once it is scrolled to", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 600 });
  const asked = await stubGoogle(page);
  await page.goto("/lab/site_footer/home");

  // `load` has fired (goto waits for it) and the frame is far below the fold.
  await expect(frame(page)).toHaveCount(1);
  expect(await frame(page).getAttribute("src")).toBeNull();
  // One more beat, so an observer that fired on arming would be seen.
  await page.waitForTimeout(300);
  expect(await frame(page).getAttribute("src")).toBeNull();
  expect(asked).toEqual([]);

  await frame(page).scrollIntoViewIfNeeded();
  await expect(frame(page)).toHaveAttribute("src", /calendar\.google\.com\/calendar\/appointments\/schedules\/.+gv=true$/);
  await expect(page.frameLocator("iframe[data-booking-frame]").locator("#stub")).toHaveText("booking stub");
  expect(asked).toHaveLength(1);
});

test("a frame already in view still waits for the window's load event", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const asked = await stubGoogle(page);

  // Hold `load` open on a subresource of the page (the footer's logo). An image
  // does not delay DOMContentLoaded, so the frame's script has already run.
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let holding = false;
  await page.route("**/e2e/img/nav-logo.png", async (route) => {
    holding = true;
    await held;
    return route.continue();
  });

  await page.goto("/lab/site_footer/schedule", { waitUntil: "domcontentloaded" });
  await expect(frame(page)).toBeInViewport();
  await expect.poll(() => holding).toBe(true);

  // NOT VACUOUS: the document really is short of `load`, and the frame is in view.
  expect(await page.evaluate(() => document.readyState)).not.toBe("complete");
  await page.waitForTimeout(300);
  expect(await frame(page).getAttribute("src")).toBeNull();
  expect(asked).toEqual([]);

  release();
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);
  expect(await page.evaluate(() => document.readyState)).toBe("complete");
  expect(asked).toHaveLength(1);
});

test("the frame fills its column", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer/schedule");

  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);
  // The lab column is 56rem (896px) less its side padding and the frame's border.
  const box = await frame(page).boundingBox();
  expect(box.width).toBeGreaterThanOrEqual(820);
  expect(box.width).toBeLessThanOrEqual(896);
});

test("the frame is cropped to the slot picker at rest and opens fully once it is used", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer/schedule");
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);

  const wrap = page.locator("[data-booking-wrap]");
  const heights = () =>
    wrap.evaluate((el) => [el.clientHeight, el.querySelector("iframe").offsetHeight,
                           parseInt(getComputedStyle(el.querySelector("iframe")).marginTop, 10)]);

  // At rest the wrapper shows a 414px window onto a 732px frame, 205px down it.
  expect(await heights()).toEqual([414, 732, -205]);
  await expect(wrap).not.toHaveClass(/is-open/);

  // A click inside the frame moves focus into it; the parent sees only a blur.
  await page.frameLocator("iframe[data-booking-frame]").locator("#stub").click();
  await expect(wrap).toHaveClass(/is-open/);
  await expect.poll(async () => await heights()).toEqual([732, 732, 0]);
});

test("below 640px nothing is cropped", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer/schedule");
  await expect(frame(page)).toHaveAttribute("src", /gv=true$/);

  const sizes = await page.locator("[data-booking-wrap]").evaluate((el) => {
    const inner = el.querySelector("iframe");
    return [el.clientHeight, inner.offsetHeight, parseInt(getComputedStyle(inner).marginTop, 10)];
  });
  expect(sizes).toEqual([1200, 1200, 0]);
});

test("a booking link opens the popup in place, centred, and Escape closes it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  const asked = await stubGoogle(page);
  await page.goto("/lab/site_footer");

  await expect(dialog(page)).toBeHidden();
  await page.waitForLoadState("load");
  expect(asked).toEqual([]);

  await page.locator("footer[data-site-footer] a[data-booking-popup]").click();

  // The visitor stays on the page; the dialog opens and only now asks Google.
  await expect(dialog(page)).toBeVisible();
  await expect(page).toHaveURL(/\/lab\/site_footer$/);
  await expect(page.frameLocator("iframe[data-booking-popup-frame]").locator("#stub")).toHaveText("booking stub");
  expect(asked).toHaveLength(1);
  expect(asked[0]).toMatch(/gv=true$/);
  expect(await dialog(page).evaluate((el) => el.matches(":modal"))).toBe(true);

  // Centred in the viewport. Tailwind's reset zeroes a dialog's margin, which is
  // what centres it, and the lab compiles that reset in as every consumer does.
  const box = await dialog(page).boundingBox();
  expect(Math.abs(box.x + box.width / 2 - 640)).toBeLessThanOrEqual(1);
  expect(Math.abs(box.y + box.height / 2 - 450)).toBeLessThanOrEqual(1);
  expect(box.width).toBe(960);

  await page.keyboard.press("Escape");
  await expect(dialog(page)).toBeHidden();

  // Opening it again does not ask Google a second time.
  await page.locator("footer[data-site-footer] a[data-booking-popup]").click();
  await expect(dialog(page)).toBeVisible();
  await page.locator("[data-booking-close]").click();
  await expect(dialog(page)).toBeHidden();
  expect(asked).toHaveLength(1);
});

test("a page's own booking link opens the same popup, and the backdrop closes it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer");

  await page.locator("a.lab-booking-link[data-booking-popup]").click();
  await expect(dialog(page)).toBeVisible();
  await expect(page).toHaveURL(/\/lab\/site_footer$/);

  // A click outside the panel lands on the dialog element itself (its backdrop).
  await page.mouse.click(20, 20);
  await expect(dialog(page)).toBeHidden();
});

test("with no dialog on the page, or on a modified click, the link's href is the fallback", async ({ page, context }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer");
  const link = page.locator("footer[data-site-footer] a[data-booking-popup]");
  await expect(link).toHaveAttribute("href", "/lab/site_footer/schedule");

  // A modified click is left to the browser: a new tab on the booking page, and
  // no dialog here.
  const [tab] = await Promise.all([context.waitForEvent("page"), link.click({ modifiers: ["ControlOrMeta"] })]);
  await tab.waitForLoadState("domcontentloaded");
  expect(new URL(tab.url()).pathname).toBe("/lab/site_footer/schedule");
  await expect(dialog(page)).toBeHidden();
  await tab.close();

  // No dialog (a page that renders booking links and no popup): the link is a link.
  await dialog(page).evaluate((el) => el.remove());
  await link.click();
  await expect(page.locator("[data-lab-page='schedule']")).toBeVisible();
  await expect(page).toHaveURL(/\/lab\/site_footer\/schedule$/);
});

test("the popup still opens after a Turbo visit, and is not restored open", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await stubGoogle(page);
  await page.goto("/lab/site_footer");
  await page.evaluate(() => { window.__sameDocument = true; });

  await page.locator("footer[data-site-footer] a[href='/lab/site_footer/terms']").click();
  await expect(page.locator("[data-lab-page='terms']")).toBeVisible();
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);

  // The click handler is delegated from document, so the new body's link works.
  await page.locator("footer[data-site-footer] a[data-booking-popup]").click();
  await expect(dialog(page)).toBeVisible();
  await expect(page).toHaveURL(/\/lab\/site_footer\/terms$/);

  // Leave with the dialog open, then come back to the snapshot: it must be shut.
  await page.evaluate(() => window.Turbo.visit("/lab/site_footer"));
  await expect(page.locator("[data-lab-page='index']")).toBeVisible();
  await page.goBack();
  await expect(page.locator("[data-lab-page='terms']")).toBeVisible();
  await expect(dialog(page)).toBeHidden();
});
