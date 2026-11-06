const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] studio/_carousel, style: :spotlight, in a real browser (/lab/carousel_spotlight):
// the centred slide is full size and colour with its caption showing, its neighbours
// smaller, faded and grey, and that state follows the arrows, the keys and a plain
// scroll. Under reduced motion nothing scales: the neighbours are only dimmed. Each
// claim is a computed style or a box, read once the row rests.
//
// Chromium runs the scroll-driven path (animation-timeline: view). The fallback path,
// the controller's data-current with a transition, is read in the same browser with
// the animation switched off by a test stylesheet, so both paths are asserted.
//
// CONTROLS, each run against this file with the lab server restarted (2026-11-05):
//   - the spotlight's `animation-timeline` line removed from engine.css: 6 red, every
//     scroll-driven spec (the slides lose the neighbour look, scale 1).
//   - the controller's data-current toggle removed: 8 red (no slide is marked).
//   - `scroll-snap-align: center` back to start: 8 red (the slide no longer centres).

const DESKTOP = { width: 1280, height: 900 };
const PHONE = { width: 390, height: 844 };
const LAB = "/lab/carousel_spotlight";

const region = (page) => page.locator("section[data-lab='spot']");
const track = (page) => region(page).locator(".carousel-track").first();
const slides = (page) => track(page).locator(":scope > .carousel-slide");

async function open(page, viewport = DESKTOP) {
  await page.setViewportSize(viewport);
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.goto(LAB);
  await expect(region(page)).toHaveAttribute("data-carousel-ready", "");
  return errors;
}

// The row rests once two reads agree.
async function settled(locator) {
  let last = -1;
  await expect.poll(async () => {
    const now = await locator.evaluate((el) => el.scrollLeft);
    const same = now === last;
    last = now;
    return same;
  }, { intervals: [100, 100, 150, 200, 250] }).toBe(true);
  return last;
}

// Each slide's look, read off its body and caption: scale, opacity, greyscale, and
// how far its centre sits from the row's centre.
const looks = (page) => track(page).evaluate((row) => {
  const mid = row.getBoundingClientRect().left + row.clientWidth / 2;
  return [...row.children].map((slide) => {
    const body = getComputedStyle(slide.querySelector(".carousel-spotlight-body"));
    const caption = getComputedStyle(slide.querySelector(".carousel-caption"));
    const box = slide.getBoundingClientRect();
    return {
      current: slide.hasAttribute("data-current"),
      scale: body.scale === "none" ? 1 : parseFloat(body.scale),
      opacity: parseFloat(body.opacity),
      grey: parseFloat((body.filter.match(/grayscale\(([\d.]+)\)/) || [0, 0])[1]) > 0.9,
      caption: parseFloat(caption.opacity),
      offset: Math.abs(box.left + box.width / 2 - mid)
    };
  });
});

// Settle the animation-or-transition state: two reads 350ms apart that agree.
async function restingLooks(page) {
  await settled(track(page));
  let last = null;
  await expect.poll(async () => {
    const now = JSON.stringify(await looks(page));
    const same = now === last;
    last = now;
    return same;
  }, { intervals: [350, 350, 350, 350] }).toBe(true);
  return JSON.parse(last);
}

function expectSpotlightOn(all, index) {
  all.forEach((look, i) => {
    if (i === index) {
      expect(look.current, `slide ${i + 1} is marked`).toBe(true);
      expect(look.offset, `slide ${i + 1} sits at the centre`).toBeLessThan(3);
      expect(look.scale).toBeGreaterThan(0.98);
      expect(look.opacity).toBeGreaterThan(0.98);
      expect(look.grey).toBe(false);
      expect(look.caption, "the centred slide shows its caption").toBeGreaterThan(0.98);
    } else {
      expect(look.current, `slide ${i + 1} is not marked`).toBe(false);
      expect(look.scale, `slide ${i + 1} is smaller`).toBeLessThan(0.8);
      expect(look.opacity, `slide ${i + 1} is faded`).toBeLessThan(0.6);
      expect(look.grey, `slide ${i + 1} is grey`).toBe(true);
      expect(look.caption, `slide ${i + 1} hides its caption`).toBeLessThan(0.05);
    }
  });
}

// Switch the scroll-driven animation off, so the controller's mark and the
// transition are what remain: the path a browser without view timelines takes.
const FALLBACK = ".carousel-spotlight .carousel-spotlight-body, .carousel-spotlight .carousel-caption { animation: none !important; }";

test("the first slide rests at the centre, full size, its neighbours small, faded and grey", async ({ page }) => {
  const errors = await open(page);
  expectSpotlightOn(await restingLooks(page), 0);
  // Every slide is a stop: seven dots, all showing.
  await expect(region(page).locator(".carousel-dot:visible")).toHaveCount(7);
  await expect(region(page).getByRole("button", { name: "Previous slides" })).toHaveAttribute("aria-disabled", "true");
  expect(errors).toEqual([]);
});

