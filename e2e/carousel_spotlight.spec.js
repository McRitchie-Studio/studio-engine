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
//
// CONTROLS FOR THE START (the three "middle slide" specs, 2026-11-05):
//   - `scroll-initial-target: nearest` removed: the controller-blocked spec red.
//   - the controller's openAtStart() call removed: the no-scroll-initial-target spec red.
//   - openAtStart's scrollTo given behavior "smooth": the same spec red (837px off
//     on the first frame).
//   - the spotlight's default start set to 0: all three red.

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
  await expect(region(page).getByRole("button", { name: "Previous slide", exact: true })).toHaveAttribute("aria-disabled", "true");
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

// Each path runs the same two checks. The specs are declared bare, one per path,
// because the lane's census counts bare `test(` declarations.
async function arrowsAndKeys(page, path) {
  await open(page);
  if (path === "fallback") await page.addStyleTag({ content: FALLBACK });
  const spot = region(page);

  await spot.getByRole("button", { name: "Next slide", exact: true }).click();
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
  await expect(spot.getByRole("button", { name: "Next slide", exact: true })).toHaveAttribute("aria-disabled", "true");

  await spot.getByRole("button", { name: "Go to slide 4" }).click();
  expectSpotlightOn(await restingLooks(page), 3);
  await spot.getByRole("button", { name: "Previous slide", exact: true }).click();
  expectSpotlightOn(await restingLooks(page), 2);
}

async function plainScroll(page, path) {
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
}

test("scroll-driven: next, prev and the arrow keys move the spotlight one slide", async ({ page }) => {
  await arrowsAndKeys(page, "scroll-driven");
});

test("fallback: next, prev and the arrow keys move the spotlight one slide", async ({ page }) => {
  await arrowsAndKeys(page, "fallback");
});

test("scroll-driven: a plain scroll moves the spotlight to the slide it snaps to", async ({ page }) => {
  await plainScroll(page, "scroll-driven");
});

test("fallback: a plain scroll moves the spotlight to the slide it snaps to", async ({ page }) => {
  await plainScroll(page, "fallback");
});

test("a phone row centres one slide with its neighbours peeking either side", async ({ page }) => {
  await open(page, PHONE);
  const all = await restingLooks(page);
  expectSpotlightOn(all, 0);
  await region(page).getByRole("button", { name: "Next slide", exact: true }).click();
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

  await region(page).getByRole("button", { name: "Next slide", exact: true }).click();
  // No glide: the next frame already rests on slide two, and its mark has moved.
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  const moved = await looks(page);
  expect(moved[1].current).toBe(true);
  expect(moved[1].opacity).toBeGreaterThan(0.98);
  expect(moved[0].opacity).toBeLessThan(0.6);
  expect(moved.map((l) => l.scale)).toEqual(Array(7).fill(1));
  expect(await row.evaluate((el) => el.scrollLeft)).toBeGreaterThan(100);
});

test("a neighbour holding focus drops the neighbour look, so its focus ring shows", async ({ page }) => {
  await open(page);
  await slides(page).nth(1).locator("[data-lab-card]").evaluate((card) => card.insertAdjacentHTML("beforeend", '<a href="#p2" data-lab-link>Open</a>'));
  await region(page).locator("[data-lab-link]").focus();
  const all = await restingLooks(page);
  expect(all[0].current, "focus did not move the spotlight").toBe(true);
  expect(all[1].current).toBe(false);
  expect(all[1].opacity, "the focused neighbour is not faded").toBeGreaterThan(0.98);
  expect(all[1].scale).toBeGreaterThan(0.98);
  expect(all[1].grey).toBe(false);
  expect(all[2].opacity, "the other neighbours stay faded").toBeLessThan(0.6);
});

test("dark and glass keep the spotlight and the arrows' glass fill", async ({ page }) => {
  await open(page);
  await page.evaluate(() => {
    document.documentElement.classList.add("dark");
    document.documentElement.dataset.surfaceStyle = "glass";
  });
  expectSpotlightOn(await restingLooks(page), 0);
  const fill = await region(page).getByRole("button", { name: "Next slide", exact: true }).evaluate((el) => getComputedStyle(el).backgroundColor);
  expect(fill).toMatch(/\/\s*0?\.\d+\)|rgba\(.*,\s*0?\.\d+\)/);
});

