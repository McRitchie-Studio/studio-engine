const { test, expect, devices } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] studio/_carousel, style: :cascade, in a real browser (/lab/carousel_cascade):
// the open card in front at full size, two each side stepping back (smaller, dimmer,
// deeper, under it), the rest hidden; and that stack follows the arrows, the dots,
// the keys, a click on a side card, keyboard focus, a drag, a loop and autoplay. A
// phone (390px, device emulation: headless Chromium will not resize under 500px)
// shows one each side; reduced motion lays the stack flat and swaps at once. Each
// claim is a computed style or a box, read once every slide's transition has ended
// (document.getAnimations() is empty): no sleeps.
//
// CONTROLS, each run against this file with the lab server restarted (2026-11-08):
//   - the controller's syncCascade step write removed: every move spec red (the
//     open card never changes).
//   - clickSide's preventDefault removed: the click-to-centre spec red (the hash
//     follows the side card's link).
//   - the narrow-region @container block removed: the phone spec red (five in view).
//   - the reduced-motion block removed: the reduced-motion spec red (a 3D matrix).

const DESKTOP = { width: 1400, height: 900 };
const LAB = "/lab/carousel_cascade";

const region = (page, lab = "cascade") => page.locator(`section[data-lab='${lab}']`);
const slides = (page, lab) => region(page, lab).locator(".carousel-track > .carousel-slide");

async function open(page, { lab = "cascade", query = "", theme = "dark", reducedMotion = "no-preference" } = {}) {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion });
  const errors = watchPageErrors(page);
  await page.goto(LAB + query);
  // The lab layout is dark by default; light drops the class the head adds.
  if (theme === "light") await page.evaluate(() => document.documentElement.classList.remove("dark"));
  await expect(region(page, lab)).toHaveAttribute("data-carousel-ready", "");
  await region(page, lab).scrollIntoViewIfNeeded();
  await rest(page);
  return errors;
}

// Every transition and fade has ended.
async function rest(page) {
  await expect.poll(() => page.evaluate(() => document.getAnimations().length)).toBe(0);
}

// Each slide's look: its slot, whether it is open and showing, its box, its body's
// brightness, its caption's opacity, and whether it is 3D.
const looks = (page, lab = "cascade") => slides(page, lab).evaluateAll((all) => all.map((slide) => {
  const style = getComputedStyle(slide);
  const body = getComputedStyle(slide.querySelector(".carousel-cascade-body"));
  const caption = slide.querySelector(".carousel-caption");
  const box = slide.getBoundingClientRect();
  const bright = body.filter.match(/brightness\(([\d.]+)\)/);
  return {
    step: slide.getAttribute("data-cascade-step"),
    current: slide.hasAttribute("data-current"),
    shown: style.visibility === "visible" && parseFloat(style.opacity) > 0.9,
    z: parseInt(style.zIndex, 10),
    width: box.width,
    centre: box.left + box.width / 2,
    brightness: bright ? parseFloat(bright[1]) : 1,
    opacity: parseFloat(getComputedStyle(slide.querySelector(".carousel-cascade-body")).opacity),
    caption: caption ? parseFloat(getComputedStyle(caption).opacity) : null,
    threeD: style.transform.startsWith("matrix3d")
  };
}));

const openIndex = async (page, lab = "cascade") => (await looks(page, lab)).findIndex((look) => look.current);

// The stack open on `index`: that card in front, at the region's centre, full size and
// brightness with its caption; `reach` cards each side showing, smaller, dimmer and
// under it, each step further out; the rest hidden.
async function expectStackOn(page, index, { lab = "cascade", reach = 2 } = {}) {
  const all = await looks(page, lab);
  const box = await region(page, lab).boundingBox();
  const front = all[index];
  expect(front.current, `card ${index + 1} is open`).toBe(true);
  expect(front.shown).toBe(true);
  expect(Math.abs(front.centre - (box.x + box.width / 2)), "the open card sits at the centre").toBeLessThan(3);
  expect(front.brightness).toBe(1);
  expect(front.caption, "the open card shows its caption").toBeGreaterThan(0.98);
  all.forEach((look, i) => {
    if (i === index) return;
    expect(look.current, `card ${i + 1} is not open`).toBe(false);
    expect(look.caption, `card ${i + 1} hides its caption`).toBeLessThan(0.02);
    const step = Number(look.step);
    if (Number.isInteger(step) && Math.abs(step) <= reach) {
      expect(look.shown, `card ${i + 1} (step ${step}) shows`).toBe(true);
      expect(look.width, `card ${i + 1} is smaller`).toBeLessThan(front.width * 0.95);
      expect(look.brightness, `card ${i + 1} is dimmer`).toBeLessThan(0.95);
      expect(look.z, `card ${i + 1} sits under the open card`).toBeLessThan(front.z);
      expect(Math.sign(look.centre - front.centre), `card ${i + 1} sits on its own side`).toBe(Math.sign(step));
    } else {
      expect(look.shown, `card ${i + 1} (step ${look.step}) is hidden`).toBe(false);
    }
  });
  // Each step out sits further aside and smaller than the one before it.
  for (const side of [-1, 1]) {
    const near = all.find((look) => look.step === String(side));
    const far = all.find((look) => look.step === String(2 * side));
    if (reach >= 2 && near && far) {
      expect(Math.abs(far.centre - front.centre)).toBeGreaterThan(Math.abs(near.centre - front.centre));
      expect(far.width).toBeLessThan(near.width);
    }
  }
  return all;
}

