const { test, expect } = require("@playwright/test");
const {
  watchPageErrors, expectStickyChromeIsLive, sampleAcrossFrames, blockOffsiteRequests
} = require("./helpers");

// [e2e] DEFECT 1 — the navbar's paint-time offset jump (fix-navbar-offset-jump).
//
// THE BUG. The bar stack published --studio-bars-h from TWO sources that disagreed:
// a server-rendered <style> estimate (bar count x a fixed 47px unit) and a
// ResizeObserver measuring the real height. The header's sticky `top` read that
// property. So the header PAINTED at the estimate and MOVED when the measurement
// landed — again on every webfont swap, and during a Turbo view transition the
// outgoing and incoming headers composited at two different tops, which is the
// "navbar drawn twice" screenshot in the bug report.
//
// WHY NO EXISTING TIER CAN SEE IT. Both markup tests in place at the time asserted
// "exactly one pinned header", and both were CORRECT — one header IS rendered. A
// string assertion cannot observe a post-paint MOVE, and the engine had no browser
// tier to run one in; test/views/bar_stack_test.rb says so in as many words. The
// fix was verified BY HAND in a headless Chromium and the numbers written into a
// comment: at 390x780, with the bar's height changed under a PINNED header, the old
// markup moved the header 8px (computed top 41px -> 49px) and the new markup moved
// it 0px. This spec is that manual check, automated. It is the first time this
// property has been asserted by anything that runs.
//
// WHY THE PAGE MUST BE SCROLLED. Unscrolled, a header sitting below the bars in
// normal flow and a header offset by a measured custom property are
// INDISTINGUISHABLE — both land under the bar. The two only diverge once the header
// is PINNED, because then the first is nailed to the viewport top by CSS while the
// second tracks a number a ResizeObserver republishes a frame late.
//
// WHY THE BAR IS GROWN. With one bar rendered, the server's estimate (1 x 47px) and
// the bar's real height can coincide exactly, so a page that merely LOADS may show
// no divergence at all. Growing the bar is what a webfont swap does in production:
// it forces the two publishers apart and makes the observer fire. This is the same
// perturbation the manual verification used.

const VIEWPORT = { width: 390, height: 780 };

test("the pinned header does not move when a bar grows under it", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.setViewportSize(VIEWPORT);
  await page.goto("/lab/bar_stack");

  await expectStickyChromeIsLive(page, expect);
  await expect(page.locator("[data-studio-bar-stack]")).toBeVisible();

  // Scroll well past the bar so the header is PINNED. 600px is far below any
  // plausible bar height, so the header is stuck for the whole sample window and a
  // change in its rect top can only come from its OFFSET changing.
  await page.evaluate(() => window.scrollTo(0, 600));
  await page.waitForTimeout(100);

  const samples = await sampleAcrossFrames(page, {
    // The webfont swap, in one line: make the bar 80px taller than it was.
    // In the fixed markup the stack is ordinary flow, so this changes where the
    // header's static position is and NOTHING about where it is pinned.
    // In the broken markup this resizes the observed element, the ResizeObserver
    // republishes --studio-bars-h one frame later, and the pinned header steps down.
    perturb: () => {
      const stack = document.querySelector("[data-studio-bar-stack]");
      stack.style.minHeight = `${stack.getBoundingClientRect().height + 80}px`;
    },
    read: () => Math.round(document.querySelector("header").getBoundingClientRect().top * 100) / 100,
    frames: 30,
  });

  const distinct = [...new Set(samples)];
  const spread = Math.max(...samples) - Math.min(...samples);
  const detail = `header top across 30 frames: ${JSON.stringify(samples)}`;

  // THE ASSERTION. Not "the header ends up in the right place" — it always does,
  // that is what made this defect ship. The property is that it was NEVER anywhere
  // else: every painted frame put the header at the same offset.
  expect(
    spread,
    `${detail}\n\nThe pinned header MOVED ${spread}px after paint. A header whose offset ` +
      "is a static CSS value cannot do this; one that reads a runtime-published custom " +
      "property can, and did — see the fix-navbar-offset-jump defect. Distinct values " +
      `observed: ${JSON.stringify(distinct)}.`
  ).toBeLessThanOrEqual(0.5);

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

// The same property at the SOURCE, which is cheaper to read when it fails: nothing
// on the page publishes the offset variable, and the header's own offset resolves to
// a plain length rather than a var()/calc() a script could rewrite between frames.
//
// This is deliberately NOT a substitute for the frame sampling above — it is the
// same trap the original guard fell into (assert the spelling, miss the behavior),
// and a consumer could reintroduce the jump with a differently-named property. It
// earns its place only as the diagnostic that tells you WHICH publisher came back.
test("no runtime publisher owns the header's offset", async ({ page }) => {
  await page.setViewportSize(VIEWPORT);
  await page.goto("/lab/bar_stack");

  const chrome = await expectStickyChromeIsLive(page, expect);

  expect(
    chrome.top,
    `the header's resolved sticky offset is "${chrome.top}". It must resolve to a plain ` +
      "length that only CSS sets."
  ).toMatch(/^-?\d+(\.\d+)?px$/);

  const published = await page.evaluate(() =>
    window.getComputedStyle(document.documentElement).getPropertyValue("--studio-bars-h").trim()
  );

  expect(
    published,
    `--studio-bars-h is published as "${published}". A measured offset republished at ` +
      "runtime is the mechanism of the paint-time jump."
  ).toBe("");
});
