const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The hold-to-confirm button and its fizz.
//
// WHY THIS IS IN THE BROWSER LANE AND NOT test/views. The server's bytes are the
// same whether any of this works. The partial always renders a button, two
// layers and sixty bubbles; what it cannot render is the press-and-hold TIMER
// that decides the button was held long enough, or the computed styles that
// decide where the bubbles sit, what colour they resolve to, and whether they
// move at all. Each of those is a program or a cascade, and both only exist once
// a browser has run them.
//
// The four things asserted here, and the defect each one exists to catch:
//
//   1. The hold completes.        A dead timer leaves the button on "Hold to
//                                 Confirm" forever, and every markup assertion
//                                 still passes.
//   2. The bubbles sit BEHIND.    The button paints over them because it is
//                                 z-index 1 in an isolated stack. Drop the
//                                 isolation and the z-order leaks into the host
//                                 page; drop the z-index and the bubbles cover
//                                 the button's face. Neither is visible in
//                                 markup — both are resolved values.
//   3. Hover adds bubbles, not    The claim is a SECOND LAYER fading in while
//      speed.                     the first one's cycle is untouched. A markup
//                                 test sees two layers whether or not either
//                                 ever appears.
//   4. Zones resolve to colours.  A bubble carries --fc: var(--fizz-c-N, <hue>).
//                                 Whether that lands on the bound palette or the
//                                 fallback is a var resolution, and the whole
//                                 point of zones is that a zone resolves to ONE
//                                 colour rather than to eighteen.
//
// The lab page (test/dummy/app/views/e2e_lab/hold_button.html.erb) renders the
// engine partial by name with a 600ms duration, so a press can be held for its
// whole life without the lane paying two seconds per test.

const LIVELY = '.hold-btn[data-hold-id="lively"]';
const LIVELY_STACK = '.hold-stack:has(> .hold-btn[data-hold-id="lively"])';

test("a press held to term confirms, and a press let go early does not", async ({ page }) => {
  const errors = watchPageErrors(page);
  // Any off-origin request a lab page makes would land in the error list on a slow or
  // refused fetch and read as a failure of the hold itself. (The instance that taught
  // the lane this was Montserrat, which the engine now vendors.)
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/lab/hold_button");

  const button = page.locator(LIVELY);
  await expect(button).not.toHaveClass(/\bsuccess\b/);

  // Let go before the 600ms is up: the button must fall back to rest, not creep
  // toward confirmed. This half is why the timer cannot simply be "fire on
  // mousedown" — a spec that only held to term would pass against that.
  await button.hover();
  await page.mouse.down();
  await page.waitForTimeout(150);
  await page.mouse.up();
  await page.waitForTimeout(700);
  await expect(button).not.toHaveClass(/\bsuccess\b/);
  await expect(button).not.toHaveClass(/\bprocess\b/);

  // Hold it to term.
  await page.mouse.down();
  await expect(button).toHaveClass(/\bprocess\b/);
  await expect(button).toHaveClass(/\bsuccess\b/, { timeout: 3000 });
  await page.mouse.up();

  expect(errors, "the page must not throw while the button runs").toEqual([]);
});

test("the bubbles sit behind the button, in a stack that keeps its z-order private", async ({ page }) => {
  await page.goto("/lab/hold_button");

  const order = await page.evaluate((selector) => {
    const stack = document.querySelector(selector);
    const button = stack.querySelector(":scope > .hold-btn");
    const fizz = stack.querySelector(":scope > .hold-fizz");
    return {
      isolation: getComputedStyle(stack).isolation,
      buttonZ: getComputedStyle(button).zIndex,
      fizzZ: getComputedStyle(fizz).zIndex,
      // The bubbles must not be inside the button: a child cannot get behind its
      // parent's own background, because the button's transform makes it a
      // stacking context.
      bubblesInsideButton: button.querySelectorAll(".fizz-bit").length,
      // And they must not swallow the press.
      fizzEvents: getComputedStyle(fizz).pointerEvents
    };
  }, LIVELY_STACK);

  expect(order.isolation).toBe("isolate");
  expect(order.buttonZ).toBe("1");
  expect(order.fizzZ).toBe("0");
  expect(order.bubblesInsideButton).toBe(0);
  expect(order.fizzEvents).toBe("none");
});