// THE START. "spot-default" takes the spotlight's default start, the middle slide
// (seven slides: the fourth). Each spec reads where the row is against where the
// fourth slide centres.
const defaultRegion = (page) => page.locator("section[data-lab='spot-default']");
const defaultTrack = (page) => defaultRegion(page).locator(".carousel-track").first();
const middleCentre = (page) => defaultTrack(page).evaluate((row) => {
  const s = row.children[3];
  return s.offsetLeft + s.offsetWidth / 2 - row.clientWidth / 2;
});
const centredIndex = (page) => defaultTrack(page).evaluate((row) => {
  const mid = row.getBoundingClientRect().left + row.clientWidth / 2;
  const offsets = [...row.children].map((s) => { const b = s.getBoundingClientRect(); return Math.abs(b.left + b.width / 2 - mid); });
  return offsets.indexOf(Math.min(...offsets));
});

test("the default spotlight opens on its middle slide, with both arrows on and nothing said", async ({ page }) => {
  const errors = await open(page);
  await expect(defaultRegion(page)).toHaveAttribute("data-carousel-ready", "");
  const left = await settled(defaultTrack(page));
  expect(Math.abs(left - await middleCentre(page))).toBeLessThan(3);
  expect(await centredIndex(page)).toBe(3);
  expect(left, "the row is not at its first slide").toBeGreaterThan(100);
  const spot = defaultRegion(page);
  await expect(spot.locator(".carousel-slide[data-current]")).toHaveAttribute("aria-label", "Crew 4");
  await expect(spot.locator(".carousel-dot[aria-current='true']")).toHaveAttribute("data-carousel-index", "3");
  await expect(spot.getByRole("button", { name: "Previous slide", exact: true })).toHaveAttribute("aria-disabled", "false");
  await expect(spot.getByRole("button", { name: "Next slide", exact: true })).toHaveAttribute("aria-disabled", "false");
  await expect(spot.locator("[role='status']")).toHaveText("");
  // The start moves the row, not the page.
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
  // The first-slide row beside it is untouched by its neighbour's start.
  expect(await track(page).evaluate((el) => el.scrollLeft)).toBe(0);
  expect(errors).toEqual([]);
});

test("the browser opens the row on the middle slide before any script: the controller blocked", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await blockOffsiteRequests(page);
  await page.route(/carousel_controller.*\.js/, (route) => route.abort());
  await page.goto(LAB);
  await expect(defaultRegion(page)).toHaveAttribute("data-studio-controller-failed", /carousel/);
  await expect(defaultRegion(page)).not.toHaveAttribute("data-carousel-ready", "");
  const left = await settled(defaultTrack(page));
  expect(Math.abs(left - await middleCentre(page))).toBeLessThan(3);
  expect(await centredIndex(page)).toBe(3);
});

test("without scroll-initial-target the controller opens the row on the middle slide, with no glide", async ({ page }) => {
  await page.setViewportSize(DESKTOP);
  await blockOffsiteRequests(page);
  // Take the browser's own start away before the first layout, and record the row
  // one frame after the controller marks it ready: a glide would still be near 0.
  await page.route(/\/tailwind\.css/, async (route) => {
    const response = await route.fetch();
    const body = `${await response.text()}\n[data-carousel-start-slide] { scroll-initial-target: none !important; }`;
    await route.fulfill({ response, body });
  });
  await page.addInitScript(() => {
    window.__firstLeft = null;
    new MutationObserver((_, observer) => {
      const region = document.querySelector("section[data-lab='spot-default'][data-carousel-ready]");
      if (!region) return;
      observer.disconnect();
      requestAnimationFrame(() => { window.__firstLeft = region.querySelector(".carousel-track").scrollLeft; });
    }).observe(document, { subtree: true, attributes: true, attributeFilter: ["data-carousel-ready"] });
  });
  await page.goto(LAB);
  await expect(defaultRegion(page)).toHaveAttribute("data-carousel-ready", "");
  await expect.poll(() => page.evaluate(() => typeof window.__firstLeft)).toBe("number");
  // The override reached the page: the browser's own start is off.
  expect(await defaultTrack(page).locator("[data-carousel-start-slide]").evaluate((el) => getComputedStyle(el).scrollInitialTarget)).toBe("none");
  const centre = await middleCentre(page);
  expect(Math.abs(await page.evaluate(() => window.__firstLeft) - centre), "the first frame already rests there").toBeLessThan(3);
  expect(await centredIndex(page)).toBe(3);
  await expect(defaultRegion(page).locator("[role='status']")).toHaveText("");
});

