const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The living style guide on a real phone (task edge-glow-phone-overflow).
//
// THE DEFECT. At 390px the style guide measured 402px wide. The cause was the
// .edge-rotate-glow bloom (its ::after). Its box reached 28px past the host on every
// side (4px ring + 4px + 2 x 10px bloom) to give the blur room before the mask cut it.
// A box that reaches past the viewport is scrollable overflow, also at opacity 0. The
// Modals section's glow cards are full width with a 16px gutter, so each one pushed
// the page 12px to the right (16 + 358 + 28 = 402). The fix cuts the bloom with
// clip-path, which is drawn after the filter but is not layout, so the bloom's box is
// now only 8px past the host. engine-motion.css section 9b has the detail.
//
// A REAL 390px. setViewportSize sets the DevTools device metrics, so the layout
// viewport is 390 CSS px. Do not use a window resize: headless Chrome does not make a
// window narrower than 500px. The assertion reads documentElement.clientWidth, not
// innerWidth. Under mobile emulation innerWidth grows to fit wide content, so a check
// against it passes on the broken page.
//
// CONTROL, run 2026-11-09: with the bloom rule back at its old inset, border and mask,
// every width spec is red at 402 against 390, and the bloom spec is red on the same
// width check. NOT a control for the glass rule: with only engine.css's glass inset
// put back at -28px these specs stay green, because the glass buttons sit inside
// clipped specimen cards. e2e/button_tricks.spec.js pins that inset at -8px.

const PHONE = { width: 390, height: 844 };

// Glass too, because a glass page changes the lit buttons and their bloom rule
// (engine.css). The CONTROL note above says what this does and does not prove.
for (const surface of ["", "glass"]) for (const scheme of ["light", "dark"]) {
  test(`the style guide does not scroll sideways at 390px (${scheme}${surface && ", " + surface})`, async ({ page }) => {
    const errors = watchPageErrors(page);
    await blockOffsiteRequests(page);
    await page.setViewportSize(PHONE);
    await page.goto(`/lab/style_nav${surface && "?surface=" + surface}`);
    // The lab layout hard-codes `dark`; light is the same page with the class off.
    await page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), scheme === "dark");

    const read = await page.evaluate(() => {
      const de = document.documentElement;
      return {
        clientWidth: de.clientWidth,
        scrollWidth: de.scrollWidth,
        bodyScrollWidth: document.body.scrollWidth,
        dark: de.classList.contains("dark"),
        surface: de.getAttribute("data-surface-style"),
        glowHosts: document.querySelectorAll(".edge-rotate-glow").length
      };
    });

    expect(read.dark).toBe(scheme === "dark");
    if (surface) expect(read.surface).toBe(surface);
    // The page is the one this defect was found on only while it has glow hosts.
    expect(read.glowHosts, "the style guide renders no .edge-rotate-glow host").toBeGreaterThan(0);
    expect(read.clientWidth).toBe(PHONE.width);
    expect(
      read.scrollWidth,
      `the style guide is ${read.scrollWidth}px wide in a ${read.clientWidth}px viewport`
    ).toBe(read.clientWidth);
    expect(read.bodyScrollWidth).toBe(read.clientWidth);
    expect(errors).toEqual([]);
  });
}

test("a full-width glow card keeps its bloom at 390px", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.setViewportSize(PHONE);
  await page.goto("/lab/style_nav");

  // A card shape as wide as the page allows, with a 16px gutter, as a phone layout
  // draws it.
  await page.evaluate(() => {
    const stage = document.createElement("div");
    stage.id = "stage";
    stage.style.cssText = "padding: 32px 16px";
    stage.innerHTML = '<div id="glow" class="edge-rotate-glow rounded-xl bg-surface p-5">Selected</div>';
    document.body.prepend(stage);
    window.scrollTo(0, 0);
  });

  const geometry = await page.evaluate(() => {
    const host = document.getElementById("glow");
    const after = getComputedStyle(host, "::after");
    return {
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      hostRight: Math.round(host.getBoundingClientRect().right),
      filter: after.filter,
      clipPath: after.clipPath
    };
  });
  expect(geometry.hostRight).toBe(PHONE.width - 16);
  expect(geometry.scrollWidth).toBe(geometry.clientWidth);
  expect(geometry.filter).toContain("blur");
  expect(geometry.clipPath).toContain("polygon");

  // The bloom still paints past the ring: the band from 8px to 16px outside the
  // host (the ring is 4px) changes when the bloom is hidden.
  const band = { x: 0, y: 32 + 8, width: 8, height: 40 };
  const withBloom = await page.screenshot({ clip: band });
  await page.addStyleTag({ content: "#glow::after { display: none !important; }" });
  const withoutBloom = await page.screenshot({ clip: band });
  expect(withBloom.equals(withoutBloom), "the bloom paints nothing past the ring at 390px").toBe(false);
});
