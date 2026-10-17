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

// ============================================================================
// THE SAME-FRAME PROPERTY — the defect this primitive was rebuilt for.
//
// WHAT SHIPPED, measured on mcritchie-studio's production /deployments on
// 2026-09-07. The publisher was WOKEN by its ResizeObserver and then DEFERRED
// the write to requestAnimationFrame. A frame runs
//
//     rAF callbacks -> style/layout -> ResizeObserver callbacks -> paint
//
// so a write made in rAF lands at the top of the NEXT frame: the frame in which
// a layer actually appeared or disappeared painted with the PREVIOUS frame's
// number, every time. On the live board that showed as the deploy lane headers
// slamming 99px and back on a page nobody was touching — two Turbo broadcasts of
// the applications row produced four jumps in 240ms with scrollY, document
// height and nav height all constant.
//
// WHY THIS CANNOT BE A UNIT CHECK. nav_offset_contract_test pins the SHAPE — the
// observer callback publishes outright and defers to nothing. It cannot say the
// number is RIGHT WHEN IT IS READ, because that is a fact about when a browser
// runs work inside a frame. Only a browser can answer it.
//
// HOW IT IS MEASURED. A ResizeObserver created LAST runs after every observer
// registered before it, including the publisher's own — and RO callbacks are the
// last point in a frame at which anything is observable before paint. So what a
// consumer's box reads there IS what the frame paints. Sampling in rAF instead
// would read the NEXT frame and report the bug as fixed.
test("a layer appearing or disappearing moves the stack in the SAME frame", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/lab/bar_stack");
  await expectStickyChromeIsLive(page, expect);

  const result = await page.evaluate(async () => {
    const strip = document.createElement("div");
    strip.setAttribute("data-pin", "apps");
    // TALLER THAN THE HEADER, on purpose. A layer that never becomes the lowest
    // edge cannot move --pin-stack-bottom at all, and the test would pass
    // against a publisher that had stopped composing entirely.
    strip.style.cssText = "position:fixed;left:0;right:0;top:0;height:600px";
    document.body.appendChild(strip);
    document.dispatchEvent(new CustomEvent("turbo:before-stream-render"));
    await new Promise((r) => setTimeout(r, 250));

    // THE CONSUMER. One CSS expression over ONE published value — no max(), no
    // layer named. This is the whole point of the primitive.
    const probe = document.createElement("div");
    probe.style.cssText = "position:fixed;left:0;height:4px;top:var(--pin-stack-bottom,0px)";
    document.body.appendChild(probe);
    await new Promise((r) => setTimeout(r, 100));

    const navBottom = document.querySelector("header").getBoundingClientRect().bottom;
    const samples = [];

    // THE INSTRUMENT. Created last, so it runs after the publisher's observer in
    // the same frame; what it reads is what this frame paints.
    const spy = new ResizeObserver(() => {
      const shown = getComputedStyle(strip).display !== "none";
      samples.push({
        truth: Math.round(shown ? 600 : navBottom),
        painted: Math.round(probe.getBoundingClientRect().top),
      });
    });
    spy.observe(strip);
    await new Promise((r) => setTimeout(r, 100));
    samples.length = 0;

    for (let i = 0; i < 8; i++) {
      strip.style.display = i % 2 === 0 ? "none" : "block";
      await new Promise((r) => setTimeout(r, 120));
    }
    spy.disconnect();

    // While the strip is up it is the lowest edge, so it owns the stack bottom;
    // --pin-apps-top must still exclude it and sit on the header alone.
    strip.style.display = "block";
    await new Promise((r) => setTimeout(r, 150));
    const root = getComputedStyle(document.documentElement);
    const composed = {
      stack: root.getPropertyValue("--pin-stack-bottom").trim(),
      appsTop: root.getPropertyValue("--pin-apps-top").trim(),
      navBottom: root.getPropertyValue("--pin-nav-bottom").trim(),
    };

    strip.remove();
    document.dispatchEvent(new CustomEvent("turbo:before-stream-render"));
    await new Promise((r) => setTimeout(r, 250));
    const afterRemoval = {
      stack: getComputedStyle(document.documentElement).getPropertyValue("--pin-stack-bottom").trim(),
      probeTop: Math.round(probe.getBoundingClientRect().top),
      navBottom: Math.round(navBottom),
    };

    return { samples, composed, afterRemoval };
  });

  // THE ASSERTION. Not "it settles eventually" — every changing frame paints the
  // right number. Against the rAF-deferred publisher this was wrong on 8/8.
  expect(result.samples.length).toBeGreaterThan(4);
  const wrong = result.samples.filter((s) => s.painted !== s.truth);
  expect(
    wrong,
    `every frame in which a layer changed must paint the new stack bottom; ` +
      `${wrong.length}/${result.samples.length} painted the previous frame's`
  ).toEqual([]);

  // A LAYER DOES NOT STACK ON ITSELF. --pin-stack-bottom includes the strip's own
  // edge; --pin-apps-top is the bottom of everything ABOVE it, which here is the
  // header alone. Collapse the two and a layer positioned off its own top chases
  // itself down the page on every publish.
  expect(result.composed.stack).toBe("600px");
  expect(result.composed.appsTop).toBe(result.composed.navBottom);
  expect(result.composed.appsTop).not.toBe(result.composed.stack);

  // AND A REMOVED LAYER LEAVES THE STACK. Nothing is left to measure, so without
  // an explicit clear the consumer sits at the height of a strip that is gone.
  expect(result.afterRemoval.stack).toBe(`${result.afterRemoval.navBottom}px`);
  expect(result.afterRemoval.probeTop).toBe(result.afterRemoval.navBottom);

  expect(errors).toEqual([]);
});