// THE LOOP (loop: true, "spot-loop": seven slides from the first, as the hub's
// /websites row). The row is visually continuous: clones of the last slides sit
// before the first and of the first after the last. Each read is the slide whose
// box holds the row's centre and its two neighbours, by card number.
//
// CONTROLS, each run against this file with the lab server restarted (2026-11-07):
//   - the controller's addClones() call removed: every loop spec red (no slide left
//     of the first).
//   - settle()'s jump removed: the seam spec red (the row rests on a clone).
//   - cloneOf()'s inert and aria-hidden removed: the screen-reader spec red.
const loopRegion = (page, name = "spot-loop") => page.locator(`section[data-lab='${name}']`);
const loopTrack = (page, name = "spot-loop") => loopRegion(page, name).locator("> .carousel-track");

async function openLoop(page, viewport = DESKTOP, name = "spot-loop") {
  const errors = await open(page, viewport);
  await expect(loopRegion(page, name)).toHaveAttribute("data-carousel-ready", "");
  await loopRegion(page, name).scrollIntoViewIfNeeded();
  await settled(loopTrack(page, name));
  return errors;
}

const loopRow = (page, name = "spot-loop") => loopTrack(page, name).evaluate((row) => {
  const r = row.getBoundingClientRect();
  const mid = r.left + row.clientWidth / 2;
  const all = [...row.children];
  const at = all.findIndex((s) => { const b = s.getBoundingClientRect(); return b.left <= mid && b.right >= mid; });
  const read = (s) => {
    if (!s) return null;
    const body = s.querySelector(".carousel-spotlight-body");
    const look = getComputedStyle(body);
    const box = s.getBoundingClientRect();
    const seen = body.getBoundingClientRect();
    return {
      card: s.querySelector("[data-lab-card]").dataset.labCard,
      clone: s.hasAttribute("data-carousel-clone"),
      current: s.hasAttribute("data-current"),
      offset: Math.abs(box.left + box.width / 2 - mid),
      width: Math.round(box.width),
      shows: Math.min(seen.right, r.right) - Math.max(seen.left, r.left),
      scale: look.scale === "none" ? 1 : parseFloat(look.scale),
      grey: parseFloat((look.filter.match(/grayscale\(([\d.]+)\)/) || [0, 0])[1]) > 0.9
    };
  };
  return { centre: read(all[at]), left: read(all[at - 1]), right: read(all[at + 1]) };
});

// Rest, then two reads of the look 350ms apart that agree.
async function restingLoop(page, name = "spot-loop") {
  await settled(loopTrack(page, name));
  let last = null;
  await expect.poll(async () => {
    const now = JSON.stringify(await loopRow(page, name));
    const same = now === last;
    last = now;
    return same;
  }, { intervals: [350, 350, 350, 350] }).toBe(true);
  return JSON.parse(last);
}

function expectFirstWithLastBeside(row, last = "7") {
  expect(row.centre).toMatchObject({ card: "1", clone: false, current: true });
  expect(row.centre.offset, "the first slide sits at the centre").toBeLessThan(3);
  expect(row.left, "a slide sits left of the first").not.toBeNull();
  expect(row.left.card, "and it shows the last slide").toBe(last);
  expect(row.left.clone).toBe(true);
  expect(row.left.width, "slide-shaped: as wide as a real slide").toBe(row.centre.width);
  expect(row.left.shows, "and it is on screen").toBeGreaterThan(20);
  expect(row.right).toMatchObject({ card: "2", clone: false });
}

test("a looping spotlight shows the last slide left of the first", async ({ page }) => {
  const errors = await openLoop(page);
  const row = await restingLoop(page);
  expectFirstWithLastBeside(row);
  // The clone wears the neighbour look the real neighbour on the right wears.
  expect(row.left.scale).toBeLessThan(0.8);
  expect(row.left.grey).toBe(true);
  expect(Math.abs(row.left.scale - row.right.scale)).toBeLessThan(0.02);
  await expect(loopRegion(page).getByRole("button", { name: "Previous slide", exact: true })).toHaveAttribute("aria-disabled", "false");
  expect(errors).toEqual([]);
});

test("a looping spotlight on a phone shows the last slide left of the first", async ({ page }) => {
  await openLoop(page, PHONE);
  expectFirstWithLastBeside(await restingLoop(page));
});

