const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The link sidebar's keyboard focus ring clears 3:1 against both colours beside
// it (WCAG 1.4.11 non-text contrast, and the 2.4.13 focus-appearance bar), in dark,
// light and glass, on every consumer palette's primary, as the browser paints it.
//
// The ring was ring-primary/40: a 40% primary composited over the panel, which
// measured 1.5 to 1.8:1. A computed style cannot grade a translucent ring, so every
// colour here is a pixel of a screenshot: the ring, the fill inside it and the
// fill outside it.
//
// Graded: a body row (an inset ring), the panel's close button and the Log out row
// (rings outside the box), and under glass the current row, whose ring is its own
// white outline on its violet fill (e2e/sidebar_glass.spec.js pins its shape).
//
// CONTROL: the rows back on focus-visible:ring-primary/40 fail every palette, dark
// and light, solid and glass, at 1.3 to 2.0:1.

const MIN = 3;
const PALETTES = ["engine-default", "turf-monster", "cyvasse", "mcritchie-industries", "moms-app"];

const MEASURE = async ({ shot, target, inset, outline }) => {
  const bitmap = await createImageBitmap(await (await fetch(`data:image/png;base64,${shot}`)).blob());
  const cv = document.createElement("canvas");
  cv.width = bitmap.width;
  cv.height = bitmap.height;
  const cx = cv.getContext("2d", { willReadFrequently: true });
  cx.drawImage(bitmap, 0, 0);
  const scale = bitmap.width / window.innerWidth;
  const pixel = (x, y) => {
    const d = cx.getImageData(Math.round(x * scale), Math.round(y * scale), 1, 1).data;
    return { r: d[0], g: d[1], b: d[2] };
  };
  const lum = (c) => {
    const f = (v) => (v / 255 <= 0.03928 ? v / 255 / 12.92 : Math.pow((v / 255 + 0.055) / 1.055, 2.4));
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  const ratio = (a, b) => {
    const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  };
  const hex = (c) => `#${[c.r, c.g, c.b].map((v) => v.toString(16).padStart(2, "0")).join("")}`;

  const el = document.querySelector(target);
  const r = el.getBoundingClientRect();
  // Down the top edge, clear of any label: a ring two pixels wide, inside the box
  // for an inset ring and outside it otherwise.
  // The glass current row's ring is a 2px outline 4px inside its edge, with the row's
  // own fill on both sides of it.
  const x = inset ? r.left + 8 : r.left + r.width / 2;
  const y = outline ? { ring: r.top + 3, inner: r.top + 6, outer: r.top + 1 }
    : inset ? { ring: r.top + 1, inner: r.top + 4, outer: r.top - 2 }
    : { ring: r.top - 1, inner: r.top + 2, outer: r.top - 4 };
  const ring = pixel(x, y.ring);
  const inner = pixel(x, y.inner);
  const outer = pixel(x, y.outer);
  return {
    ring: hex(ring), inner: hex(inner), outer: hex(outer),
    ratio: +Math.min(ratio(ring, inner), ratio(ring, outer)).toFixed(2),
  };
};

const TARGETS = [
  { name: "row", target: "#studio-link-sidebar nav a:not([aria-current])", inset: true },
  { name: "close", target: "#studio-link-sidebar [data-link-sidebar-close]", inset: false },
  { name: "log out", target: "#studio-link-sidebar a[href$='logout'], #studio-link-sidebar a[href*='sign_out'], #studio-link-sidebar a[href*='logout']", inset: false },
];

const CURRENT_GLASS = { name: "current", target: "#studio-link-sidebar nav a[aria-current='page']", outline: true };

async function grade(page, { palette, glass, dark }) {
  await page.goto(`/lab/sidebar_panels?sidebar=1&signed_in=1&palette=${palette}${glass ? "&glass=1" : ""}`);
  await page.waitForFunction(() => window.Alpine);
  await page.locator("[data-link-sidebar-trigger]:visible").first().click();
  await expect(page.locator("#studio-link-sidebar")).toBeVisible();
  await page.evaluate((on) => document.documentElement.classList.toggle("dark", on), dark);
  await page.mouse.move(1, 1);
  await page.waitForTimeout(450);

  const rows = [];
  const targets = glass ? [...TARGETS, CURRENT_GLASS] : TARGETS;
  for (const { name, target, inset, outline } of targets) {
    // A key press first, so the focus that follows is keyboard focus.
    await page.keyboard.press("Shift");
    await page.locator(target).first().evaluate((el) => el.focus());
    await expect(page.locator(target).first()).toBeFocused();
    expect(await page.locator(target).first().evaluate((el) => el.matches(":focus-visible"))).toBe(true);
    await page.waitForTimeout(200); // the rows' colour transition
    const shot = (await page.screenshot()).toString("base64");
    rows.push({ name, ...(await page.evaluate(MEASURE, { shot, target, inset, outline })) });
  }
  return rows;
}

test("the sidebar's focus ring clears 3:1 beside it, in dark, light and glass, on every palette", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await blockOffsiteRequests(page);
  const results = [];

  for (const palette of PALETTES) {
    for (const glass of [false, true]) {
      for (const dark of [true, false]) {
        const where = `${palette} ${glass ? "glass" : "solid"} ${dark ? "dark" : "light"}`;
        for (const row of await grade(page, { palette, glass, dark })) results.push({ where, ...row });
      }
    }
  }

  console.log(results.map((r) => `${r.where.padEnd(36)} ${r.name.padEnd(8)} ${String(r.ratio).padStart(5)}:1  ring ${r.ring} in ${r.inner} out ${r.outer}`).join("\n"));
  const failing = results.filter((r) => !(r.ratio >= MIN));
  expect(failing, "rings under 3:1").toEqual([]);
});
