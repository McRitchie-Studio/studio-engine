const { test, expect } = require("@playwright/test");
const {
  watchPageErrors, expectStickyChromeIsLive, sampleAcrossFrames, blockOffsiteRequests
} = require("./helpers");

// THE COLLAPSE MUST STOP WHEN THE FINGER STOPS.
//
// This is the one claim about the navbar collapse that no server-side tier can
// make. nav_collapse_contract_test pins the WIRING — that --nav-p is registered,
// written from a clamped scrollY, smoothstepped, guarded on short pages — and
// every one of those assertions passes over a build that also carries
// `transition-all duration-300` alongside. The wiring being right does not mean
// the motion is.
//
// The defect it exists to catch, measured in turf-monster at 390x844 before this
// primitive existed: the collapse was a 60px THRESHOLD fed into a 300ms ease, so
// the header ran 178px -> 139px with 34 of those 39px of document reflow landing
// AFTER the scroll had already stopped, over 232ms, at up to 3px per frame. From
// the response bytes that build and this one are indistinguishable. From the
// rendered page they are not remotely the same product.
//
// TWO ASSERTIONS, DELIBERATELY PAIRED. "Nothing moves after the finger stops" is
// trivially true of a navbar that never collapses at all — deleting the whole
// feature would pass it. So the collapse is asserted to HAPPEN first, and to have
// finished at its documented endpoint, before stillness means anything.
test("the collapse tracks the scroll and stops dead when it stops", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/lab/bar_stack");
  // Refuses to measure an unstyled page — see the helper's own note.
  await expectStickyChromeIsLive(page, expect);

  const headerHeight = () => {
    const header = document.querySelector("header");
    return Math.round(header.getBoundingClientRect().height * 10) / 10;
  };

  const expanded = await page.evaluate(headerHeight);

  // Walk the ramp the way a finger does — one step per frame, past --nav-ramp
  // (120px on this viewport) so the collapse completes.
  await page.evaluate(async () => {
    for (let i = 0; i < 24; i++) {
      window.scrollBy(0, 8);
      await new Promise((resolve) => requestAnimationFrame(resolve));
    }
  });

  // IT COLLAPSED. Without this, the stillness assertion below is satisfied by
  // any build where the navbar does nothing at all.
  const collapsed = await page.evaluate(headerHeight);
  expect(collapsed).toBeLessThan(expanded - 20);

  // AND IT IS FINISHED. Thirty frames — half a second, comfortably longer than
  // the 300ms ease this replaced and than the 232ms of measured overrun. The
  // scroll is untouched throughout; the only perturbation is time passing.
  const settled = await sampleAcrossFrames(page, {
    perturb: () => {},
    read: () => {
      const header = document.querySelector("header");
      return Math.round(header.getBoundingClientRect().height * 10) / 10;
    },
    frames: 30,
  });

  const drift = Math.max(...settled.map((h) => Math.abs(h - collapsed)));
  expect(
    drift,
    `header moved ${drift}px across 30 idle frames after the scroll stopped; ` +
      `samples: ${JSON.stringify(settled)}`
  ).toBeLessThanOrEqual(0.5);

  expect(errors).toEqual([]);
});