async function expectNoSideScroll(page) {
  const { inner, scroll } = await page.evaluate(() => ({ inner: window.innerWidth, scroll: document.documentElement.scrollWidth }));
  expect(scroll, "no horizontal page scroll").toBeLessThanOrEqual(inner);
}

// The lane's census counts bare test( declarations, so each theme is its own spec.
async function expectFiveInView(page, theme) {
    await page.setViewportSize(DESKTOP);
    const errors = await open(page, { theme });
    expect(await page.evaluate(() => document.documentElement.classList.contains("dark"))).toBe(theme === "dark");
    expect(await page.evaluate(() => window.innerWidth)).toBe(1400);
    const all = await expectStackOn(page, 3);
    expect(all.map((look) => look.step)).toEqual(["before", "-2", "-1", "0", "1", "2", "after"]);
    expect(all.filter((look) => look.shown)).toHaveLength(5);
    expect(all[3].threeD || all[4].threeD, "the stack is laid out in 3D").toBe(true);
    // The centre of the open card is the open card: nothing lies over it.
    const hit = await page.evaluate(() => {
      const card = document.querySelector("section[data-lab='cascade'] [data-current] [data-lab-card]");
      const box = card.getBoundingClientRect();
      return document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)?.closest("[data-lab-card]")?.dataset.labCard;
    });
    expect(hit).toBe("4");
    await expect(region(page).locator(".carousel-dot:visible")).toHaveCount(7);
    await expectNoSideScroll(page);
    expect(errors).toEqual([]);
}

test("dark: five in view, the middle card in front and on top, the rest hidden", async ({ page }) => {
  await expectFiveInView(page, "dark");
});

test("light: five in view, the middle card in front and on top, the rest hidden", async ({ page }) => {
  await expectFiveInView(page, "light");
});

test("the arrows and the dots move the stack, and the status line says where", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  const status = region(page).locator("[role='status']");

  await region(page).getByRole("button", { name: "Next slide", exact: true }).click();
  await rest(page);
  await expectStackOn(page, 4);
  await expect(status).toHaveText("Slide 5 of 7");
  await expect(region(page).locator(".carousel-dot").nth(4)).toHaveAttribute("aria-current", "true");

  await region(page).getByRole("button", { name: "Go to slide 7" }).click();
  await rest(page);
  await expectStackOn(page, 6);
  await expect(status).toHaveText("Slide 7 of 7");
  await expect(region(page).getByRole("button", { name: "Next slide", exact: true })).toHaveAttribute("aria-disabled", "true");

  await region(page).getByRole("button", { name: "Previous slide", exact: true }).click();
  await rest(page);
  await expectStackOn(page, 5);
});

test("the keys move the stack: arrows, Home and End", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  await region(page).locator(".carousel-track").focus();

  await page.keyboard.press("ArrowLeft");
  await rest(page);
  await expectStackOn(page, 2);
  await page.keyboard.press("End");
  await rest(page);
  await expectStackOn(page, 6);
  await page.keyboard.press("Home");
  await rest(page);
  await expectStackOn(page, 0);
  await expect(region(page).getByRole("button", { name: "Previous slide", exact: true })).toHaveAttribute("aria-disabled", "true");
  await page.keyboard.press("ArrowRight");
  await rest(page);
  await expectStackOn(page, 1);
});

test("a click on a side card brings it to the front and opens nothing; a click on the front card opens it", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  const side = slides(page).nth(5);
  const box = await side.boundingBox();

  // The outer edge of the far card, clear of the card over it.
  await page.mouse.click(box.x + box.width - 12, box.y + box.height / 3);
  await rest(page);
  await expectStackOn(page, 5);
  expect(new URL(page.url()).hash, "the side card's link was not followed").toBe("");
  await expect(region(page).locator("[role='status']")).toHaveText("Slide 6 of 7");

  await slides(page).nth(5).locator("[data-lab-card]").click();
  await expect.poll(() => new URL(page.url()).hash).toBe("#cascade-open-6");
});

test("Tab into a side card brings it to the front, and Tab walks the set", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  await region(page).locator(".carousel-track").focus();

  // The first card's link is hidden (past the window), so Tab lands on the first
  // card in view, two left of the open one.
  await page.keyboard.press("Tab");
  await expect(slides(page).nth(1).locator("a")).toBeFocused();
  await rest(page);
  await expectStackOn(page, 1);
  await page.keyboard.press("Tab");
  await expect(slides(page).nth(2).locator("a")).toBeFocused();
  await rest(page);
  await expectStackOn(page, 2);
});

