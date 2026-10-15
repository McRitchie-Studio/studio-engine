const { test, expect } = require("@playwright/test");

// [e2e] Tints and shades, as the browser paints them.
//
// A SHADE lays the dark base over media and light ink reads on it; a TINT lays
// the light base over media and dark ink reads on it. `.scrim` alone is
// theme-aware; `.scrim-tint` / `.scrim-shade` force a tone in either theme;
// `.scrim-soft` / `.scrim-strong` step the strength from the tone's default.
//
// test/lib/scrim_contract_test.rb reads engine.css as text and pins the
// numbers. What only a browser can say is whether the cascade and inheritance
// deliver them: the tone is a custom property inherited from :root, .dark or a
// tone class on an ANCESTOR, the wash and the text are siblings that must both
// take it, and the forced class has to beat the theme default it sits under.
// So each spec reads the computed gradient stops and ink off the lab page,
// which renders the style guide's own style/_scrims group.
//
// CONTROLS, each run against this file:
//   - `.dark { ... }` removed from engine.css: the theme-aware, strength and
//     custom-palette specs fail in dark mode (the wash stays the tint).
//   - the tone class moved from the specimen stage onto the wash alone: the
//     forced spec fails on "dark .scrim-tint: ink", which no longer inherits.
//   - ThemeResolver#to_css dropping the tone vars from the light block: the
//     custom-palette spec fails, light mode falling back to the engine shade.

const DEFAULT_SHADE = "#1a1535";
const DEFAULT_TINT = "#f8fafc";

const hexToRgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));

// Every specimen's three gradient stops, ink colour, and muted ink colour and
// weight, in the theme `dark` selects.
async function read(page, dark) {
  await page.evaluate((d) => document.documentElement.classList.toggle("dark", d), dark);
  return page.evaluate(() => {
    const rgb = (css) => css.match(/[\d.]+/g).slice(0, 3).map(Number);
    const stops = (css) => [...css.matchAll(/color\(srgb ([\d.e-]+) ([\d.e-]+) ([\d.e-]+)(?: \/ ([\d.]+))?\)/g)].map((m) => ({
      rgb: [m[1], m[2], m[3]].map((v) => Math.round(Number(v) * 255)),
      alpha: m[4] === undefined ? 1 : Number(m[4]),
    }));
    const root = getComputedStyle(document.documentElement);
    const token = (name) => root.getPropertyValue(name).trim().toLowerCase();
    const out = { tokens: {} };
    for (const name of ["--color-shade", "--color-tint", "--color-shade-ink", "--color-shade-ink-muted", "--color-tint-ink", "--color-tint-ink-muted"]) {
      out.tokens[name] = token(name);
    }
    for (const el of document.querySelectorAll("[data-scrim-specimen]")) {
      const muted = getComputedStyle(el.querySelector("[data-scrim-ink-muted]"));
      out[el.dataset.scrimSpecimen] = {
        stops: stops(getComputedStyle(el.querySelector("[data-scrim-wash]")).backgroundImage),
        ink: rgb(getComputedStyle(el.querySelector("[data-scrim-ink]")).color),
        muted: rgb(muted.color),
        weight: muted.fontWeight,
      };
    }
    return out;
  });
}

// A specimen painted in `color` at edge / mid / edge alpha.
function expectWash(specimen, color, [edge, mid], where) {
  expect(specimen.stops.map((s) => s.rgb), `${where}: wash colour`).toEqual([color, color, color]);
  const alphas = specimen.stops.map((s) => Math.round(s.alpha * 100));
  expect(alphas, `${where}: wash strength`).toEqual([edge, mid, edge]);
}

function expectInk(specimen, tokens, tone, where) {
  expect(specimen.ink, `${where}: ink`).toEqual(hexToRgb(tokens[`--color-${tone}-ink`]));
  expect(specimen.muted, `${where}: muted ink`).toEqual(hexToRgb(tokens[`--color-${tone}-ink-muted`]));
  expect(specimen.weight, `${where}: muted weight`).toBe(tone === "tint" ? "600" : "400");
}

test("the theme-aware scrim is a tint in light mode and the old navy shade in dark mode", async ({ page }) => {
  await page.goto("/lab/scrims");
  await expect(page.locator("[data-scrim-specimen]")).toHaveCount(5);

  const dark = await read(page, true);
  // The old hub hero navy, rgba(26,21,53, .85 / .70 / .85), to the unit.
  expectWash(dark.theme, [26, 21, 53], [85, 70], "dark .scrim");
  expectInk(dark.theme, dark.tokens, "shade", "dark .scrim");
  expect(dark.theme.ink, "dark .scrim ink is white").toEqual([255, 255, 255]);

  const light = await read(page, false);
  // The tint Alex approved on the hub hero: 75 / 58.
  expectWash(light.theme, hexToRgb(DEFAULT_TINT), [75, 58], "light .scrim");
  expectInk(light.theme, light.tokens, "tint", "light .scrim");
  // Muted ink on a tint is the body ink at 600, never the secondary grey.
  expect(light.theme.muted, "light .scrim muted ink is the body ink").toEqual([51, 65, 85]);
});

test("a forced tint or shade paints the same, with its own ink, in either theme", async ({ page }) => {
  await page.goto("/lab/scrims");

  for (const isDark of [true, false]) {
    const r = await read(page, isDark);
    const theme = isDark ? "dark" : "light";
    expectWash(r.tint, hexToRgb(DEFAULT_TINT), [75, 58], `${theme} .scrim-tint`);
    expectInk(r.tint, r.tokens, "tint", `${theme} .scrim-tint`);
    expectWash(r.shade, hexToRgb(DEFAULT_SHADE), [85, 70], `${theme} .scrim-shade`);
    expectInk(r.shade, r.tokens, "shade", `${theme} .scrim-shade`);
  }
});

test("soft and strong step from the tone's own default, in both themes", async ({ page }) => {
  await page.goto("/lab/scrims");

  const dark = await read(page, true);
  expectWash(dark.soft, hexToRgb(DEFAULT_SHADE), [70, 55], "dark .scrim-soft");
  expectWash(dark.strong, hexToRgb(DEFAULT_SHADE), [95, 80], "dark .scrim-strong");

  const light = await read(page, false);
  expectWash(light.soft, hexToRgb(DEFAULT_TINT), [60, 43], "light .scrim-soft");
  expectWash(light.strong, hexToRgb(DEFAULT_TINT), [85, 68], "light .scrim-strong");
});

test("a custom dark and light base carries through to both tones, in both themes", async ({ page }) => {
  // mcritchie-industries sets dark #141516 and light #FFFFFF.
  await page.goto("/lab/scrims?palette=mcritchie-industries");

  for (const isDark of [true, false]) {
    const r = await read(page, isDark);
    const theme = isDark ? "dark" : "light";
    expect(r.tokens["--color-shade"], `${theme}: --color-shade`).toBe("#141516");
    expect(r.tokens["--color-tint"], `${theme}: --color-tint`).toBe("#ffffff");
    expectWash(r.shade, [20, 21, 22], [85, 70], `${theme} .scrim-shade`);
    expectWash(r.tint, [255, 255, 255], [75, 58], `${theme} .scrim-tint`);
    expectWash(r.theme, isDark ? [20, 21, 22] : [255, 255, 255], isDark ? [85, 70] : [75, 58], `${theme} .scrim`);
  }
});
