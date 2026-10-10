const { test, expect } = require("@playwright/test");

// [e2e] A chip's text clears WCAG AA on its own tint, in both themes, as the
// browser paints it, and a primary chip is painted in the primary hue.
//
// test/lib/chip_ink_contrast_test.rb measures the hexes the theme resolver
// emits. Between those hexes and the screen sit a CSS custom property, a
// utility the shared preset has to mint, and a translucent tint the browser
// composites over whichever surface the chip lands on. A chip whose utility
// never compiled inherits the body colour and still reads as "text on a tint",
// so each spec reads the painted colours.
//
// Measured: the five status tones and the `primary` scheme, on the four surface
// tokens. The other legacy schemes paint fixed Tailwind palette colours, which
// no theme token derives; they are not graded here.
//
// CONTROLS, each run against this file:
//   - BadgeComponent's primary tone back on text-heading: "is painted in the
//     primary hue" fails in every palette.
//   - the preset's `primary-ink` text colour removed: the same spec fails, the
//     chip inherits the body colour.
//   - status_ink tuned to a 0.10 tint alone: the moms-app spec fails, its
//     primary chip at 4.48:1 on the dark surface.

const AA = 4.5;
const PALETTES = ["engine-default", "turf-monster", "cyvasse", "mcritchie-industries", "moms-app"];
const GRADED = ["tone-success", "tone-warning", "tone-danger", "tone-primary", "tone-muted", "scheme-primary"];

// Runs in the page, over a screenshot of it. For every graded chip: the text
// colour the browser computed, and the pixel it painted inside the chip's left
// padding, which is the tint already composited over the surface under it.
// Reading the pixel matters: Chromium paints a 10% fill at 26/255, so a tint
// recomputed here at 0.10 would grade a lighter chip than the one on screen.
const MEASURE = async ({ graded, shot }) => {
  const bitmap = await createImageBitmap(await (await fetch(`data:image/png;base64,${shot}`)).blob());
  const cv = document.createElement("canvas");
  cv.width = bitmap.width;
  cv.height = bitmap.height;
  const cx = cv.getContext("2d", { willReadFrequently: true });
  cx.drawImage(bitmap, 0, 0);
  const scale = bitmap.width / document.documentElement.scrollWidth;
  const pixel = (x, y) => {
    const d = cx.getImageData(Math.round((x + window.scrollX) * scale), Math.round((y + window.scrollY) * scale), 1, 1).data;
    return { r: d[0], g: d[1], b: d[2] };
  };
  const parse = (css) => {
    const [r, g, b] = css.match(/[\d.]+/g).map(Number);
    return { r, g, b };
  };
  const lum = (c) => {
    const f = (v) => (v / 255 <= 0.03928 ? v / 255 / 12.92 : Math.pow((v / 255 + 0.055) / 1.055, 2.4));
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  const ratio = (a, b) => {
    const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  };
  const hue = (c) => {
    const [r, g, b] = [c.r / 255, c.g / 255, c.b / 255];
    const max = Math.max(r, g, b);
    const d = max - Math.min(r, g, b);
    if (d === 0) return null;
    const h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    return (h * 60 + 360) % 360;
  };
  const fromHex = (h) => ({ r: parseInt(h.slice(1, 3), 16), g: parseInt(h.slice(3, 5), 16), b: parseInt(h.slice(5, 7), 16) });
  const hex = (c) => `#${[c.r, c.g, c.b].map((v) => v.toString(16).padStart(2, "0")).join("")}`;

  const rows = [];
  for (const section of document.querySelectorAll("[data-chip-surface]")) {
    const box = section.getBoundingClientRect();
    const surface = pixel(box.left + 8, box.top + 8);
    for (const name of graded) {
      const chip = section.querySelector(`[data-chip="${name}"] .badge`);
      if (!chip) {
        rows.push({ surface: section.dataset.chipSurface, chip: name, missing: true });
        continue;
      }
      const color = getComputedStyle(chip).color;
      // An ink is an opaque rgb(); anything else is a colour this cannot grade.
      if (!/^rgb\(\d+, \d+, \d+\)$/.test(color)) {
        rows.push({ surface: section.dataset.chipSurface, chip: name, ungraded: color });
        continue;
      }
      const rect = chip.getBoundingClientRect();
      const painted = pixel(rect.left + 4, rect.top + rect.height / 2);
      const ink = parse(color);
      rows.push({
        surface: section.dataset.chipSurface,
        chip: name,
        ratio: +ratio(ink, painted).toFixed(2),
        tinted: hex(painted) !== hex(surface),
        hue: hue(ink),
        ink: hex(ink),
        on: hex(painted),
      });
    }
  }
  const root = getComputedStyle(document.documentElement);
  return {
    rows,
    primaryHue: hue(fromHex(root.getPropertyValue("--color-primary").trim())),
    heading: root.getPropertyValue("--color-text").trim().toLowerCase(),
    pageBackground: getComputedStyle(document.body).backgroundColor,
  };
};

// The lab layout hard-codes `dark`; light is the same page with the class off.
async function inTheme(page, theme) {
  await page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), theme === "dark");
  const shot = (await page.screenshot({ fullPage: true })).toString("base64");
  return page.evaluate(MEASURE, { graded: GRADED, shot });
}

