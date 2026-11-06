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
//   - move()'s `to === this.current` return removed: the end-press spec, its
//     cleared status line rewritten to "Slides 7 to 9 of 9".
//   - the key guard back on form fields alone: the widget spec, the slider's
//     ArrowRight moving the row.

const DESKTOP = { width: 1280, height: 900 };
const PHONE = { width: 390, height: 844 };
const LAB = "/lab/carousel";

const region = (page, name) => page.locator(`section[data-lab='${name}']`);
const track = (page, name) => region(page, name).locator("> .carousel-track");

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

test("the controls row keeps its room before the controller connects, so nothing below moves", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await blockOffsiteRequests(page);
  await page.route(/carousel_controller.*\.js/, async (route) => { await new Promise((r) => setTimeout(r, 800)); await route.continue(); });
  await page.goto(LAB, { waitUntil: "domcontentloaded" });
  const apps = region(page, "apps");
  await expect(apps).not.toHaveAttribute("data-carousel-ready", "");
  const before = await apps.evaluate((el) => el.getBoundingClientRect().height);
  await expect(apps).toHaveAttribute("data-carousel-ready", "");
  expect(await apps.evaluate((el) => el.getBoundingClientRect().height)).toBe(before);
});

const status = (page, name) => region(page, name).locator("> [role='status']");

test("the status line stays empty after the first paint and after a swipe", async ({ page }) => {
  await open(page);
  const row = track(page, "apps");

  await expect(status(page, "apps")).toHaveText("");
  // A swipe is a scroll the controller did not ask for: the row moves, the line stays quiet.
  await row.evaluate((el) => el.scrollTo({ left: 400, behavior: "auto" }));
  expect(await settled(row)).toBeGreaterThan(100);
  await expect(region(page, "apps").getByRole("button", { name: "Previous slides" })).toHaveAttribute("aria-disabled", "false");
  await expect(status(page, "apps")).toHaveText("");
});

test("an arrow pressed at its end scrolls nothing and announces nothing", async ({ page }) => {
  await open(page);
  const apps = region(page, "apps");
  const row = track(page, "apps");

  // aria-disabled keeps the arrow focusable and clickable, which Playwright reads as disabled.
  await apps.getByRole("button", { name: "Previous slides" }).click({ force: true });
  await row.focus();
  await page.keyboard.press("Home");
  await page.waitForTimeout(300);
  await expect(status(page, "apps")).toHaveText("");

  await page.keyboard.press("End");
  await settled(row);
  await expect(status(page, "apps")).toHaveText("Slides 7 to 9 of 9");
  // Clear the line, then press at the end: a press that goes nowhere writes nothing.
  await status(page, "apps").evaluate((el) => { el.textContent = ""; });
  await apps.getByRole("button", { name: "Next slides" }).click({ force: true });
  await row.focus();
  await page.keyboard.press("End");
  await page.waitForTimeout(300);
  await expect(status(page, "apps")).toHaveText("");
});

test("a widget that owns the arrow keys, or a nested carousel, keeps them", async ({ page }) => {
  await open(page);
  const widgets = region(page, "widgets");
  const row = track(page, "widgets");
  await expect(widgets).toHaveAttribute("data-carousel-ready", "");
  await expect(region(page, "inner")).toHaveAttribute("data-carousel-ready", "");
  // A real slider or tab list handles its own keys and cancels the browser's scroll;
  // this stands in for that script, so only the carousel could move the row.
  await page.evaluate(() => {
    for (const el of document.querySelectorAll("[data-lab-widget]")) {
      el.addEventListener("keydown", (event) => {
        if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) event.preventDefault();
      });
    }
  });

  for (const hook of ["slider", "tab"]) {
    await widgets.locator(`[data-lab-widget='${hook}']`).focus();
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("End");
    await page.waitForTimeout(300);
    expect(await scrollLeft(row), `a key in the ${hook} moved the row`).toBeLessThan(2);
    await row.evaluate((el) => el.scrollTo({ left: 0, behavior: "auto" }));
  }

  // The nested carousel's keys move the inner row, not the outer one.
  const inner = track(page, "inner");
  await inner.focus();
  await page.keyboard.press("ArrowRight");
  expect(await settled(inner)).toBeGreaterThan(10);
  expect(await settled(row)).toBeLessThan(2);
  await expect(status(page, "widgets")).toHaveText("");

  // The outer row still takes its own keys.
  await row.focus();
  await page.keyboard.press("ArrowRight");
  expect(await settled(row)).toBeGreaterThan(10);
});
