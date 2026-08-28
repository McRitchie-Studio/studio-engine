const { test, expect } = require("@playwright/test");
const { watchPageErrors, expectStickyChromeIsLive, blockOffsiteRequests } = require("./helpers");

// [e2e] DEFECT — the toast a lifted banner made unclickable (clear-toasts-above-banners).
//
// THE BUG. The shared layer scale put --z-banner (500) over --z-toast (400), and
// `body.modal-open` lifts the environment bar stack to that tier at sticky top 0.
// #toast-container is fixed at top 0 with 1rem of padding, so the two land on the
// same pixels: measured here, the bars own y0-47 and the toast's Dismiss button
// runs y28-40 — an 11px overlap at every viewport tested. With a modal open the
// banner won, so the Dismiss button could be SEEN and not PRESSED.
//
// AND THE TOAST HAD NO OTHER EXIT. The manager in layouts/studio/_flash gives any
// toast carrying buttons `duration: 0`, so it never auto-dismisses. A covered X is
// not a four-second annoyance; it strands the toast on the page for the rest of
// the session.
//
// WHY NO OTHER TIER CAN SEE THIS. The engine's own layer-scale test asserted
// --z-toast > --z-modal and was GREEN the entire time the toast was unusable —
// both tiers cleared the modal, which says nothing about which of THEM wins.
// test/lib/layer_scale_contract_test.rb now names the banner, and that assertion
// is the right tier for the token ORDER. It still cannot answer the question this
// file exists for: WHICH ELEMENT DOES THE BROWSER HAND THE CLICK TO. That is a hit
// test against real geometry, real stacking contexts and a real compositor, and it
// is the layer the defect actually lives on.
//
// TWO TRAPS THIS FILE IS BUILT AROUND, both measured on the broken build:
//
//   1. "THE TOAST COUNT DROPPED" IS NOT PROOF. At 390x844 the point under the
//      Dismiss button is the banner's own Email LINK. A real click there navigates
//      to /_studio/local_emails — and the toast count on the newly-loaded page is
//      zero. A spec asserting only `toHaveCount(0)` PASSES on the broken build at
//      phone width. So every dismissal assertion here also pins the URL and the
//      open modal: the toast must be gone AND we must still be standing on the
//      page that raised it.
//
//   2. AN ABSENT BANNER PASSES EVERYTHING. If the bar never rendered, or the lift
//      never armed, the hit test returns the Dismiss button trivially and the whole
//      file is vacuously green. So each spec asserts the collision EXISTS first —
//      the bar stack is sticky at top 0 carrying a numeric z-index, and its box
//      genuinely overlaps the button's — before asserting who wins it.

const DESKTOP = { width: 1440, height: 900 };
const PHONE = { width: 390, height: 844 };

const dismiss = (page) => page.locator('#toast-container button[aria-label="Dismiss"]');
const toasts = (page) => page.locator("#toast-container .toast-wrapper");

// WAIT ON THE ANIMATIONS THEMSELVES, NOT ON A CLOCK AND NOT ON TWO FRAMES.
//
// A toast enters on a CSS transition — scale 0.7 to 1 and max-height 0 to 20rem,
// over 0.4-0.5s of `ease`. A rect read before that finishes is a rect the button is
// no longer at, and the click lands somewhere else entirely.
//
// THE OBVIOUS WAIT IS WRONG, AND IT FAILED HERE FIRST. Sampling the button's top on
// consecutive animation frames and stopping when two agree looks like waiting on an
// observable, and it is not: `ease` starts SLOW, so the first two frames of the
// transition differ by well under a pixel and the check returns immediately — at the
// beginning of the animation rather than the end. Measured on the broken build with
// that version: the desktop specs read the button at y46 instead of its settled y34,
// and the PHONE spec passed over a build whose banner was demonstrably eating the
// click. A mutation test is the only reason that was caught.
//
// getAnimations() is the real signal. A CSS transition IS an Animation, it exposes a
// `finished` promise, and awaiting those is awaiting the settlement itself. Looped,
// because finishing one transition can start another (the blur's opacity follows the
// toast's), and each pass re-asks rather than trusting the first answer. `catch`
// because an animation cancelled mid-flight rejects, and a cancelled animation has
// equally stopped moving.
async function settleToastAnimations(page) {
  await page.evaluate(async () => {
    const container = document.querySelector("#toast-container");
    for (let pass = 0; pass < 6; pass += 1) {
      const running = container.getAnimations({ subtree: true });
      if (running.length === 0) return;
      await Promise.all(running.map((animation) => animation.finished.catch(() => {})));
    }
  });
}