async function openLab(page, palette) {
  await page.goto(palette === "engine-default" ? "/lab/chips" : `/lab/chips?palette=${palette}`);
  await expect(page.locator("[data-chip-surface]")).toHaveCount(4);
}

const hueDistance = (a, b) => Math.min(Math.abs(a - b), 360 - Math.abs(a - b));

for (const palette of PALETTES) {
  test(`${palette}: every graded chip clears AA on its tint in dark and in light`, async ({ page }) => {
    await openLab(page, palette);
    const backgrounds = [];

    for (const theme of ["dark", "light"]) {
      const { rows, pageBackground } = await inTheme(page, theme);
      backgrounds.push(pageBackground);

      expect(rows.filter((row) => row.missing || row.ungraded), `${theme}: chips not rendered or not gradable`).toEqual([]);
      expect(rows).toHaveLength(4 * GRADED.length);
      // A role chip paints a tint over its surface; one that matches the bare
      // surface is an uncompiled class, or a sample that missed the chip.
      const untinted = rows.filter((row) => row.chip !== "tone-muted" && !row.tinted);
      expect(untinted, `${theme}: role chips painting no tint`).toEqual([]);

      const failing = rows.filter((row) => row.ratio < AA);
      expect(failing, `${palette} ${theme}: chips under ${AA}:1`).toEqual([]);
    }

    expect(backgrounds[0], "the light pass measured the dark page again").not.toBe(backgrounds[1]);
  });
}

test("a primary chip is painted in the primary hue, not the heading colour, in both themes", async ({ page }) => {
  for (const palette of PALETTES) {
    await openLab(page, palette);

    for (const theme of ["dark", "light"]) {
      const { rows, primaryHue, heading } = await inTheme(page, theme);
      const primaries = rows.filter((row) => row.chip === "tone-primary" || row.chip === "scheme-primary");

      expect(primaries).toHaveLength(8);
      expect(heading, `${palette} ${theme}: --color-text is not a hex`).toMatch(/^#[0-9a-f]{6}$/);
      expect(primaryHue, `${palette}: --color-primary has no hue to compare`).not.toBeNull();
      for (const row of primaries) {
        const where = `${palette} ${theme} ${row.chip} on ${row.surface} (${row.ink})`;
        expect(row.hue, `${where} is a grey`).not.toBeNull();
        expect(hueDistance(row.hue, primaryHue), `${where} hue against --color-primary`).toBeLessThanOrEqual(8);
        expect(row.ink, `${where} is the heading colour`).not.toBe(heading);
      }
    }
  }
});
