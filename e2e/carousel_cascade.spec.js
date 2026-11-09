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

test("Tab into a side card brings it to the front, and each Tab moves one card on", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  await region(page).locator(".carousel-track").focus();

  // The first card's link is hidden (past the window), so Tab skips it and lands on
  // the first card in view, two left of the open one. Shift+Tab reaches card 1 from
  // there: see "a cascade opened mid-row" below.
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

// -- cascade-carousel-polish -------------------------------------------------------
//
// CONTROLS, each run against this file with the lab server restarted (2026-11-08):
//   - clickSide reading the press record whatever event.detail says (the code on
//     accepted at dc5f72be): the stale-press spec red (Enter moves the stack to card
//     6 and follows no link).
//   - syncCascade's replay of a held jump mark removed: the seam double-move spec red
//     (one fade-in for two jumps).
//   - the narrow region's mask removed: the phone edge spec red.
//   - announceChange removed: every change-event spec red (no event).

// The change events the lab page logged (window.__carouselChanges), for one row.
const changes = (page, lab) => page.evaluate((lab) => window.__carouselChanges.filter((change) => change.lab === lab), lab);

test("a press on a side card released off the track leaves nothing behind: Enter on the front card follows its link", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  const box = await slides(page).nth(5).boundingBox();
  const track = await region(page).locator(".carousel-track").boundingBox();

  // Press the far card's outer edge, then leave the track straight down (no drag:
  // the pointer moves up and down, not across) and let go below it.
  await page.mouse.move(box.x + box.width - 12, box.y + box.height / 3);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width - 12, track.y + track.height + 120, { steps: 4 });
  await page.mouse.up();
  await rest(page);
  await expectStackOn(page, 3);
  expect(new URL(page.url()).hash).toBe("");

  // The front card's link, by keyboard: Enter is a click with no press (detail 0).
  await slides(page).nth(3).locator("a").focus();
  await page.keyboard.press("Enter");
  await expect.poll(() => new URL(page.url()).hash, "Enter on the front card follows its link").toBe("#cascade-open-4");
  await rest(page);
  await expectStackOn(page, 3);
});

test("a cascade opened mid-row: Tab moves forward from the first card in view, and Shift+Tab then reaches the card before it", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  // Card 1 sits past the window (hidden), so Tab from the track skips it.
  expect((await looks(page))[0].step).toBe("before");
  await region(page).locator(".carousel-track").focus();
  await page.keyboard.press("Tab");
  await expect(slides(page).nth(1).locator("a")).toBeFocused();
  await rest(page);
  await expectStackOn(page, 1);
  // Card 1 is now one step left, in view: Shift+Tab lands on it and opens it.
  await page.keyboard.press("Shift+Tab");
  await expect(slides(page).nth(0).locator("a")).toBeFocused();
  await rest(page);
  await expectStackOn(page, 0);
});

test("two seam moves in a row on a five-card loop each fade the crossing card in", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page, { lab: "cascade-five" });
  expect(await page.evaluate(() => window.innerWidth)).toBe(1400);
  // Every fade-in that starts, by card.
  await page.evaluate(() => {
    window.__fades = [];
    document.querySelector("section[data-lab='cascade-five'] .carousel-track").addEventListener("animationstart", (event) => {
      if (event.animationName === "carousel-cascade-in") window.__fades.push(event.target.getAttribute("aria-label"));
    });
  });
  const five = region(page, "cascade-five");
  // Five in a loop, all in view: Next takes card 4 (far left) round to the far right,
  // Previous takes it back. Both are seam moves for the same card.
  await five.getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__fades)).toEqual(["Five 4"]);
  await rest(page);
  await expectStackOn(page, 1, { lab: "cascade-five" });
  await five.getByRole("button", { name: "Previous slide", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__fades), "the second jump fades in too").toEqual(["Five 4", "Five 4"]);
  await rest(page);
  await expectStackOn(page, 0, { lab: "cascade-five" });
  // And a third, straight after the second, with no rest between.
  await five.getByRole("button", { name: "Next slide", exact: true }).click();
  await five.getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__fades)).toEqual(["Five 4", "Five 4", "Five 4", "Five 5"]);
  await rest(page);
  await expectStackOn(page, 2, { lab: "cascade-five" });
});

test("a phone fades the side cards at the track's edge instead of cutting them", async ({ browser }) => {
  const context = await browser.newContext({ ...devices["iPhone 13"] });
  const page = await context.newPage();
  try {
    await open(page);
    expect(await page.evaluate(() => window.innerWidth)).toBe(390);
    const edge = await region(page).evaluate((section) => {
      const track = section.querySelector(".carousel-track");
      const style = getComputedStyle(track);
      const box = track.getBoundingClientRect();
      const side = [...track.children].filter((slide) => ["-1", "1"].includes(slide.getAttribute("data-cascade-step")))
        .map((slide) => slide.getBoundingClientRect());
      return {
        mask: style.maskImage || style.webkitMaskImage,
        past: side.some((card) => card.left < box.left - 1 || card.right > box.right + 1)
      };
    });
    expect(edge.past, "a side card runs past the track's edge").toBe(true);
    expect(edge.mask, "the edge fades it").toContain("linear-gradient");
    expect(edge.mask, "transparent at the edge").toMatch(/^linear-gradient\(to right, (transparent|rgba\(0, 0, 0, 0\)), /);
    await expectNoSideScroll(page);
  } finally {
    await context.close();
  }
});

test("a wide stack keeps no edge mask", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  const mask = await region(page).locator(".carousel-track").evaluate((track) => {
    const style = getComputedStyle(track);
    return style.maskImage || style.webkitMaskImage;
  });
  expect(mask).toBe("none");
});