// Put the page into the state the defect needs: a stuck toast, a modal open over
// it, and (optionally) a reader who had scrolled before either happened.
//
// THE ORDER IS FORCED. The toast is raised first because the modal's backdrop
// covers the whole viewport once it is up, and the scroll happens before both
// because `modal-open` locks the document — a scroll afterwards moves nothing. That
// is also the real sequence: a reader scrolls, acts, and gets a modal and a toast.
//
// The controls are pinned to the bottom of the lab page so clicking them cannot
// scroll the page back to the top and quietly undo the offset under test.
async function arrangeCollision(page, { viewport, scrollY = 0 }) {
  await blockOffsiteRequests(page);
  await page.setViewportSize(viewport);
  await page.goto("/lab/toast_over_banner");

  await expectStickyChromeIsLive(page, expect);

  if (scrollY) {
    await page.evaluate((y) => window.scrollTo(0, y), scrollY);
    await page.waitForFunction((y) => Math.round(window.scrollY) === y, scrollY);
  }

  await page.locator('[data-test="raise-toast"]').click();
  await expect(dismiss(page)).toBeVisible();

  await page.locator('[data-test="open-modal"]').click();
  await expect(page.locator('[role="dialog"]')).toBeVisible();

  await settleToastAnimations(page);

  return await page.evaluate(() => {
    const button = document.querySelector('#toast-container button[aria-label="Dismiss"]');
    const stack = document.querySelector(".studio-bar-stack");
    const b = button.getBoundingClientRect();
    const s = stack ? stack.getBoundingClientRect() : null;
    const stackStyle = stack ? window.getComputedStyle(stack) : null;
    const hitX = Math.round(b.left + b.width / 2);
    const hitY = Math.round(b.top + b.height / 2);
    const hit = document.elementFromPoint(hitX, hitY);

    const describe = (el) => {
      const parts = [];
      for (let node = el; node && node !== document.documentElement; node = node.parentElement) {
        const cls = typeof node.className === "string" && node.className.trim()
          ? "." + node.className.trim().split(/\s+/).slice(0, 2).join(".")
          : "";
        parts.push(node.tagName.toLowerCase() + (node.id ? "#" + node.id : "") + cls);
      }
      return parts.slice(0, 5).join(" < ");
    };

    return {
      url: location.href,
      scrollY: Math.round(window.scrollY),
      modalOpen: document.body.classList.contains("modal-open"),
      stackPresent: !!stack,
      stackPosition: stackStyle && stackStyle.position,
      stackTop: stackStyle && stackStyle.top,
      stackZ: stackStyle && stackStyle.zIndex,
      containerZ: window.getComputedStyle(document.querySelector("#toast-container")).zIndex,
      overlap: s ? Math.min(s.bottom, b.bottom) - Math.max(s.top, b.top) : -1,
      hitX,
      hitY,
      hitInsideDismiss: !!(hit && button.contains(hit)),
      hitDescription: hit ? describe(hit) : "nothing",
    };
  });
}

// Assert the page is genuinely in the state that produced the defect. Everything
// after this is only meaningful because these hold.
function expectTheCollisionIsReal(state) {
  expect(state.modalOpen, "body never got `modal-open`, so the bar-stack lift never armed").toBe(true);
  expect(state.stackPresent, "no .studio-bar-stack rendered — there is no banner to lose to").toBe(true);
  expect(
    state.stackPosition,
    `the bar stack computed position: ${state.stackPosition}. The modal-open rule in engine.css ` +
      "pins it; unpinned, it scrolls away and cannot cover anything."
  ).toBe("sticky");
  expect(state.stackTop, "sticky without a top offset never pins").toBe("0px");
  expect(
    Number(state.stackZ),
    `the bar stack computed z-index ${state.stackZ}. A value of auto means the lift never ` +
      "applied, so the banner is not competing for these pixels at all."
  ).toBeGreaterThan(0);
  expect(
    state.overlap,
    `the banner box and the Dismiss button do NOT overlap (${state.overlap}px). Nothing below is ` +
      "evidence of anything: the hit test would return the button whatever the layer scale said."
  ).toBeGreaterThan(0);
}

// The real click, and the three things that together mean it was heard by the toast.
async function expectDismissActuallyDismisses(page, state) {
  await page.mouse.click(state.hitX, state.hitY);

  await expect(
    toasts(page),
    "the toast is still on the page after a real click on its only exit"
  ).toHaveCount(0);

  // TRAP 1. On the broken build at phone width this click NAVIGATED — the point
  // belongs to the banner's Email link — and the count above went to zero because
  // a fresh page has no toasts. These two say we never left.
  expect(page.url(), "the click navigated away; the toast did not go anywhere, we did").toBe(state.url);
  await expect(
    page.locator('[role="dialog"]'),
    "the modal is gone, so this was a page change rather than a dismissal"
  ).toBeVisible();
}

