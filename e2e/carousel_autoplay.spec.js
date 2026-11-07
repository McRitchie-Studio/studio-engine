const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] studio/_carousel with autoplay: and loop: in a real browser
// (/lab/carousel_autoplay, one-second intervals): the row advances on its own, a
// looping row wraps from its last slide to its first, and it holds still on hover,
// on keyboard focus, in a hidden tab, after a press, under reduced motion, and
// behind its pause button. Each claim is the open dot, a label or an attribute the
// controller sets, read in the browser.
//
// CONTROLS, each run against this file with the lab server restarted (2026-11-06):
//   - autoplayRunning() made to ignore its reasons: 6 red (hover, pause button,
//     keyboard focus, hidden tab, a press, reduced motion).
//   - targetStop()'s two loop wraps removed: 1 red, the looping arrows.
// A looping row of more than one slide is cloned round its seam (loop: true), so the
// specs count its real slides, [data-carousel-target='slide'], and every real slide
// of it is a stop. The loop's clones and seam are carousel_spotlight.spec.js's.

const DESKTOP = { width: 1280, height: 900 };
const LAB = "/lab/carousel_autoplay";

const region = (page, name) => page.locator(`section[data-lab='${name}']`);
const track = (page, name) => region(page, name).locator("> .carousel-track");
const toggle = (page, name) => region(page, name).locator("[data-carousel-target='toggle']");
const openDot = (page, name) => region(page, name).locator(".carousel-dot").evaluateAll(
  (dots) => dots.findIndex((dot) => dot.getAttribute("aria-current") === "true")
);

async function open(page, { reducedMotion = "no-preference" } = {}) {
  await page.setViewportSize(DESKTOP);
  await page.emulateMedia({ reducedMotion });
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto(LAB);
  await expect(region(page, "auto")).toHaveAttribute("data-carousel-ready", "");
  return errors;
}

// Whether a standard row rests with real slide `index` at its start, not a clone.
const restsOn = (page, name, index) => track(page, name).evaluate((el, i) => {
  const slide = el.querySelectorAll("[data-carousel-target='slide']")[i];
  return Math.abs(slide.offsetLeft - el.firstElementChild.offsetLeft - el.scrollLeft) <= 2;
}, index);

// Holds for `ms`: the open dot never leaves `index`.
async function holds(page, name, index, ms = 2500) {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    expect(await openDot(page, name)).toBe(index);
    await page.waitForTimeout(250);
  }
}

test("an autoplaying row advances one slide each interval, and says nothing", async ({ page }) => {
  const errors = await open(page);

  await expect(region(page, "auto")).toHaveAttribute("data-carousel-playing", "");
  expect(await openDot(page, "auto")).toBe(0);
  await expect.poll(() => openDot(page, "auto"), { timeout: 4000 }).toBe(1);
  await expect.poll(() => openDot(page, "auto"), { timeout: 4000 }).toBe(2);
  await expect(region(page, "auto").locator("[data-carousel-target='status']")).toHaveText("");
  expect(errors).toEqual([]);
});

test("a looping spotlight wraps from its last slide to its first, and centres it", async ({ page }) => {
  await open(page);
  const spot = region(page, "auto-spot");

  const real = spot.locator("[data-carousel-target='slide']");
  await expect(real.nth(4)).toHaveAttribute("data-current", "");
  await expect.poll(() => openDot(page, "auto-spot"), { timeout: 4000 }).toBe(0);
  await expect(real.nth(0)).toHaveAttribute("data-current", "");
  // The slide left of the first is a clone of the last.
  const before = await real.nth(0).evaluate((slide) => [slide.previousElementSibling?.hasAttribute("data-carousel-clone"), slide.previousElementSibling?.textContent.trim()]);
  expect(before[0]).toBe(true);
  expect(before[1]).toContain("Person 5");
  // Neither arrow is ever disabled on a looping row.
  await expect(spot.locator("[data-carousel-target='prev']")).toHaveAttribute("aria-disabled", "false");
  await expect(spot.locator("[data-carousel-target='next']")).toHaveAttribute("aria-disabled", "false");
});

test("the pointer over the slides holds the row, and leaving lets it go", async ({ page }) => {
  await open(page);
  await track(page, "auto").hover();
  await expect(region(page, "auto")).not.toHaveAttribute("data-carousel-playing", "");
  const at = await openDot(page, "auto");

  await holds(page, "auto", at);
  await page.mouse.move(5, 5);
  await expect.poll(() => openDot(page, "auto"), { timeout: 4000 }).not.toBe(at);
});

test("the pause button stops the row, and Play starts it again", async ({ page }) => {
  await open(page);
  const button = toggle(page, "auto");
  await expect(button).toHaveAccessibleName("Pause slideshow");

  await button.click();
  await page.mouse.move(5, 5);
  await expect(button).toHaveAccessibleName("Play slideshow");
  await expect(button).toHaveAttribute("data-carousel-stopped", "");
  await expect(button.locator(".carousel-autoplay-play")).toBeVisible();
  await expect(button.locator(".carousel-autoplay-pause")).toBeHidden();
  const at = await openDot(page, "auto");
  await holds(page, "auto", at);

  await button.click();
  await page.mouse.move(5, 5);
  await expect(button).toHaveAccessibleName("Pause slideshow");
  await expect.poll(() => openDot(page, "auto"), { timeout: 4000 }).not.toBe(at);
});

