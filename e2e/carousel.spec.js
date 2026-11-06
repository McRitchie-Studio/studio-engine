const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] studio/_carousel in a real browser (/lab/carousel): the widths the container
// queries give, the arrows, dots and keys the controller drives, the reduced-motion
// scroll, the glass arrows, and a carousel whose controller never loads. Every claim
// is a box, a scroll position or a computed style, so the response bytes answer none.
//
// CONTROLS, each run against this file with the lab server restarted:
//   - "carousel" removed from LAZY: 10 red. Every spec waits for the controller,
//     and the failed-load spec's mark is never set without its import.
//   - --carousel-peek set to 0: 2 red, the wide and phone widths.

const DESKTOP = { width: 1280, height: 900 };
const PHONE = { width: 390, height: 844 };
const LAB = "/lab/carousel";

const region = (page, name) => page.locator(`section[data-lab='${name}']`);
const track = (page, name) => region(page, name).locator(".carousel-track");

async function open(page, viewport = DESKTOP) {
  await page.setViewportSize(viewport);
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto(LAB);
  await expect(region(page, "apps")).toHaveAttribute("data-carousel-ready", "");
  return errors;
}

const box = (locator) => locator.evaluate((el) => {
  const r = el.getBoundingClientRect();
  return { width: r.width, left: r.left };
});

const scrollLeft = (locator) => locator.evaluate((el) => el.scrollLeft);

// The row rests once two frames agree.
async function settled(locator) {
  let last = -1;
  await expect.poll(async () => {
    const now = await scrollLeft(locator);
    const same = now === last;
    last = now;
    return same;
  }, { intervals: [100, 100, 150, 200, 250] }).toBe(true);
  return last;
}

test("a wide row shows three slides and a sliver of the fourth", async ({ page }) => {
  const errors = await open(page);
  const row = track(page, "apps");
  const rowWidth = (await box(row)).width;
  const slides = row.locator(".carousel-slide");
  const slide = (await box(slides.nth(0))).width;
  const gap = 16;

  // n * w + n * gap + peek * w = row, with n = 3 and peek = 0.2
  expect(Math.abs(slide - (rowWidth - 3 * gap) / 3.2)).toBeLessThan(1.5);
  const fourth = await box(slides.nth(3));
  const rowLeft = (await box(row)).left;
  expect(fourth.left - rowLeft).toBeLessThan(rowWidth);
  expect(fourth.left - rowLeft + fourth.width).toBeGreaterThan(rowWidth);
  expect(errors).toEqual([]);
});

test("a phone row shows one slide and a sliver of the next", async ({ page }) => {
  await open(page, PHONE);
  const row = track(page, "apps");
  const rowWidth = (await box(row)).width;
  const slide = (await box(row.locator(".carousel-slide").first())).width;

  expect(Math.abs(slide - (rowWidth - 16) / 1.2)).toBeLessThan(1.5);
});

test("the first paint rests at the start: prev off, next on, the end faded", async ({ page }) => {
  await open(page);
  const apps = region(page, "apps");

  await expect(apps.getByRole("button", { name: "Previous slides" })).toHaveAttribute("aria-disabled", "true");
  await expect(apps.getByRole("button", { name: "Next slides" })).toHaveAttribute("aria-disabled", "false");
  await expect(track(page, "apps")).toHaveAttribute("data-fade-end", "");
  await expect(track(page, "apps")).not.toHaveAttribute("data-fade-start", "");
  // Nine slides, three to a view: seven stops, so two dots are hidden.
  await expect(apps.locator(".carousel-dot:visible")).toHaveCount(7);
  await expect(apps.locator(".carousel-dot[aria-current='true']")).toHaveAttribute("data-carousel-index", "0");
});

test("a standard row still opens on its first slide: no start mark, no scroll", async ({ page }) => {
  await open(page);
  const apps = region(page, "apps");
  await expect(apps).not.toHaveAttribute("data-carousel-start", /.*/);
  await expect(apps.locator("[data-carousel-start-slide]")).toHaveCount(0);
  expect(await settled(track(page, "apps"))).toBe(0);
});

test("a standard row's caption is a small styled line under every slide", async ({ page }) => {
  await open(page);
  const captions = region(page, "captioned").locator(".carousel-slide > .carousel-caption");
  await expect(captions).toHaveCount(5);
  const look = await captions.first().evaluate((el) => {
    const s = getComputedStyle(el);
    return { size: s.fontSize, top: s.marginTop, opacity: s.opacity };
  });
  expect(look).toEqual({ size: "14px", top: "8px", opacity: "1" });
  for (const i of [0, 1, 2]) await expect(captions.nth(i)).toBeVisible();
});

