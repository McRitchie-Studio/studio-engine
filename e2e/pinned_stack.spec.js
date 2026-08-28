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

    return { shown, hidden };
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

  expect(errors).toEqual([]);
});