// THE ENDPOINTS THEMSELVES, at every band boundary.
//
// The spec above proves the PATH between the two ends is smooth. It says nothing
// about WHERE the ends are, and that gap shipped a real regression: lifting the
// band table carried each Tailwind size across as a font-size while dropping the
// LINE-HEIGHT half of the pair (`text-3xl` is 1.875rem/2.25rem, not 1.875rem), so
// the header grew 9px at every width >= 768px — expanded 84 -> 93 — while every
// wiring assertion, the smoothness spec, and consumer CI all stayed green. Only a
// human measuring two builds side by side caught it.
//
// COLLAPSED WAS UNAFFECTED, which is the sharp part: at the collapsed end the 32px
// logo sets the row height, not the title, so a one-endpoint check sees nothing.
// Both ends, at every boundary, or this class of move stays invisible.
//
// These numbers are the pre-existing navbar's, measured on origin/accepted. If a
// change is MEANT to move them, move them here in the same commit — that is a diff
// a reviewer reads as exactly what it is.
//
// MOVED 2026-09-27 (header-fits-a-phone), and by the LAB HOST, not by the navbar.
// e2e/boot.rb now gives the lab a Navbar Logo and the two-word app_name
// "McRitchie Industries", because every consuming app has both and the bare
// dummy had neither — and a header-width defect is invisible against a fixture
// with no logo and a six-letter name. Attributed by measurement rather than
// reasoning, one input at a time, all four mobile rows read at 320px:
//
//   one-word name, no logo  (the old fixture)   113 / 84 expanded   <- the old table
//   two-word name, no logo                      117 / 84
//   two-word name + logo    (what ships now)    125 / 96
//
// The 48px logo is taller than a title line, so it raises BOTH bands. The second
// word raises only the mobile band, where .nav-title stacks into a column. On
// the mobile rows the 400-767 sub-band reads 124 rather than 117 without the
// logo, because the title's font steps up above 399px.
//
// CONFIRMED NOT THE NAVBAR CHANGE, both directions, both measured:
//   · new fixture + layouts/_navbar at origin/main  -> still fails, same numbers
//   · old fixture (one-word name, no logo) + the phone-width fix in place
//                                                   -> 113/82 and 84/53 exactly,
//     i.e. the table above this change, restored by reverting only the fixture.
// The phone-width fix adds min-w-0, `truncate` and two width caps; none of the
// three touches a height, and the second run is what proves it rather than
// asserts it.
const ENDPOINTS = [
  { width: 320,  expanded: 125, collapsed: 86 },
  { width: 399,  expanded: 125, collapsed: 86 },
  { width: 400,  expanded: 125, collapsed: 86 },
  { width: 767,  expanded: 125, collapsed: 86 },
  { width: 768,  expanded: 96,  collapsed: 53 },
  { width: 1024, expanded: 96,  collapsed: 53 },
  { width: 1440, expanded: 96,  collapsed: 53 }
];

test("the collapse endpoints are unchanged at every band boundary", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  const measured = [];

  for (const band of ENDPOINTS) {
    await page.setViewportSize({ width: band.width, height: 900 });
    await page.goto("/lab/bar_stack");

    await page.evaluate(() => window.scrollTo(0, 0));
    await page.waitForTimeout(120);
    const expanded = await page.evaluate(() =>
      Math.round(document.querySelector("header").getBoundingClientRect().height));

    await page.evaluate(() => window.scrollTo(0, 2000));
    await page.waitForTimeout(400);
    const collapsed = await page.evaluate(() =>
      Math.round(document.querySelector("header").getBoundingClientRect().height));

    measured.push({ width: band.width, expanded, collapsed });
  }

  expect(measured, "the navbar's height endpoints moved; see the table in this spec")
    .toEqual(ENDPOINTS);

  // A collapse that never happens would satisfy an endpoint table of two equal
  // numbers, so assert the ends are actually APART as well as correct.
  for (const m of measured) {
    expect(m.collapsed, `the navbar does not collapse at ${m.width}px`).toBeLessThan(m.expanded);
  }

  expect(errors, `page errors: ${errors.join(", ")}`).toHaveLength(0);
});

// AND IT MUST NOT ARRIVE ALL AT ONCE.
//
// The sibling above proves the collapse stops when the scroll stops. It says
// nothing about how fast it gets there, and it cannot: it walks a constant
// 8px/frame, which is the slow deliberate case that was never broken.
//
// Progress is a pure function of scroll position, so if scrollY moves 90px
// between two frames the header moves its WHOLE range in that frame. Measured
// in turf-monster at 390x844 before the clamp — 8px/frame walked 3.9px of
// header, 24px/frame 14.1px, a momentum flick 39.0px, which is the entire
// 178 -> 139 collapse. It was found on a phone, by a person, after every tier
// here was green.
//
// So this walks a FLICK, and asserts the per-frame cap the clamp promises.
// THE HOLD: SCROLLING NEVER MOVES THE PAGE BY ITSELF.
//
// The header used to sit in the page's flow and shrink there, so every frame of
// the collapse reflowed the page: content ran ahead of the finger, a flick back
// to the top pushed the page down for ~10 frames after the scroll had stopped,
// and near the bottom of a page the browser clamped scrollY back 4px a frame as
// the document shrank (measured on the hub's /links: 344 -> 305 with nobody
// touching it). Held, the header gives its lost height back as margin, so:
//
//   1. the body's position IN THE DOCUMENT never changes, whatever --nav-p is;
//   2. once the scroll stops, scrollY stays where the finger left it;
//   3. the document never changes height.
//
// Paired, like the stop-dead spec above: each run also asserts the collapse
// HAPPENED, or a navbar that never collapses would pass all three.
const docTop = () => {
  const el = document.querySelector("[data-test='lab-body']");
  return Math.round((el.getBoundingClientRect().top + window.scrollY) * 10) / 10;
};