test("a stuck toast's Dismiss button takes the click, not the lifted banner", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  const state = await arrangeCollision(page, { viewport: DESKTOP });
  expectTheCollisionIsReal(state);

  expect(
    state.hitInsideDismiss,
    `elementFromPoint(${state.hitX}, ${state.hitY}) — the centre of the toast's Dismiss button, ` +
      `overlapping the lifted banner by ${state.overlap}px — returned:\n  ${state.hitDescription}\n` +
      `Toast container z-index ${state.containerZ}, bar stack z-index ${state.stackZ}. The browser ` +
      "hands the click to the topmost element at a point, so anything but the button itself means " +
      "the toast cannot be dismissed — and a toast with buttons never auto-dismisses."
  ).toBe(true);

  await expectDismissActuallyDismisses(page, state);

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("the same holds for a reader who had scrolled before the modal opened", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  // SCROLL-TOP IS THE ONE POSITION THAT CAN HIDE THIS CLASS OF DEFECT. Both layers
  // are pinned, so a stacking mistake reads identically at the top of the document
  // and diverges only once the page has moved under them — and every reader who did
  // anything before opening a modal is at an offset.
  const state = await arrangeCollision(page, { viewport: DESKTOP, scrollY: 900 });

  expect(state.scrollY, "the page never scrolled, so this repeats the spec above").toBe(900);
  expectTheCollisionIsReal(state);

  expect(
    state.hitInsideDismiss,
    `at scrollY ${state.scrollY}, elementFromPoint at the Dismiss button returned:\n  ` +
      `${state.hitDescription}\n(overlap ${state.overlap}px, container z ${state.containerZ}, ` +
      `stack z ${state.stackZ})`
  ).toBe(true);

  await expectDismissActuallyDismisses(page, state);

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

test("and on a phone, where the banner puts a LINK under the Dismiss button", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  // The sharpest viewport for this defect. At 390px the banner's controls are
  // pushed inward and its Email link lands exactly under the Dismiss button, so on
  // the broken build the click did not merely miss — it navigated.
  const state = await arrangeCollision(page, { viewport: PHONE });
  expectTheCollisionIsReal(state);

  expect(
    state.hitInsideDismiss,
    `at ${PHONE.width}x${PHONE.height}, elementFromPoint at the Dismiss button returned:\n  ` +
      `${state.hitDescription}\n(overlap ${state.overlap}px, container z ${state.containerZ}, ` +
      `stack z ${state.stackZ})`
  ).toBe(true);

  await expectDismissActuallyDismisses(page, state);

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});

// THE PROPERTY THE SCALE WAS BUILT FOR, AND THE ONE THIS CHANGE COULD HAVE COST.
// --z-banner exists above --z-modal so a QA session can still read DEV MODE and
// reach the email chip with a modal up. Lowering the banner under the toast must
// not lower it under the BACKDROP, and the backdrop spans the whole viewport, so
// nothing about that is implied by the specs above.
test("the environment banner still clears the modal backdrop it sits over", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  const state = await arrangeCollision(page, { viewport: DESKTOP });
  expectTheCollisionIsReal(state);

  const banner = await page.evaluate(() => {
    const stack = document.querySelector(".studio-bar-stack");
    const box = stack.getBoundingClientRect();
    // A point inside the bars but well clear of the toast's own fixed box, which
    // is centred: the far left of the stack.
    const x = Math.round(box.left + 24);
    const y = Math.round(box.top + box.height / 2);
    const hit = document.elementFromPoint(x, y);
    return {
      x,
      y,
      insideStack: !!(hit && stack.contains(hit)),
      hitTag: hit ? hit.tagName.toLowerCase() : "nothing",
      hitClass: hit && typeof hit.className === "string" ? hit.className.trim().slice(0, 60) : "",
      backdropCovers: !!document.querySelector('[role="dialog"]'),
    };
  });

  expect(banner.backdropCovers, "no backdrop is up, so this asserts nothing").toBe(true);
  expect(
    banner.insideStack,
    `elementFromPoint(${banner.x}, ${banner.y}) is inside the lifted bar stack, but returned ` +
      `<${banner.hitTag} class="${banner.hitClass}">. The bars must stay lit and clickable over a ` +
      "modal — that is why --z-banner is above --z-modal, and this change moved --z-banner."
  ).toBe(true);

  expect(pageErrors, pageErrors.join("\n")).toHaveLength(0);
});