test("fallback: a clone takes the neighbour look from the controller's mark", async ({ page }) => {
  await openLoop(page);
  await page.addStyleTag({ content: FALLBACK });
  const row = await restingLoop(page);
  expectFirstWithLastBeside(row);
  expect(row.left.current).toBe(false);
  expect(row.left.scale).toBeLessThan(0.8);
  expect(row.left.grey).toBe(true);
  expect(row.centre.scale).toBeGreaterThan(0.98);
});

// Every scroll event of the row: where it is and which card is at the centre.
async function recordSeam(page) {
  await loopTrack(page).evaluate((row) => {
    window.__seam = [];
    row.addEventListener("scroll", () => {
      const mid = row.getBoundingClientRect().left + row.clientWidth / 2;
      const slide = [...row.children].find((s) => { const b = s.getBoundingClientRect(); return b.left <= mid && b.right >= mid; });
      window.__seam.push({ left: row.scrollLeft, card: slide?.querySelector("[data-lab-card]").dataset.labCard });
    }, { passive: true });
  });
}

test("Next at the last slide glides across the seam and rests on the first, the last beside it", async ({ page }) => {
  await openLoop(page);
  const spot = loopRegion(page);
  await spot.getByRole("button", { name: "Previous slide", exact: true }).click();
  await expect.poll(async () => (await loopRow(page)).centre).toMatchObject({ card: "7", clone: false, current: true });
  await expect(spot.locator("[role='status']")).toHaveText("Slide 7 of 7");
  await expect(spot.locator(".carousel-dot[aria-current='true']")).toHaveAttribute("data-carousel-index", "6");
  await restingLoop(page);

  await recordSeam(page);
  await spot.getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(async () => (await loopRow(page)).centre).toMatchObject({ card: "1", clone: false, current: true });
  expectFirstWithLastBeside(await restingLoop(page));
  await expect(spot.locator("[role='status']")).toHaveText("Slide 1 of 7");
  await expect(spot.locator(".carousel-dot[aria-current='true']")).toHaveAttribute("data-carousel-index", "0");

  // A glide forward, then one silent jump home: the centre only ever shows the
  // last slide and then the first, never the row running back across itself.
  const seam = await page.evaluate(() => window.__seam);
  const back = seam.map((s, i) => (i && s.left < seam[i - 1].left - 2 ? i : -1)).filter((i) => i >= 0);
  expect(back, "one jump back, after the glide").toHaveLength(1);
  const glide = seam.slice(0, back[0]);
  expect(new Set(glide.map((s) => Math.round(s.left))).size, "it glided through several frames").toBeGreaterThan(2);
  expect([...new Set(seam.map((s) => s.card))].sort()).toEqual(["1", "7"]);
  expect(seam[back[0] - 1].card).toBe("1");
  expect(seam[back[0]].card, "the jump shows the same card").toBe("1");
});

// A scroll that scrollend never follows (Chrome, when the page shortens and the
// browser pulls the scroll back, sends one scroll event and no scrollend). The spec
// swallows every scrollend of the looping row before the row hears it, so only the
// backstop (studio/carousel REST_CAP_MS) can rest the row.
//   CONTROL (2026-11-09): watchRest's backstop removed: red (the row rests on the
//   clone of card 7, no real slide is marked, and no change event fires).
test("a glide across the seam that gets no scrollend still jumps home and fires the change event once", async ({ page }) => {
  await page.addInitScript(() => {
    window.__swallowed = 0;
    window.__carouselChanges = [];
    window.addEventListener("scrollend", (event) => {
      if (!event.target.closest?.("[data-lab='spot-loop']")) return;
      window.__swallowed += 1;
      event.stopImmediatePropagation();
    }, true);
    document.addEventListener("studio:carousel:change", ({ target, detail }) => {
      if (target.dataset.lab === "spot-loop") window.__carouselChanges.push({ index: detail.index, previous: detail.previous });
    });
  });
  const errors = await openLoop(page);
  const spot = loopRegion(page);
  await recordSeam(page);
  await spot.getByRole("button", { name: "Previous slide", exact: true }).click();

  await expect.poll(async () => (await loopRow(page)).centre).toMatchObject({ card: "7", clone: false, current: true });
  await expect(spot.locator(".carousel-slide[data-current]:not([data-carousel-clone])")).toHaveAttribute("aria-label", "Loop 7");
  await expect(spot).not.toHaveAttribute("data-carousel-wrapping", "");
  await restingLoop(page);
  expect(await page.evaluate(() => window.__swallowed), "the browser sent scrollend and the row never heard it").toBeGreaterThan(0);
  // It glided to the copy first, then jumped home.
  const seam = await page.evaluate(() => window.__seam);
  expect(new Set(seam.map((s) => Math.round(s.left))).size, "it glided through several frames").toBeGreaterThan(2);
  expect(await page.evaluate(() => window.__carouselChanges)).toEqual([{ index: 6, previous: 0 }]);

  // The next press moves on from the real slide, and fires once more.
  await spot.getByRole("button", { name: "Next slide", exact: true }).click();
  await expect.poll(async () => (await loopRow(page)).centre).toMatchObject({ card: "1", clone: false, current: true });
  await restingLoop(page);
  expect(await page.evaluate(() => window.__carouselChanges)).toEqual([{ index: 6, previous: 0 }, { index: 0, previous: 6 }]);
  expect(errors).toEqual([]);
});