test("a card holding focus that leaves the window hands focus to the track", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  await slides(page).nth(3).locator("a").focus();
  await page.keyboard.press("End");
  await rest(page);
  await expectStackOn(page, 6);
  await expect(region(page).locator(".carousel-track")).toBeFocused();
});

test("a drag moves the stack after the pointer, and opens nothing", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  const box = await slides(page).nth(3).boundingBox();
  const y = box.y + box.height / 2;

  await page.mouse.move(box.x + box.width / 2, y);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 - 60, y, { steps: 4 });
  await expect(region(page)).toHaveAttribute("data-carousel-dragging", "");
  await page.mouse.move(box.x + box.width / 2 - 140, y, { steps: 4 });
  await page.mouse.up();
  await rest(page);
  await expectStackOn(page, 4);
  expect(new URL(page.url()).hash, "the drag followed no link").toBe("");
  await expect(region(page)).not.toHaveAttribute("data-carousel-dragging", "");
});

test("a looping cascade wraps both ways round the set, with no clones", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page, { lab: "cascade-loop" });
  const all = await expectStackOn(page, 0, { lab: "cascade-loop" });
  expect(all.map((look) => look.step)).toEqual(["0", "1", "2", "after", "before", "-2", "-1"]);
  await expect(region(page, "cascade-loop").locator("[data-carousel-clone]")).toHaveCount(0);
  const prev = region(page, "cascade-loop").getByRole("button", { name: "Previous slide", exact: true });
  await expect(prev).toHaveAttribute("aria-disabled", "false");

  await prev.click();
  await rest(page);
  await expectStackOn(page, 6, { lab: "cascade-loop" });
  await region(page, "cascade-loop").getByRole("button", { name: "Next slide", exact: true }).click();
  await rest(page);
  await region(page, "cascade-loop").getByRole("button", { name: "Next slide", exact: true }).click();
  await rest(page);
  await expectStackOn(page, 1, { lab: "cascade-loop" });
});

test("visible: 3 shows one card each side", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page, { lab: "cascade-three" });
  const all = await expectStackOn(page, 0, { lab: "cascade-three", reach: 1 });
  expect(all.filter((look) => look.shown)).toHaveLength(2);
  await region(page, "cascade-three").getByRole("button", { name: "Next slide", exact: true }).click();
  await rest(page);
  expect((await expectStackOn(page, 1, { lab: "cascade-three", reach: 1 })).filter((look) => look.shown)).toHaveLength(3);
});

test("autoplay moves a looping cascade, and the pointer over it holds it", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page, { lab: "cascade-loop", query: "?autoplay=1" });
  await page.mouse.move(2, 2);
  await expect(region(page, "cascade-loop")).toHaveAttribute("data-carousel-playing", "");
  await expect.poll(() => openIndex(page, "cascade-loop"), { timeout: 4000 }).toBe(1);

  const box = await slides(page, "cascade-loop").nth(1).boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await expect(region(page, "cascade-loop")).not.toHaveAttribute("data-carousel-playing", "");
  await expect(region(page, "cascade-loop").getByRole("button", { name: "Pause slideshow" })).toBeVisible();
});

test("a phone (390px) shows one card each side, with no horizontal page scroll", async ({ browser }) => {
  const context = await browser.newContext({ ...devices["iPhone 13"] });
  const page = await context.newPage();
  try {
    const errors = await open(page);
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    const all = await expectStackOn(page, 3, { reach: 1 });
    expect(all.filter((look) => look.shown)).toHaveLength(3);
    await expectNoSideScroll(page);

    // A swipe moves it.
    const box = await slides(page).nth(3).boundingBox();
    const y = box.y + box.height / 2;
    await page.mouse.move(box.x + box.width - 10, y);
    await page.mouse.down();
    await page.mouse.move(box.x + 20, y, { steps: 6 });
    await page.mouse.up();
    await rest(page);
    await expectStackOn(page, 4, { reach: 1 });
    await expectNoSideScroll(page);
    expect(errors).toEqual([]);
  } finally {
    await context.close();
  }
});

test("under reduced motion the stack lays flat and swaps at once", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page, { reducedMotion: "reduce" });
  const all = await looks(page);
  const front = all[3];
  expect(all.every((look) => !look.threeD), "no 3D transform").toBe(true);
  expect(all[4].width, "no step scales").toBeCloseTo(front.width, 0);
  expect(all[4].opacity, "the neighbour is only dimmed").toBeLessThan(0.6);
  // Side by side, not overlapping.
  expect(all[4].centre - front.centre).toBeGreaterThanOrEqual(front.width);

  await region(page).getByRole("button", { name: "Next slide", exact: true }).click();
  // No transition: the moment the press lands, nothing animates and card 5 is open.
  expect(await page.evaluate(() => document.getAnimations().length)).toBe(0);
  const after = await looks(page);
  expect(after[4].current).toBe(true);
  const box = await region(page).boundingBox();
  expect(Math.abs(after[4].centre - (box.x + box.width / 2))).toBeLessThan(3);
  await expectNoSideScroll(page);
});