test("hover doubles the bubble count and leaves the cycle alone", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/lab/hold_button");

  // The nudge cycle re-classes the button every few seconds and swaps the
  // bubbles onto its own timing. Clearing the class and reading the computed
  // style in ONE evaluate keeps the pair atomic: the interval cannot fire
  // between the two halves.
  const restingCycle = () =>
    page.evaluate((selector) => {
      const stack = document.querySelector(selector);
      stack.querySelector(".hold-btn").classList.remove("nudge", "nudge-soft");
      const bit = stack.querySelector(".hold-fizz:not(.hold-fizz-extra) .fizz-bit");
      const style = getComputedStyle(bit);
      return { name: style.animationName, duration: style.animationDuration };
    }, LIVELY_STACK);

  const extraOpacity = () =>
    page.evaluate((selector) =>
      getComputedStyle(document.querySelector(selector).querySelector(".hold-fizz-extra")).opacity,
    LIVELY_STACK);

  const atRest = await restingCycle();
  expect(atRest.name).toBe("fizz-boil");
  expect(await extraOpacity()).toBe("0");

  await page.locator(LIVELY).hover();
  await expect.poll(extraOpacity, { timeout: 3000 }).toBe("1");
  expect(await restingCycle(), "hover adds bubbles, it does not spin them faster").toEqual(atRest);

  // Calm is the other level: one layer, and no second to reveal.
  const calmLayers = await page.locator('.hold-stack:has(> .hold-btn[data-hold-id="calm"]) .hold-fizz-extra').count();
  expect(calmLayers).toBe(0);
});

test("each zone resolves to one colour, and the layers differ inside it", async ({ page }) => {
  await page.goto("/lab/hold_button");

  const zones = await page.evaluate((selector) => {
    const stack = document.querySelector(selector);
    const read = (layer) => {
      const byZone = {};
      stack.querySelectorAll(layer).forEach((el) => {
        const slot = Number(el.style.getPropertyValue("--fc").match(/--fizz-c-(\d+)/)[1]);
        const zone = Math.ceil(slot / 3);
        const colour = getComputedStyle(el).backgroundColor;
        byZone[zone] = byZone[zone] || [];
        if (!byZone[zone].includes(colour)) byZone[zone].push(colour);
      });
      return byZone;
    };
    return { rest: read(".hold-fizz:not(.hold-fizz-extra) .fizz-bit"), hover: read(".hold-fizz-extra .fizz-bit") };
  }, LIVELY_STACK);

  expect(Object.keys(zones.rest)).toHaveLength(6);
  for (const [zone, colours] of Object.entries(zones.rest)) {
    expect(colours, `zone ${zone} rests in exactly one colour`).toHaveLength(1);
    expect(zones.hover[zone], `zone ${zone} carries its other two`).toHaveLength(2);
    expect(zones.hover[zone], `zone ${zone} changes on hover`).not.toContain(colours[0]);
  }
});

test("a viewer who asked for less motion gets no bubbles at all", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/lab/hold_button");

  // The guard has to BEAT the state rules, which are more specific than anything
  // a media query can write — the first cut of it lost that contest silently,
  // and every server-side assertion stayed green while a lively button kept
  // fizzing at someone who had asked it not to.
  expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(true);

  const bits = await page.evaluate(() =>
    [...document.querySelectorAll(".fizz-bit")].map((el) => {
      const style = getComputedStyle(el);
      return `${style.animationName}:${style.opacity}`;
    })
  );
  expect(bits.length).toBeGreaterThan(0);
  expect([...new Set(bits)]).toEqual(["none:0"]);
});