test("under reduced motion the seam is crossed with no glide", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await openLoop(page);
  const spot = loopRegion(page);
  await recordSeam(page);
  await spot.getByRole("button", { name: "Previous slide", exact: true }).click();
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  expect((await loopRow(page)).centre).toMatchObject({ card: "7", clone: false, current: true });
  const seam = await page.evaluate(() => window.__seam);
  expect(new Set(seam.map((s) => Math.round(s.left))).size, "one step, straight to the real last slide").toBe(1);

  await spot.getByRole("button", { name: "Next slide", exact: true }).click();
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  expect((await loopRow(page)).centre).toMatchObject({ card: "1", clone: false, current: true });
  expect((await loopRow(page)).left.card).toBe("7");
});

test("a screen reader and Tab meet each real slide once, and the dots count real slides", async ({ page }) => {
  await openLoop(page);
  const spot = loopRegion(page);
  const clones = spot.locator("[data-carousel-clone]");

  await expect(spot.getByRole("group", { name: /^Loop \d$/ })).toHaveCount(7);
  await expect(spot.getByRole("link", { name: "Open" })).toHaveCount(7);
  await expect(clones).toHaveCount(8);
  for (const clone of await clones.all()) {
    await expect(clone).toHaveAttribute("aria-hidden", "true");
    await expect(clone).toHaveAttribute("inert", "");
  }
  await expect(clones.locator("[id], [data-test], [data-carousel-target], [data-loop-link][name]")).toHaveCount(0);
  await expect(page.locator("#loop-1")).toHaveCount(1);
  await expect(page.locator("[data-test='loop-card']")).toHaveCount(7);
  await expect(spot.locator(".carousel-dot:visible")).toHaveCount(7);

  await loopTrack(page).focus();
  const reached = [];
  for (let i = 0; i < 7; i += 1) {
    await page.keyboard.press("Tab");
    reached.push(await page.evaluate(() => (document.activeElement.closest("[data-carousel-clone]") ? "clone" : document.activeElement.id)));
  }
  expect(reached).toEqual(["loop-1", "loop-2", "loop-3", "loop-4", "loop-5", "loop-6", "loop-7"]);
});

test("a #fragment link to a looping row's slide finds the real slide and brings it into view", async ({ page }) => {
  await openLoop(page);
  await page.evaluate(() => { window.location.hash = "#loop-5"; });
  await restingLoop(page);
  const target = page.locator("#loop-5");
  await expect(target).toHaveCount(1);
  const seen = await target.evaluate((link) => {
    const row = link.closest(".carousel-track").getBoundingClientRect();
    const box = link.getBoundingClientRect();
    return { clone: !!link.closest("[data-carousel-clone]"), inRow: box.left >= row.left - 1 && box.right <= row.right + 1 };
  });
  expect(seen).toEqual({ clone: false, inRow: true });
});

test("a looping spotlight with no start opens on its first slide, the last on its left", async ({ page }) => {
  const errors = await openLoop(page, DESKTOP, "spot-loop-default");
  const spot = loopRegion(page, "spot-loop-default");
  expectFirstWithLastBeside(await restingLoop(page, "spot-loop-default"), "5");
  await expect(spot).not.toHaveAttribute("data-carousel-start", /.*/);
  await expect(spot.locator(".carousel-dot[aria-current='true']")).toHaveAttribute("data-carousel-index", "0");
  await expect(spot.locator("[role='status']")).toHaveText("");
  expect(errors).toEqual([]);
});