test("the change event fires once per move, after data-current moves, and not at load", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page);
  expect(await changes(page, "cascade"), "nothing at load").toEqual([]);

  await region(page).getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(() => changes(page, "cascade")).toEqual([{ lab: "cascade", index: 4, previous: 3, total: 7, slide: "Card 5", marked: true }]);
  await region(page).getByRole("button", { name: "Go to slide 1" }).click();
  await region(page).locator(".carousel-track").focus();
  await page.keyboard.press("End");
  // A press that goes nowhere fires nothing.
  await page.keyboard.press("End");
  await rest(page);
  // Card 6 sits left of the open card 7: its outer (left) edge, clear of the card over it.
  const box = await slides(page).nth(5).boundingBox();
  await page.mouse.click(box.x + 12, box.y + box.height / 3);
  await rest(page);
  expect((await changes(page, "cascade")).map(({ index, previous }) => [previous, index])).toEqual([[3, 4], [4, 0], [0, 6], [6, 5]]);

  // A looping row wraps once, to the real slide.
  await region(page, "cascade-loop").getByRole("button", { name: "Previous slide", exact: true }).click();
  await expect.poll(() => changes(page, "cascade-loop")).toEqual([{ lab: "cascade-loop", index: 6, previous: 0, total: 7, slide: "Loop 7", marked: true }]);
});

test("under reduced motion the change event still fires once per move", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page, { reducedMotion: "reduce" });
  await region(page).getByRole("button", { name: "Next slide", exact: true }).click();
  await region(page).getByRole("button", { name: "Next slide", exact: true }).click();
  expect((await changes(page, "cascade")).map(({ index }) => index)).toEqual([4, 5]);
});

// The other styles fire it too: the lab pages for them log nothing of their own, so
// the spec listens from before the page loads.
async function logChanges(page) {
  await page.addInitScript(() => {
    window.__carouselChanges = [];
    document.addEventListener("studio:carousel:change", ({ target, detail }) => {
      window.__carouselChanges.push({ lab: target.dataset.lab, index: detail.index, previous: detail.previous, marked: detail.slide.hasAttribute("data-current") });
    });
  });
}

test("a spotlight fires the change event once per slide, a looping one once round the seam", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await logChanges(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/carousel_spotlight");
  const spot = page.locator("section[data-lab='spot']");
  await expect(spot).toHaveAttribute("data-carousel-ready", "");
  expect(await changes(page, "spot")).toEqual([]);
  await spot.getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(() => changes(page, "spot")).toEqual([{ lab: "spot", index: 1, previous: 0, marked: true }]);

  const loop = page.locator("section[data-lab='spot-loop']");
  await loop.scrollIntoViewIfNeeded();
  await loop.getByRole("button", { name: "Previous slide", exact: true }).click();
  await expect.poll(() => changes(page, "spot-loop")).toEqual([{ lab: "spot-loop", index: 6, previous: 0, marked: true }]);
  // The glide rests on a copy, then jumps home: still one event.
  // During the glide a copy holds data-current; once the real card 7 holds it, the row
  // has jumped home.
  await expect(loop.locator(".carousel-slide[data-current]:not([data-carousel-clone])")).toHaveAttribute("aria-label", "Loop 7");
  await expect(loop).not.toHaveAttribute("data-carousel-wrapping", "");
  expect(await changes(page, "spot-loop")).toHaveLength(1);
});

test("a standard row fires the change event for the slide at its first stop", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await logChanges(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/carousel");
  const apps = page.locator("section[data-lab='apps']");
  await expect(apps).toHaveAttribute("data-carousel-ready", "");
  await apps.getByRole("button", { name: "Go to slide 4" }).click();
  await expect.poll(async () => (await changes(page, "apps")).at(-1)?.index).toBe(3);
  const seen = await changes(page, "apps");
  // Each slide the glide passes fires once, in order, and none twice.
  expect(seen.map(({ index }) => index)).toEqual([...new Set(seen.map(({ index }) => index))]);
  expect(seen.every(({ marked }) => marked === false), "a standard row marks no slide").toBe(true);
});