// ── The portal (fizz_portal: true) ──────────────────────────────────────────
//
// A button near the top of an overflow-hidden card has its bubbles cut off at
// the card's edge. The portal moves the layers to <body> in a fixed box that
// tracks the stack. What a markup test cannot see, and these assert: that the
// box really left every clipping ancestor, that it stays on the button through
// a scroll, that it paints above the card, and that it still follows the
// button's state once :has() can no longer reach it.

const clippingAncestors = (el) => {
  const found = [];
  for (let n = el.parentElement; n; n = n.parentElement) {
    const { overflowX, overflowY } = getComputedStyle(n);
    if (/hidden|clip/.test(overflowX + overflowY)) found.push(n.dataset.test || n.tagName);
  }
  return found;
};

test("the default stack stays inside the card, which clips it", async ({ page }) => {
  await page.goto("/lab/hold_button");

  const clipped = await page.evaluate((walk) => {
    const stack = document.querySelector('.hold-stack:has(> .hold-btn[data-hold-id="clipped"])');
    const bit = stack.querySelector(".fizz-bit");
    return {
      portalAttr: stack.hasAttribute("data-fizz-portal"),
      layersInStack: stack.querySelectorAll(":scope > .hold-fizz").length,
      clippedBy: new Function("return " + walk)()(bit)
    };
  }, clippingAncestors.toString());

  expect(clipped.portalAttr).toBe(false);
  expect(clipped.layersInStack).toBe(2);
  expect(clipped.clippedBy).toContain("phone-clipped");
});

test("with fizz_portal the bubbles leave the card and track the button", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/lab/hold_button");

  const read = () =>
    page.evaluate((walk) => {
      const stack = document.querySelector('.hold-stack:has(> .hold-btn[data-hold-id="escaping"])');
      const box = stack._fizzPortal && stack._fizzPortal.box;
      if (!box) return null;
      const s = stack.getBoundingClientRect();
      const b = box.getBoundingClientRect();
      const card = document.querySelector('[data-test="phone-escaping"]');
      return {
        parent: box.parentElement.tagName,
        layersLeftInStack: stack.querySelectorAll(".fizz-bit").length,
        bubbles: box.querySelectorAll(".fizz-bit").length,
        clippedBy: new Function("return " + walk)()(box.querySelector(".fizz-bit")),
        position: getComputedStyle(box).position,
        boxZ: Number(getComputedStyle(box).zIndex),
        cardZ: Number(getComputedStyle(card).zIndex),
        drift: Math.max(Math.abs(s.left - b.left), Math.abs(s.top - b.top),
                        Math.abs(s.width - b.width), Math.abs(s.height - b.height)),
        top: b.top
      };
    }, clippingAncestors.toString());

  await expect.poll(read).not.toBeNull();
  const mounted = await read();
  expect(mounted.parent).toBe("BODY");
  expect(mounted.layersLeftInStack).toBe(0);
  expect(mounted.bubbles).toBe(60);
  expect(mounted.clippedBy, "no ancestor of the moved bubbles may clip them").toEqual([]);
  expect(mounted.position).toBe("fixed");
  expect(mounted.boxZ, "a card under the floor gets the --z-raised floor, which is above it").toBe(20);
  expect(mounted.boxZ).toBeGreaterThan(mounted.cardZ);
  expect(mounted.drift).toBeLessThan(1);

  // Scroll the page and the box must follow the button, not stay where it was.
  await page.evaluate(() => { document.body.style.minHeight = "300vh"; window.scrollTo(0, 120); });
  await expect.poll(async () => (await read()).drift).toBeLessThan(1);
  expect((await read()).top).toBeLessThan(mounted.top - 100);

  expect(errors).toEqual([]);
});