test("next moves a page, prev comes back, and the status says where", async ({ page }) => {
  await open(page);
  const apps = region(page, "apps");
  const row = track(page, "apps");
  const fourth = await row.locator(".carousel-slide").nth(3).evaluate((el) => el.offsetLeft - el.parentElement.firstElementChild.offsetLeft);

  await apps.getByRole("button", { name: "Next slides" }).click();
  expect(Math.abs((await settled(row)) - fourth)).toBeLessThan(2);
  await expect(apps.locator("[role='status']")).toHaveText("Slides 4 to 6 of 9");
  await expect(apps.getByRole("button", { name: "Previous slides" })).toHaveAttribute("aria-disabled", "false");
  await expect(row).toHaveAttribute("data-fade-start", "");
  await expect(apps.locator(".carousel-dot[aria-current='true']")).toHaveAttribute("data-carousel-index", "3");

  await apps.getByRole("button", { name: "Previous slides" }).click();
  expect(await settled(row)).toBeLessThan(2);
  await expect(apps.getByRole("button", { name: "Previous slides" })).toHaveAttribute("aria-disabled", "true");
});

test("End reaches the last stop and turns next off; a dot goes to its slide", async ({ page }) => {
  await open(page);
  const apps = region(page, "apps");
  const row = track(page, "apps");

  await row.focus();
  await page.keyboard.press("End");
  const max = await row.evaluate((el) => el.scrollWidth - el.clientWidth);
  expect(Math.abs((await settled(row)) - max)).toBeLessThan(2);
  await expect(apps.getByRole("button", { name: "Next slides" })).toHaveAttribute("aria-disabled", "true");
  await expect(row).not.toHaveAttribute("data-fade-end", "");
  await expect(apps.locator("[role='status']")).toHaveText("Slides 7 to 9 of 9");

  await page.keyboard.press("Home");
  expect(await settled(row)).toBeLessThan(2);

  await apps.getByRole("button", { name: "Go to slide 3" }).click();
  const third = await row.locator(".carousel-slide").nth(2).evaluate((el) => el.offsetLeft - el.parentElement.firstElementChild.offsetLeft);
  expect(Math.abs((await settled(row)) - third)).toBeLessThan(2);
});

test("the arrow keys move a row of plain slides from its focused track", async ({ page }) => {
  await open(page);
  const row = track(page, "quotes");

  await expect(region(page, "quotes").locator(".carousel-slide").first()).toHaveAttribute("aria-label", "Quote One");
  await row.focus();
  await page.keyboard.press("ArrowRight");
  expect(await settled(row)).toBeGreaterThan(10);
  await page.keyboard.press("ArrowLeft");
  expect(await settled(row)).toBeLessThan(2);
});

test("a focused track shows a ring on its region, where the edge mask cannot clip it", async ({ page }) => {
  await open(page);
  await track(page, "apps").focus();
  const ring = await region(page, "apps").evaluate((el) => getComputedStyle(el).outlineStyle);
  expect(ring).toBe("solid");
});

test("an arrow key with a modifier is the browser's, not the row's", async ({ page }) => {
  await open(page);
  const row = track(page, "quotes");
  await row.focus();
  await page.keyboard.press("Alt+ArrowRight");
  expect(await settled(row)).toBeLessThan(2);
});

test("a row that fits shows no controls", async ({ page }) => {
  await open(page);
  await expect(region(page, "pair")).toHaveAttribute("data-carousel-static", "");
  await expect(region(page, "pair").locator(".carousel-controls")).toBeHidden();
});

test("under reduced motion the track jumps instead of gliding", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await open(page);
  const row = track(page, "apps");

  expect(await row.evaluate((el) => getComputedStyle(el).scrollBehavior)).toBe("auto");
  await region(page, "apps").getByRole("button", { name: "Next slides" }).click();
  // No glide: the very next frame already rests past the start.
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(resolve)));
  expect(await scrollLeft(row)).toBeGreaterThan(100);
});

test("under the glass surfaces the arrows take the glass fill, light and dark", async ({ page }) => {
  await open(page);
  const arrow = region(page, "apps").getByRole("button", { name: "Next slides" });
  const fill = () => arrow.evaluate((el) => getComputedStyle(el).backgroundColor);
  // The lab may start dark; the fill transitions nothing, so one read is enough.
  await page.evaluate(() => document.documentElement.classList.remove("dark"));
  const solid = await fill();

  await page.evaluate(() => { document.documentElement.dataset.surfaceStyle = "glass"; });
  const glassLight = await fill();
  await page.evaluate(() => document.documentElement.classList.add("dark"));
  const glassDark = await fill();

  expect(glassLight).not.toBe(solid);
  expect(glassLight).not.toBe(glassDark);
  for (const color of [glassLight, glassDark]) {
    expect(color, "a translucent fill").toMatch(/\/\s*0?\.\d+\)|rgba\(.*,\s*0?\.\d+\)/);
  }
});

test("a carousel whose controller never loads still scrolls, with its controls hidden", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await blockOffsiteRequests(page);
  await page.route(/carousel_controller.*\.js/, (route) => route.abort());
  await page.goto(LAB);
  const apps = region(page, "apps");

  await expect(apps).toHaveAttribute("data-studio-controller-failed", /carousel/);
  await expect(apps).not.toHaveAttribute("data-carousel-ready", "");
  await expect(apps.locator(".carousel-controls")).toBeHidden();
  expect(await track(page, "apps").evaluate((el) => getComputedStyle(el).scrollbarWidth)).toBe("thin");
  await track(page, "apps").evaluate((el) => { el.scrollLeft = 200; });
  expect(await settled(track(page, "apps"))).toBeGreaterThan(100);
});