// THE MOTION WRITE (task smooth-navbar-collapse). Every stack value is an
// inherited custom property on documentElement, so a root write restyles the
// whole document; on turf-monster's 2,000-element contest page that was 8.7ms a
// write, every frame the header's bottom edge moved, and the collapse dropped
// frames on a 120Hz screen. While a scroll is in motion the publisher writes
// only the elements that read the stack live (here the link sidebar panel,
// whose inline style positions off --nav-bottom), and writes the root once the
// scroll has settled.
test("in motion the stack reaches its readers without writing the root, and settles onto the root", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/lab/bar_stack?one_row=1&sidebar=1");
  await expectStickyChromeIsLive(page, expect);

  const run = await page.evaluate(async () => {
    const root = document.documentElement;
    const panel = document.querySelector("#studio-link-sidebar");
    const header = document.querySelector("header");
    let rootWrites = 0;
    new MutationObserver(() => rootWrites++).observe(root, { attributes: true, attributeFilter: ["style"] });
    const frame = () => new Promise((r) => requestAnimationFrame(r));
    const tracked = [];
    for (const s of [8, 12, 16, 20, 20, 16, 12, 8]) {
      window.scrollBy(0, s);
      await frame();
      await frame();
      tracked.push({
        panel: panel.style.getPropertyValue("--nav-bottom"),
        header: Math.max(0, header.getBoundingClientRect().bottom),
        // The script reader's live read, and what it used to read: the root.
        live: window.studioPinnedStack.bottom(),
        root: parseFloat(getComputedStyle(root).getPropertyValue("--pin-stack-bottom")),
      });
    }
    const inMotion = rootWrites;
    await new Promise((r) => setTimeout(r, 400));
    return {
      inMotion,
      tracked,
      settledRoot: root.style.getPropertyValue("--nav-bottom"),
      settledPanel: panel.style.getPropertyValue("--nav-bottom"),
      headerBottom: Math.max(0, header.getBoundingClientRect().bottom),
    };
  });

  expect(run.inMotion, "the root was written while the scroll was in motion").toBe(0);
  // The reader tracked the header's bottom edge, frame by frame.
  for (const t of run.tracked) expect(Math.abs(parseFloat(t.panel) - t.header), JSON.stringify(run.tracked)).toBeLessThanOrEqual(1);
  // A SCRIPT reader gets the same edge from the live read, on call, every
  // frame. The root lags it while the scroll is in motion, which is why a
  // script must not read the root (Cyvasse's phone dock did).
  for (const t of run.tracked) expect(Math.abs(t.live - t.header), JSON.stringify(run.tracked)).toBeLessThanOrEqual(1);
  expect(run.tracked.some((t) => Math.abs(t.root - t.header) > 1), `the root lagged in motion ${JSON.stringify(run.tracked)}`).toBe(true);
  // Settled: the root holds the value and the reader inherits it again.
  expect(Math.abs(parseFloat(run.settledRoot) - run.headerBottom)).toBeLessThanOrEqual(1);
  expect(run.settledPanel).toBe("");
});

// Leaving MID-SCROLL, while the followers still hold their copies: Turbo
// caches the page, and a restored page must carry none of them, or a reader
// would keep a stale copy over the root's live value.
test("a page left mid-scroll is cached with no follower copies", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/lab/toast_flash");
  await page.evaluate(() => window.Turbo.visit("/lab/bar_stack_turbo"));
  await expect(page.locator("[data-test='lab-body']")).toBeVisible();
  await expectStickyChromeIsLive(page, expect);

  const seen = await page.evaluate(async () => {
    const panel = () => document.querySelector("#studio-link-sidebar");
    // Registered after the publisher's, so it reads what Turbo is about to
    // copy into its snapshot cache.
    window.__cached = null;
    document.addEventListener("turbo:before-cache", () => {
      window.__cached = panel().style.getPropertyValue("--nav-bottom");
    }, { once: true });
    const frame = () => new Promise((r) => requestAnimationFrame(r));
    for (const s of [10, 14, 18, 14, 10]) { window.scrollBy(0, s); await frame(); }
    const midScroll = panel().style.getPropertyValue("--nav-bottom");
    window.Turbo.visit("/lab/toast_flash");
    return midScroll;
  });
  expect(seen, "mid-scroll, the sidebar panel held a copy").not.toBe("");

  await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
  expect(await page.evaluate(() => window.__cached), "the snapshot carried a follower copy").toBe("");
});
