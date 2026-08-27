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