test("this browser runs the scroll-driven path", async ({ page }) => {
  await open(page);
  const timeline = await slides(page).nth(1).locator(".carousel-spotlight-body")
    .evaluate((el) => getComputedStyle(el).animationTimeline);
  expect(timeline).toBe("--carousel-slide");
  // Half-way between two stops the neighbour is part way: the look follows the
  // scroll, not a mark that flips at the half. The snap is lifted so the row can
  // rest between stops.
  const row = track(page);
  await row.evaluate((el) => { el.style.scrollSnapType = "none"; el.style.scrollBehavior = "auto"; });
  const [a, b] = await row.evaluate((el) => [...el.children].slice(0, 2).map((s) => s.offsetLeft + s.offsetWidth / 2 - el.clientWidth / 2));
  await row.evaluate((el, left) => el.scrollTo({ left, behavior: "auto" }), Math.max(0, a) + (b - Math.max(0, a)) * 0.5);
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  const mid = await row.evaluate((el) => parseFloat(getComputedStyle(el.children[1].querySelector(".carousel-spotlight-body")).scale));
  expect(mid).toBeGreaterThan(0.8);
  expect(mid).toBeLessThan(0.97);
});

for (const path of ["scroll-driven", "fallback"]) {
  test(`${path}: next, prev and the arrow keys move the spotlight one slide`, async ({ page }) => {
    await open(page);
    if (path === "fallback") await page.addStyleTag({ content: FALLBACK });
    const spot = region(page);

    await spot.getByRole("button", { name: "Next slides" }).click();
    expectSpotlightOn(await restingLooks(page), 1);
    await expect(spot.locator("[role='status']")).toHaveText("Slide 2 of 7");
    await expect(spot.locator(".carousel-dot[aria-current='true']")).toHaveAttribute("data-carousel-index", "1");

    await track(page).focus();
    await page.keyboard.press("ArrowRight");
    expectSpotlightOn(await restingLooks(page), 2);
    await page.keyboard.press("ArrowLeft");
    expectSpotlightOn(await restingLooks(page), 1);
    await page.keyboard.press("End");
    expectSpotlightOn(await restingLooks(page), 6);
    await expect(spot.getByRole("button", { name: "Next slides" })).toHaveAttribute("aria-disabled", "true");

    await spot.getByRole("button", { name: "Go to slide 4" }).click();
    expectSpotlightOn(await restingLooks(page), 3);
    await spot.getByRole("button", { name: "Previous slides" }).click();
    expectSpotlightOn(await restingLooks(page), 2);
  });

  test(`${path}: a plain scroll moves the spotlight to the slide it snaps to`, async ({ page }) => {
    await open(page);
    if (path === "fallback") await page.addStyleTag({ content: FALLBACK });
    const row = track(page);
    // A swipe's worth, a little past the fifth slide's stop: the snap centres the fifth.
    const target = await row.evaluate((el) => {
      const s = el.children[4];
      return s.offsetLeft + s.offsetWidth / 2 - el.clientWidth / 2 + 20;
    });
    await row.evaluate((el, left) => el.scrollTo({ left, behavior: "auto" }), target);
    expectSpotlightOn(await restingLooks(page), 4);
  });
}

test("a phone row centres one slide with its neighbours peeking either side", async ({ page }) => {
  await open(page, PHONE);
  const all = await restingLooks(page);
  expectSpotlightOn(all, 0);
  await region(page).getByRole("button", { name: "Next slides" }).click();
  const moved = await restingLooks(page);
  expectSpotlightOn(moved, 1);
  const visible = await track(page).evaluate((row) => {
    const r = row.getBoundingClientRect();
    return [...row.children].filter((s) => {
      const b = s.querySelector(".carousel-spotlight-body").getBoundingClientRect();
      return b.right > r.left + 4 && b.left < r.right - 4;
    }).length;
  });
  expect(visible, "the centred slide and a neighbour either side").toBe(3);
});

test("under reduced motion nothing scales or greys: the neighbours are only dimmed", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await open(page);
  const row = track(page);

  const first = await restingLooks(page);
  expect(first.map((l) => l.scale)).toEqual(Array(7).fill(1));
  expect(first.some((l) => l.grey)).toBe(false);
  expect(first[0].opacity).toBeGreaterThan(0.98);
  expect(first.slice(1).every((l) => l.opacity < 0.6)).toBe(true);
  const name = await slides(page).nth(1).locator(".carousel-spotlight-body").evaluate((el) => getComputedStyle(el).animationName);
  expect(name).toBe("none");

  await region(page).getByRole("button", { name: "Next slides" }).click();
  // No glide: the next frame already rests on slide two, and its mark has moved.
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  const moved = await looks(page);
  expect(moved[1].current).toBe(true);
  expect(moved[1].opacity).toBeGreaterThan(0.98);
  expect(moved[0].opacity).toBeLessThan(0.6);
  expect(moved.map((l) => l.scale)).toEqual(Array(7).fill(1));
  expect(await row.evaluate((el) => el.scrollLeft)).toBeGreaterThan(100);
});

test("dark and glass keep the spotlight and the arrows' glass fill", async ({ page }) => {
  await open(page);
  await page.evaluate(() => {
    document.documentElement.classList.add("dark");
    document.documentElement.dataset.surfaceStyle = "glass";
  });
  expectSpotlightOn(await restingLooks(page), 0);
  const fill = await region(page).getByRole("button", { name: "Next slides" }).evaluate((el) => getComputedStyle(el).backgroundColor);
  expect(fill).toMatch(/\/\s*0?\.\d+\)|rgba\(.*,\s*0?\.\d+\)/);
});