test("the portal follows the button's state and palette", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/lab/hold_button");

  const box = page.locator('body > .hold-fizz-portal[data-fizz-portal-for="escaping"]');
  await expect(box).toHaveCount(1);
  const button = page.locator('.hold-btn[data-hold-id="escaping"]');

  await button.hover();
  await expect(box).toHaveClass(/\bis-hover\b/);
  await expect.poll(() =>
    box.evaluate((el) => getComputedStyle(el.querySelector(".hold-fizz-extra")).opacity)).toBe("1");

  await page.mouse.down();
  await expect(box).toHaveClass(/\bis-process\b/);
  await expect(box).toHaveClass(/\bis-success\b/, { timeout: 3000 });
  await page.mouse.up();
  expect(await box.evaluate((el) => getComputedStyle(el.querySelector(".fizz-bit")).animationName)).toBe("fizz-burst");

  // The stack's palette rides along: slot 1 is bound to red on the stack, and
  // zone 1's resting bubbles must still resolve to it out on <body>.
  const zoneOne = await box.evaluate((el) =>
    [...el.querySelectorAll(".hold-fizz:not(.hold-fizz-extra) .fizz-bit")]
      .filter((bit) => /--fizz-c-1,/.test(bit.style.getPropertyValue("--fc")))
      .map((bit) => getComputedStyle(bit).backgroundColor));
  expect(zoneOne.length).toBeGreaterThan(0);
  expect([...new Set(zoneOne)]).toEqual(["rgb(255, 0, 0)"]);
});

// ── The timers ──────────────────────────────────────────────────────────────
//
// hold-button:start fires at the press, validate at validate_at, early at
// early_action_at, and an early listener that takes the action over cancels
// success. The turf-monster confirm runs these at 0 / 750 / 1500 against a
// 2000 ms hold; the lab runs them at 0 / 150 / 400 against 600 so the lane stays
// quick, and the order and the gaps are what is asserted.

test("the hold's hooks fire in order, each at its own time", async ({ page }) => {
  await page.goto("/lab/hold_button");

  await page.locator('.hold-btn[data-hold-id="timed"]').hover();
  await page.mouse.down();
  // Wait on the event, not on a window: a slow runner moves every time later,
  // never earlier, so the floors below hold however loaded the machine is.
  await expect.poll(() => page.evaluate(() => (window.__holdLog || []).map(([name]) => name)),
    { timeout: 10000 }).toContain("early");
  // success would fire 600 ms after the press; give it that long and more to
  // prove the early listener cancelled it.
  await page.waitForTimeout(1500);
  await page.mouse.up();

  const log = await page.evaluate(() => window.__holdLog);
  expect(log.map(([name]) => name)).toEqual(["start", "validate", "early"]);
  const at = Object.fromEntries(log);
  expect(at.validate).toBeGreaterThanOrEqual(150);
  expect(at.early).toBeGreaterThanOrEqual(400);
  expect(at.early).toBeGreaterThan(at.validate);
});

test("the box lands one rung above the highest ancestor z-index", async ({ page }) => {
  await page.goto("/lab/hold_button");

  // The card is at z 200, a modal's rung. A box at the --z-raised floor would sit
  // under it, so this pins the ancestor walk rather than the floor.
  const box = page.locator('body > .hold-fizz-portal[data-fizz-portal-for="modal"]');
  await expect(box).toHaveCount(1);
  expect(await box.evaluate((el) => getComputedStyle(el).zIndex)).toBe("201");
});

test("a stack removed while parked off screen takes its box and observers with it", async ({ page }) => {
  await page.goto("/lab/hold_button");

  const box = page.locator('body > .hold-fizz-portal[data-fizz-portal-for="escaping"]');
  await expect(box).toHaveCount(1);
  const before = await page.evaluate(() => window.studioFizzPortal.count());

  // Park it: scroll the card well out of view, and wait for the box to hide.
  await page.evaluate(() => { document.body.style.minHeight = "500vh"; window.scrollTo(0, document.body.scrollHeight); });
  await expect.poll(() => box.evaluate((el) => el.style.visibility)).toBe("hidden");

  // Remove the stack while parked: no frame is running to notice.
  await page.evaluate(() => document.querySelector('[data-test="phone-escaping"]').remove());

  await expect(box).toHaveCount(0, { timeout: 5000 });
  expect(await page.evaluate(() => window.studioFizzPortal.count())).toBe(before - 1);
});