async function flickAndWatch(page, steps) {
  return page.evaluate(async ({ steps, docTopSrc }) => {
    const docTop = eval(`(${docTopSrc})`);
    const header = document.querySelector("header");
    const h = () => Math.round(header.getBoundingClientRect().height * 10) / 10;
    const frame = () => new Promise((r) => requestAnimationFrame(r));
    const tops = [docTop()];
    const heights = [h()];
    const docHeights = [document.documentElement.scrollHeight];
    for (const s of steps) {
      window.scrollBy(0, s);
      await frame();
      tops.push(docTop());
      heights.push(h());
      docHeights.push(document.documentElement.scrollHeight);
    }
    const stoppedAt = window.scrollY;
    const after = [];
    for (let i = 0; i < 30; i++) {
      await frame();
      after.push(window.scrollY);
      tops.push(docTop());
      docHeights.push(document.documentElement.scrollHeight);
    }
    return { tops, heights, docHeights, stoppedAt, after };
  }, { steps, docTopSrc: docTop.toString() });
}

const DOWN = [90, 78, 66, 55, 45, 36, 28, 21, 15, 10, 6, 3];
const UP = DOWN.map((s) => -s);

// Written out per width rather than looped: config/e2e_lane.yml's count reads
// the test() calls in the source.
async function expectFlickHoldsThePage(page, viewport) {
    await blockOffsiteRequests(page);
    const errors = watchPageErrors(page);
    await page.setViewportSize(viewport);
    await page.goto("/lab/bar_stack");
    await expectStickyChromeIsLive(page, expect);

    for (const steps of [DOWN, UP]) {
      const run = await flickAndWatch(page, steps);

      // IT COLLAPSED (or expanded): the header changed size during the flick.
      const span = Math.max(...run.heights) - Math.min(...run.heights);
      expect(span, `header heights ${JSON.stringify(run.heights)}`).toBeGreaterThan(20);

      const drift = Math.max(...run.tops) - Math.min(...run.tops);
      expect(drift, `the body moved in the document: ${JSON.stringify(run.tops)}`).toBeLessThanOrEqual(0.5);
      expect(new Set(run.docHeights).size, `document heights ${JSON.stringify([...new Set(run.docHeights)])}`).toBe(1);
      expect(run.after.every((y) => y === run.stoppedAt), `scrollY after the flick: ${JSON.stringify(run.after)}`).toBe(true);
    }
    expect(errors).toEqual([]);
}

test("390px: a flick down and back up never moves the page by itself", async ({ page }) => {
  await expectFlickHoldsThePage(page, { width: 390, height: 844 });
});

test("1280px: a flick down and back up never moves the page by itself", async ({ page }) => {
  await expectFlickHoldsThePage(page, { width: 1280, height: 800 });
});

// A short page: barely more scroll room than the ramp. Scrolled to its end,
// the browser has nothing to clamp, because the document never shortened.
test("at the bottom of a short page the scroll stays where it was put", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/lab/bar_stack?short=1");
  await expectStickyChromeIsLive(page, expect);

  // The browser's own answer for "the end": scroll far past it and read back.
  const max = await page.evaluate(() => { window.scrollTo(0, 1e6); const m = window.scrollY; window.scrollTo(0, 0); return m; });
  // This page's whole scroll room is barely more than the ramp.
  expect(max).toBeLessThan(260);
  await page.evaluate(() => new Promise((r) => setTimeout(r, 200)));

  const run = await flickAndWatch(page, [400, 400]);
  expect(run.stoppedAt).toBe(max);
  expect(run.heights[run.heights.length - 1], "the header collapsed").toBeLessThan(run.heights[0] - 20);
  expect(run.after.every((y) => y === max), `scrollY after reaching the end: ${JSON.stringify(run.after)}`).toBe(true);
  expect(new Set(run.docHeights).size).toBe(1);
});