test("keyboard focus in the row holds it", async ({ page }) => {
  await open(page);
  await page.keyboard.press("Tab");
  await track(page, "auto").focus();
  await expect(region(page, "auto")).not.toHaveAttribute("data-carousel-playing", "");
  await holds(page, "auto", await openDot(page, "auto"), 2000);
});

test("a hidden tab holds the row", async ({ page }) => {
  await open(page);
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await expect(region(page, "auto")).not.toHaveAttribute("data-carousel-playing", "");
  await holds(page, "auto", await openDot(page, "auto"), 2000);

  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await expect(region(page, "auto")).toHaveAttribute("data-carousel-playing", "");
});

test("a press holds the row until the reader leaves it alone", async ({ page }) => {
  await open(page);
  const next = region(page, "auto").locator("[data-carousel-target='next']");

  await next.click();
  await page.mouse.move(5, 5);
  await expect(region(page, "auto")).not.toHaveAttribute("data-carousel-playing", "");
  // Next moves a page of three: from the first slide to the fourth, once it rests.
  const at = 3;
  await expect.poll(() => openDot(page, "auto")).toBe(at);
  await holds(page, "auto", at, 3000);
  // idleDelay: five seconds for a one-second row, then it moves again.
  await expect(region(page, "auto")).toHaveAttribute("data-carousel-playing", "", { timeout: 5000 });
  await expect.poll(() => openDot(page, "auto"), { timeout: 4000 }).not.toBe(at);
});

test("under reduced motion the row starts stopped, and Play starts it", async ({ page }) => {
  await open(page, { reducedMotion: "reduce" });
  const button = toggle(page, "auto");

  await expect(button).toHaveAccessibleName("Play slideshow");
  await expect(region(page, "auto")).not.toHaveAttribute("data-carousel-playing", "");
  await holds(page, "auto", 0, 2000);

  await button.click();
  await page.mouse.move(5, 5);
  await expect.poll(() => openDot(page, "auto"), { timeout: 4000 }).toBe(1);
});

test("a row that does not loop stops at its last slide", async ({ page }) => {
  await open(page);
  await region(page, "auto-end").scrollIntoViewIfNeeded();
  const button = toggle(page, "auto-end");
  const last = (await region(page, "auto-end").locator(".carousel-dot:not([hidden])").count()) - 1;

  await expect(button).toHaveAccessibleName("Play slideshow", { timeout: 8000 });
  expect(await openDot(page, "auto-end")).toBe(last);
  await expect(region(page, "auto-end").locator("[data-carousel-target='next']")).toHaveAttribute("aria-disabled", "true");
});

test("a looping row's arrows wrap at both ends and are never disabled", async ({ page }) => {
  await open(page);
  await region(page, "loop").scrollIntoViewIfNeeded();
  const row = region(page, "loop");
  const prev = row.locator("[data-carousel-target='prev']");
  const next = row.locator("[data-carousel-target='next']");
  const status = row.locator("[data-carousel-target='status']");
  // Every real slide is a stop, and the dots count the real slides only.
  await expect(row.locator(".carousel-dot:not([hidden])")).toHaveCount(6);

  await expect(prev).toHaveAttribute("aria-disabled", "false");
  await prev.click();
  await expect.poll(() => openDot(page, "loop")).toBe(3);
  await expect(next).toHaveAttribute("aria-disabled", "false");
  await expect(status).toHaveText("Slides 4 to 6 of 6");
  // The glide ran to the clones before the first, then jumped home to the real fourth.
  await expect.poll(() => restsOn(page, "loop", 3)).toBe(true);

  // Next from the last page glides on across the seam, never back across the row.
  await track(page, "loop").evaluate((el) => {
    window.__lefts = [];
    el.addEventListener("scroll", () => window.__lefts.push(el.scrollLeft), { passive: true });
  });
  await next.click();
  await expect.poll(() => openDot(page, "loop")).toBe(0);
  await expect(status).toHaveText("Slides 1 to 3 of 6");
  await expect.poll(() => restsOn(page, "loop", 0)).toBe(true);
  const lefts = await page.evaluate(() => window.__lefts);
  const back = lefts.findIndex((left, i) => i && left < lefts[i - 1] - 2);
  expect(back, "one jump home, after the glide").toBeGreaterThan(1);
  expect(lefts.slice(back + 1).every((left) => Math.abs(left - lefts[back]) <= 2), "and no glide after it").toBe(true);

  // A dot takes the short way round: from the first, slide five is two back.
  await row.getByRole("button", { name: "Go to slide 5" }).click();
  await expect.poll(() => openDot(page, "loop")).toBe(4);
  await expect(status).toHaveText("Slides 5 to 6 and 1 of 6");
  expect(await row.locator("[data-carousel-target='toggle']").count()).toBe(0);
});
