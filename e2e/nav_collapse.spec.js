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
const ENDPOINTS = [
  { width: 320,  expanded: 113, collapsed: 82 },
  { width: 399,  expanded: 113, collapsed: 82 },
  { width: 400,  expanded: 113, collapsed: 82 },
  { width: 767,  expanded: 113, collapsed: 82 },
  { width: 768,  expanded: 84,  collapsed: 53 },
  { width: 1024, expanded: 84,  collapsed: 53 },
  { width: 1440, expanded: 84,  collapsed: 53 }
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
test("a flick collapses at the capped rate, not all in one frame", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/lab/bar_stack");
  await expectStickyChromeIsLive(page, expect);

  const walk = async (steps) =>
    page.evaluate(async (steps) => {
      const header = document.querySelector("header");
      const h = () => Math.round(header.getBoundingClientRect().height * 10) / 10;
      window.scrollTo(0, 0);
      await new Promise((r) => setTimeout(r, 300));
      const seen = [h()];
      for (const s of steps) {
        window.scrollBy(0, s);
        await new Promise((r) => requestAnimationFrame(r));
        seen.push(h());
      }
      // Let the clamp finish catching up once the "finger" is off.
      for (let i = 0; i < 24; i++) {
        await new Promise((r) => requestAnimationFrame(r));
        seen.push(h());
      }
      let worst = 0;
      for (let i = 1; i < seen.length; i++) worst = Math.max(worst, Math.abs(seen[i] - seen[i - 1]));
      return { worst, first: seen[0], last: seen[seen.length - 1] };
    }, steps);

  // A momentum flick: the profile that used to move the whole range in one frame.
  const flick = await walk([90, 78, 66, 55, 45, 36, 28, 21, 15, 10, 6, 3]);

  // IT STILL COLLAPSES. Without this, a navbar that ignored scroll entirely
  // would satisfy the cap trivially.
  expect(flick.last).toBeLessThan(flick.first - 20);

  // AND NEVER FASTER THAN THE CAP. --nav-max-step is 5px; allow a pixel of
  // rounding on top rather than pinning the exact constant from another file.
  expect(
    flick.worst,
    `a flick moved the header ${flick.worst}px in one frame (${flick.first} -> ${flick.last})`
  ).toBeLessThanOrEqual(6);

  expect(errors).toEqual([]);
});