// STILL CONTINUOUS. The hold changes how the page makes room, not the collapse:
// halfway through the ramp the header is halfway between its endpoints, and it
// stays there while the scroll does.
async function expectHalfwayHolds(page, band) {
    await blockOffsiteRequests(page);
    await page.setViewportSize({ width: band.width, height: 800 });
    await page.goto("/lab/bar_stack");
    await expectStickyChromeIsLive(page, expect);

    const height = () => Math.round(document.querySelector("header").getBoundingClientRect().height * 10) / 10;
    const expanded = await page.evaluate(height);
    await page.evaluate((y) => window.scrollTo(0, y), band.ramp * 10);
    await expect.poll(() => page.evaluate(() => document.querySelector("header").style.getPropertyValue("--nav-p"))).toBe("1.0000");
    const collapsed = await page.evaluate(height);

    await page.evaluate((y) => window.scrollTo(0, y), band.ramp / 2);
    // smoothstep(0.5) is 0.5: halfway along the ramp is halfway collapsed.
    await expect.poll(() => page.evaluate(() => document.querySelector("header").style.getPropertyValue("--nav-p"))).toBe("0.5000");
    const mid = await page.evaluate(height);
    expect(Math.abs(mid - (expanded + collapsed) / 2), `${expanded} / ${mid} / ${collapsed}`).toBeLessThanOrEqual(2);

    const held = await sampleAcrossFrames(page, { perturb: () => {}, read: () => document.querySelector("header").getBoundingClientRect().height, frames: 20 });
    expect(Math.max(...held) - Math.min(...held)).toBeLessThanOrEqual(0.5);
}

test("390px: parked mid-ramp, the header holds halfway", async ({ page }) => {
  await expectHalfwayHolds(page, { width: 390, ramp: 120 });
});

test("1280px: parked mid-ramp, the header holds halfway", async ({ page }) => {
  await expectHalfwayHolds(page, { width: 1280, ramp: 144 });
});

// BACK RESTORES A HELD HEADER, IT DOES NOT STACK A SECOND HOLD.
//
// Turbo copies the page into its snapshot cache BEFORE the controller
// disconnects, so the cached header still carries the hold's inline margin.
// On Back, a controller that read that margin as the header's own base counted
// the old hold twice: a permanent 39-43px band under the header (found in
// review on turf-monster's contest page, 5642 -> 5681px). Restored, the page
// must sit exactly where a fresh load puts it.
test("Back to a page left scrolled restores the header's footprint exactly", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  // Entered by a Turbo visit, so Back is a Turbo RESTORE from the snapshot
  // cache (a page entered by a full load comes back as a full load).
  await page.goto("/lab/toast_flash");
  await page.evaluate(() => window.Turbo.visit("/lab/bar_stack_turbo"));
  await expect(page.locator("[data-test='lab-body']")).toBeVisible();
  await expectStickyChromeIsLive(page, expect);

  const fresh = await page.evaluate(docTop);
  await page.evaluate(() => window.scrollTo(0, 600));
  await expect.poll(() => page.evaluate(() => document.querySelector("header").style.getPropertyValue("--nav-p"))).toBe("1.0000");
  await page.waitForTimeout(300);

  // Away and Back inside Turbo: both pages load it, so Back restores the
  // cached clone with its scroll position.
  await page.evaluate(() => window.Turbo.visit("/lab/toast_flash"));
  await expect(page).toHaveURL(/toast_flash/);
  await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
  // Back before Turbo has filed the page it left in its snapshot cache came
  // back at scrollY 0 (2 in 12 runs idle, 10 in 20 under load); waiting for
  // the cache entry held it at 45 in 45. So wait for the entry.
  await expect.poll(() => page.evaluate(() => !!window.Turbo.session.view.snapshotCache.get(new URL("/lab/bar_stack_turbo", location.href))), { message: "the page left is in Turbo's snapshot cache" }).toBe(true);
  await page.goBack();
  await expect(page.locator("[data-test='lab-body']")).toBeVisible();
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));

  // A Turbo restore puts the scroll back where it was left.
  await expect.poll(() => page.evaluate(() => window.scrollY), { message: "Back was a Turbo restore" }).toBeGreaterThan(300);
  await page.waitForTimeout(200);
  const restored = await page.evaluate(docTop);
  expect(Math.abs(restored - fresh), `fresh ${fresh}, restored ${restored}`).toBeLessThanOrEqual(0.5);
  expect(errors).toEqual([]);
});
