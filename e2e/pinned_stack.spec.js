const { test, expect } = require("@playwright/test");
const { watchPageErrors, expectStickyChromeIsLive, blockOffsiteRequests } = require("./helpers");

// THE PINNED STACK, COMPOSED IN CSS.
//
// nav_offset_contract_test pins the wiring — that data-pin elements are found,
// that each publishes its height and clamped bottom, that they share one
// observer and one frame. None of that says the numbers are USABLE, and the
// whole promise of this primitive is that a consumer positions off the stack
// with a CSS expression instead of the hand-rolled Alpine arithmetic on
// mcritchie-studio's /deployments (`laneTop = site header height + strip
// height`, behind its own ResizeObserver on .vt-pinned-header).
//
// So this asserts the promise itself: a plain `top: max(...)` lands on the
// bottom of the pinned stack, and a HIDDEN layer drops out of it. That second
// half is what removes the need for anyone to declare a stacking order.
test("a consumer positions off the pinned stack with max(), and a hidden layer drops out", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/lab/bar_stack");
  await expectStickyChromeIsLive(page, expect);

  const result = await page.evaluate(async () => {
    const root = () => getComputedStyle(document.documentElement);
    const g = (n) => root().getPropertyValue(n).trim();

    // A second pinned layer, under the header the engine navbar already marks.
    const strip = document.createElement("div");
    strip.setAttribute("data-pin", "apps");
    strip.style.cssText = "position:fixed;left:0;right:0;top:0;height:48px";
    document.body.appendChild(strip);
    document.dispatchEvent(new CustomEvent("turbo:before-stream-render"));
    await new Promise((r) => setTimeout(r, 250));

    // The consumer. No JS: one CSS expression over the layers.
    const probe = document.createElement("div");
    probe.style.cssText =
      "position:fixed;height:4px;top:max(var(--pin-nav-bottom,0px),var(--pin-apps-bottom,0px))";
    document.body.appendChild(probe);
    await new Promise((r) => requestAnimationFrame(r));

    const shown = { top: getComputedStyle(probe).top, navBottom: g("--nav-bottom"), pinNav: g("--pin-nav-bottom") };

    strip.style.display = "none";
    document.dispatchEvent(new CustomEvent("turbo:before-stream-render"));
    await new Promise((r) => setTimeout(r, 250));
    const hidden = { top: getComputedStyle(probe).top, pinApps: g("--pin-apps-bottom") };

    // THE THIRD WAY A LAYER GOES AWAY, and the one display:none does not cover.
    // A removed node cannot be measured at 0 by anything, so unless the
    // publisher CLEARS what departed, its last value stands forever and the
    // consumer sits at the height of a strip that is gone. Review measured a
    // removed 300px strip holding the property at 300px against a real stack
    // bottom of 160px.
    //
    // The event order matters and this spec had it wrong: real Turbo fires
    // turbo:before-stream-render and THEN patches the DOM. So the removal
    // happens first here, and the event follows it.
    strip.style.display = "";
    document.dispatchEvent(new CustomEvent("turbo:before-stream-render"));
    await new Promise((r) => setTimeout(r, 250));
    strip.remove();
    document.dispatchEvent(new CustomEvent("turbo:before-stream-render"));
    await new Promise((r) => setTimeout(r, 250));
    const removed = { top: getComputedStyle(probe).top, pinApps: g("--pin-apps-bottom") };

    return { shown, hidden, removed };
  });

  // THE HEADER'S TWO NAMES AGREE. --nav-bottom is the legacy name a live
  // consumer (studio/_sidebar_panel) already positions off; --pin-nav-bottom is
  // the same edge under the general contract. They must not drift.
  expect(result.shown.pinNav).toBe(result.shown.navBottom);

  // WITH BOTH LAYERS UP, the consumer sits on the LOWER edge. The header's
  // bottom is below the 48px strip on this page, so max() picks the header.
  expect(result.shown.top).toBe(result.shown.navBottom);

  // HIDDEN LAYER DROPS OUT. It measures 0 and stops contributing, so the
  // consumer is unmoved — no stacking order was ever declared.
  expect(result.hidden.pinApps).toBe("0px");
  expect(result.hidden.top).toBe(result.shown.top);

  // REMOVED LAYER CLEARS. The property must be gone, not stuck at its last
  // value, and the consumer must sit back on the header alone.
  expect(result.removed.pinApps).toBe("");
  expect(result.removed.top).toBe(result.shown.navBottom);

  expect(errors).toEqual([]);
});

// THE HOST-OWNED HEADER, IN A BROWSER — the regression that shipped.
//
// A consumer that owns its header does not carry data-pin on it, and both live
// consumers are exactly that (turf-monster layouts/_navbar, mcritchie-studio
// layouts/application). Built from [data-pin] alone, such a header is never
// measured, so --nav-h and --nav-bottom never publish — and studio/_sidebar_panel
// positions off --nav-bottom while turf's contest board takes its
// scroll-margin-top from --nav-h. Review measured the drawer 82px out of place
// and the board 114px, with neither tracking the collapse any more.
//
// The engine's own navbar DOES carry data-pin, which is why every unit test and
// this lab published fine over the broken build. So this strips the attribute to
// stand in for a host-owned header, and asserts the legacy pair survives it.
test("a header with no data-pin still publishes --nav-h and --nav-bottom", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/lab/bar_stack");
  await expectStickyChromeIsLive(page, expect);

  const result = await page.evaluate(async () => {
    const g = (n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
    const header = document.querySelector("header");

    // Stand in for a consumer that owns its header: no data-pin anywhere.
    header.removeAttribute("data-pin");
    document.documentElement.style.removeProperty("--nav-h");
    document.documentElement.style.removeProperty("--nav-bottom");
    document.dispatchEvent(new CustomEvent("turbo:before-stream-render"));
    await new Promise((r) => setTimeout(r, 250));
    const atRest = { navH: g("--nav-h"), navBottom: g("--nav-bottom") };

    // AND IT MUST KEEP TRACKING. Publishing once and going quiet would satisfy
    // a value check while the drawer drifted through every collapse.
    for (let i = 0; i < 20; i++) {
      window.scrollBy(0, 8);
      await new Promise((r) => requestAnimationFrame(r));
    }
    await new Promise((r) => setTimeout(r, 250));
    const collapsed = { navH: g("--nav-h"), navBottom: g("--nav-bottom") };
    return { atRest, collapsed };
  });

  expect(result.atRest.navH, "--nav-h must publish for a header that carries no data-pin").not.toBe("");
  expect(result.atRest.navBottom, "--nav-bottom must publish for a header that carries no data-pin").not.toBe("");
  expect(
    result.collapsed.navH,
    `--nav-h must follow the collapse (${result.atRest.navH} -> ${result.collapsed.navH})`
  ).not.toBe(result.atRest.navH);

  expect(errors).toEqual([]);
});
