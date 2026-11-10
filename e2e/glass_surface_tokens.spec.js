const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The glass surfaces take the app's tint from two root tokens (engine.css, THE GLASS
// SURFACES): --glass-surface-tint for the hairline and the soft lights' shade, and
// --glass-surface-shadow-tint for a card's drop shadow. With no tokens set they paint the
// hub's violet exactly as before. Computed styles, in both themes.
//
// CONTROLS: the hub-look spec passes on the commit before the tokens (the defaults are the
// values the block hard-coded, so the look did not move). The app-token spec fails there (an
// app's :root tokens never reached the surfaces). The layer spec shows why NEW_APP_SETUP.md
// says "outside any layer": a token in @layer components loses to the engine's default.

const SPECIMENS = `
  <span id="badge" class="badge">Go</span>
  <input id="input" class="input-field">
  <div id="card" class="card p-4">Card</div>
  <div class="page-header" id="bar" data-stuck>Bar</div>
  <button id="neutral" class="btn btn-neutral">Go</button>
  <button id="pressed" class="btn btn-neutral" data-lit-state="pressed">Go</button>
  <div id="probe"></div>
`;

const open = async (page) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/sidebar_panels");
  await page.evaluate((html) => document.body.insertAdjacentHTML("beforeend", html), SPECIMENS);
  await page.addStyleTag({ content: "*, *::before, *::after { transition: none !important; }" });
  await page.evaluate(() => { document.documentElement.dataset.surfaceStyle = "glass"; });
};
const setDark = (page, on) => page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), on);

// Each surface value, resolved: a probe paints the variable, so the value is the one the
// root computed. The real elements are read too: the badge, the input, the stuck header's
// hairline, and a neutral button's ::after light at rest and pressed.
const paint = (page) => page.evaluate(() => {
  const probe = document.getElementById("probe");
  const read = (prop, name) => {
    probe.style[prop] = `var(${name})`;
    const value = getComputedStyle(probe)[prop];
    probe.style[prop] = "";
    return value;
  };
  return {
    line: read("backgroundColor", "--surface-glass-line"),
    shadow: read("boxShadow", "--surface-glass-shadow"),
    softBottom: read("boxShadow", "--lit-soft-bottom"),
    softPressed: read("boxShadow", "--lit-soft-pressed"),
    badge: read("boxShadow", "--lit-badge"),
    input: read("boxShadow", "--lit-input"),
    badgeEl: getComputedStyle(document.getElementById("badge")).boxShadow,
    inputEl: getComputedStyle(document.getElementById("input")).boxShadow,
    barLine: getComputedStyle(document.getElementById("bar")).borderBottomColor,
    neutralEl: getComputedStyle(document.getElementById("neutral"), "::after").boxShadow,
    pressedEl: getComputedStyle(document.getElementById("pressed"), "::after").boxShadow,
  };
});

// The real elements paint the values the probe read.
const expectElements = (got) => {
  expect(got.badgeEl).toContain(got.badge);
  expect(got.inputEl).toContain(got.input);
  expect(got.barLine).toBe(got.line);
  expect(got.neutralEl).toContain(got.softBottom);
  expect(got.neutralEl).toContain(`${got.line} 0px 0px 0px 1px inset`);
  expect(got.pressedEl).toContain(got.softPressed);
};

const HUB_LIGHT = {
  line: "rgba(29, 24, 50, 0.1)",
  shadow: "rgba(60, 50, 120, 0.08) 0px 6px 20px 0px",
  softBottom: "rgba(29, 24, 50, 0.08) 0px -1px 0px 0px inset",
  softPressed: "rgba(29, 24, 50, 0.16) 0px 2px 3px 0px inset",
  badge: "rgba(255, 255, 255, 0.5) 0px 1px 0px 0px inset, rgba(29, 24, 50, 0.12) 0px 1px 1px 0px",
  input: "rgba(29, 24, 50, 0.14) 0px 1px 2px 0px inset, rgba(255, 255, 255, 0.6) 0px -1px 0px 0px inset",
};
const HUB_DARK = {
  line: "rgba(255, 255, 255, 0.1)",
  shadow: "rgba(0, 0, 0, 0.22) 0px 8px 24px 0px",
  softBottom: "rgba(0, 0, 0, 0.25) 0px -1px 0px 0px inset",
  softPressed: "rgba(0, 0, 0, 0.4) 0px 2px 3px 0px inset",
  badge: "rgba(255, 255, 255, 0.14) 0px 1px 0px 0px inset, rgba(0, 0, 0, 0.35) 0px 1px 1px 0px",
  input: "rgba(0, 0, 0, 0.4) 0px 1px 2px 0px inset, rgba(255, 255, 255, 0.06) 0px -1px 0px 0px inset",
};

test("with no tokens set, the glass surfaces paint the hub's violet in both themes", async ({ page }) => {
  await open(page);

  await setDark(page, false);
  const light = await paint(page);
  expect(light).toMatchObject(HUB_LIGHT);
  expectElements(light);

  await setDark(page, true);
  const dark = await paint(page);
  expect(dark).toMatchObject(HUB_DARK);
  expectElements(dark);
});

// An app's stylesheet: unlayered, after the engine, as NEW_APP_SETUP.md shows. Commercial
// Welding's navy. The dark theme's lights are white and black, so the tint never reaches it.
const APP_TOKENS = ":root { --glass-surface-tint: 11 24 36; --glass-surface-shadow-tint: 31 95 168; }";

test("an app's root tokens reach each glass surface value, and the dark theme keeps its own", async ({ page }) => {
  await open(page);
  await page.addStyleTag({ content: APP_TOKENS });

  await setDark(page, false);
  const light = await paint(page);
  expect(light).toMatchObject({
    line: "rgba(11, 24, 36, 0.1)",
    shadow: "rgba(31, 95, 168, 0.08) 0px 6px 20px 0px",
    softBottom: "rgba(11, 24, 36, 0.08) 0px -1px 0px 0px inset",
    softPressed: "rgba(11, 24, 36, 0.16) 0px 2px 3px 0px inset",
    badge: "rgba(255, 255, 255, 0.5) 0px 1px 0px 0px inset, rgba(11, 24, 36, 0.12) 0px 1px 1px 0px",
    input: "rgba(11, 24, 36, 0.14) 0px 1px 2px 0px inset, rgba(255, 255, 255, 0.6) 0px -1px 0px 0px inset",
  });
  expectElements(light);

  await setDark(page, true);
  const dark = await paint(page);
  expect(dark).toMatchObject(HUB_DARK);
  expectElements(dark);
});

test("a token set inside @layer components loses to the engine's default", async ({ page }) => {
  await open(page);
  await page.addStyleTag({ content: `@layer components { ${APP_TOKENS} }` });

  await setDark(page, false);
  expect(await paint(page)).toMatchObject(HUB_LIGHT);
});
