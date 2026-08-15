const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The email manager's two preview frames must be the SAME SIZE.
//
// THE BUG. /admin/emails/:key shows the artwork beside the banner as it arrives.
// The artwork frame is fluid — it fills its grid column. The banner is the
// EMAIL's own markup, a fixed 600px table, because an inbox has no responsive
// layout. Two different sizing models in one row: measured at a 1500px viewport
// they came out 467x156 and 467x202, and the 600px table was additionally being
// clipped to the column, so the "preview" was the left two-thirds of the banner.
//
// WHY NO OTHER TIER CAN SEE IT. Every markup assertion about this page passed
// while it was wrong, and would go on passing. The defect is a RELATIONSHIP
// between two rendered boxes — it exists only once a browser has done layout,
// and "both frames declare aspect-ratio: 3" is exactly the kind of proxy that
// was true the whole time the boxes disagreed. Reading the class list cannot
// distinguish a frame that is 156px tall from one that is 202px tall.
//
// WHY MORE THAN ONE WIDTH. At a single viewport the two can coincide by luck —
// which is most of how this shipped. The relationship has to hold as the column
// reflows, so it is asserted across a wide, a medium and a narrow layout.
test.describe("email manager preview frames", () => {
  const WIDTHS = [1500, 1100, 800];

  test("both frames render at identical size across widths", async ({ page }) => {
    const errors = watchPageErrors(page);

    await blockOffsiteRequests(page);
    for (const width of WIDTHS) {
      await page.setViewportSize({ width, height: 1000 });
      await page.goto("/lab/email_banner_frames");
      // The scaler runs on load and on resize; settle before measuring.
      await page.waitForTimeout(150);

      const box = await page.evaluate(() => {
        const rect = (selector) => {
          const el = document.querySelector(selector);
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return { w: Math.round(r.width), h: Math.round(r.height) };
        };
        return {
          artwork: rect("[data-email-artwork-frame]"),
          banner: rect("[data-email-banner-frame]"),
          painted: rect("[data-email-banner-preview] table")
        };
      });

      expect(box.artwork, `no artwork frame at ${width}`).not.toBeNull();
      expect(box.banner, `no banner frame at ${width}`).not.toBeNull();

      expect(box.banner.w, `width differs at ${width}px`).toBe(box.artwork.w);
      expect(box.banner.h, `height differs at ${width}px`).toBe(box.artwork.h);

      // The banner must FILL its frame, not sit clipped inside it. Allowing 4px
      // covers the frame's 1px border on each side; anything more means the
      // 600px table is overflowing again, which is the original defect.
      expect(
        Math.abs(box.painted.w - box.banner.w),
        `banner painted ${box.painted.w} inside a ${box.banner.w} frame at ${width}px`
      ).toBeLessThanOrEqual(4);
    }

    expect(errors, `page errors: ${errors.join(", ")}`).toHaveLength(0);
  });

  // At 1:1 this preview is exactly the 600px a recipient sees. Scaling past that
  // would show the operator a banner larger than any inbox renders — a preview
  // that misleads in the other direction.
  test("the banner is never scaled above its real size", async ({ page }) => {
    await page.setViewportSize({ width: 2200, height: 1000 });
    await page.goto("/lab/email_banner_frames");
    await page.waitForTimeout(150);

    const scale = await page.evaluate(() => {
      const el = document.querySelector("[data-email-banner-preview]");
      const t = getComputedStyle(el).transform;
      if (!t || t === "none") return 1;
      return parseFloat(t.match(/matrix\(([^,]+)/)[1]);
    });

    expect(scale).toBeLessThanOrEqual(1.0001);
  });
});