// THE IMAGE-ONLY PATTERN (the hub Portfolio): each card is its picture alone, the
// row draws no dots, the open card wears a ring, and one caption under the stack
// follows the open card on the change event.
async function expectImageOnlyPattern(page, { theme, width }) {
  const errors = await open(page, { lab: "cascade-portfolio", theme });
  expect(await page.evaluate(() => window.innerWidth)).toBe(width);
  const row = region(page, "cascade-portfolio");
  const stage = page.locator("[data-lab-stage='portfolio']");
  const captions = stage.locator("[data-carousel-caption]");
  await expect(row.locator(".carousel-dots"), "dots: false draws no dot group").toHaveCount(0);
  await expect(row.locator("button.carousel-dot")).toHaveCount(0);

  // The card is only the picture, filling it.
  const fill = await row.locator(".carousel-slide[data-current] [data-test='portfolio-card']").evaluate((card) => {
    const img = card.querySelector("img").getBoundingClientRect();
    const box = card.getBoundingClientRect();
    return { text: card.textContent.trim(), dw: Math.abs(img.width - box.width), dh: Math.abs(img.height - box.height) };
  });
  expect(fill).toEqual({ text: "", dw: expect.any(Number), dh: expect.any(Number) });
  expect(fill.dw).toBeLessThan(1);
  expect(fill.dh).toBeLessThan(1);

  const ringOf = (index) => slides(page, "cascade-portfolio").nth(index).locator("[data-test='portfolio-card']")
    .evaluate((card) => getComputedStyle(card).boxShadow);
  const shownCaption = async () => {
    await rest(page);
    return captions.evaluateAll((all) => all.map((caption, index) => ({
      index, current: caption.hasAttribute("data-current"), hidden: caption.getAttribute("aria-hidden"),
      shown: getComputedStyle(caption).visibility === "visible" && parseFloat(getComputedStyle(caption).opacity) > 0.98,
      top: caption.getBoundingClientRect().top
    })).filter((caption) => caption.shown));
  };

  const trackBottom = async () => (await row.locator(".carousel-track").boundingBox()).y + (await row.locator(".carousel-track").boundingBox()).height;
  let shown = await shownCaption();
  expect(shown.map(({ index }) => index), "one caption shows: the open card's").toEqual([0]);
  expect(shown[0].hidden).toBeNull();
  expect(shown[0].top, "the caption sits under the stack").toBeGreaterThanOrEqual(await trackBottom() - 1);
  expect(await ringOf(0), "the open card wears a ring").not.toBe("none");
  expect(await ringOf(1), "a side card wears none").toBe("none");

  await row.getByRole("button", { name: "Next slide", exact: true }).click();
  shown = await shownCaption();
  expect(shown.map(({ index }) => index), "the caption follows the open card").toEqual([1]);
  await expect(captions.nth(0)).toHaveAttribute("aria-hidden", "true");
  expect(await ringOf(1)).not.toBe("none");
  expect(await ringOf(0)).toBe("none");

  await row.getByRole("button", { name: "Previous slide", exact: true }).click();
  await row.getByRole("button", { name: "Previous slide", exact: true }).click();
  shown = await shownCaption();
  expect(shown.map(({ index }) => index), "round the seam too").toEqual([6]);
  await expectNoSideScroll(page);
  expect(errors).toEqual([]);
}

test("dark, 1400: the image-only pattern, no dots, a ring on the open card and one caption under the stack", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await expectImageOnlyPattern(page, { theme: "dark", width: 1400 });
});

test("light, 1400: the image-only pattern, no dots, a ring on the open card and one caption under the stack", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await expectImageOnlyPattern(page, { theme: "light", width: 1400 });
});

test("a phone (390px): the image-only pattern keeps its caption and ring", async ({ browser }) => {
  const context = await browser.newContext({ ...devices["iPhone 13"] });
  const page = await context.newPage();
  try {
    await expectImageOnlyPattern(page, { theme: "dark", width: 390 });
  } finally {
    await context.close();
  }
});

test("dots: false leaves no dot in the tab order: Tab goes from the cards to the arrows", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await open(page, { lab: "cascade-portfolio" });
  const row = region(page, "cascade-portfolio");
  await row.getByRole("button", { name: "Previous slide", exact: true }).focus();
  await page.keyboard.press("Shift+Tab");
  const focused = await page.evaluate(() => document.activeElement.className + "|" + (document.activeElement.getAttribute("aria-label") || ""));
  expect(focused).not.toContain("carousel-dot");
});

test("the style guide's image-only specimen moves its one caption with the open card", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto("/lab/style_nav");
  const stage = page.locator("[data-carousel-image-only-specimen]");
  const row = stage.locator("section.carousel");
  await expect(row).toHaveAttribute("data-carousel-ready", "");
  await row.scrollIntoViewIfNeeded();
  await expect(row.locator(".carousel-dots")).toHaveCount(0);
  const current = () => stage.locator("[data-carousel-caption][data-current]");
  await expect(current()).toHaveText(/Picture 1/);
  await row.getByRole("button", { name: "Next slide", exact: true }).click();
  await expect(current()).toHaveText(/Picture 2/);
  await expect(stage.locator("[data-carousel-caption]").first()).toHaveAttribute("aria-hidden", "true");
  await expect(row.locator(".carousel-slide[data-current] [role='img']")).toHaveAttribute("aria-label", "Picture 2");
  const ring = await row.locator(".carousel-slide[data-current] [role='img']").evaluate((card) => getComputedStyle(card).boxShadow);
  expect(ring, "the open picture wears a ring").not.toBe("none");
  expect(errors).toEqual([]);
});
