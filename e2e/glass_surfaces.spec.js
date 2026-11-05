const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The glass surfaces and lit buttons (Studio.surface_style = :glass, written on the host's
// root as html[data-surface-style]). The page's own stylesheet is what is read: the elements below
// carry only the engine's classes, so a computed style here is what a host gets.
//
// CONTROLS, each red for its reason: optIn() not setting the attribute (every test but the first);
// the attribute dropped from a selector so a rule reaches every app (the first test); ::after's
// inset -1px back to 0 (the edge spec); the glow on .btn-sm (the small spec); --lit-fill-alpha in
// the light theme (the transparency spec); .fixed * out of the surface rule's :not (the modal spec).

const SPECIMENS = `
  <button id="primary" class="btn btn-primary">Go</button>
  <button id="danger" class="btn btn-danger">Go</button>
  <button id="small" class="btn btn-primary btn-sm">Go</button>
  <button id="neutral" class="btn btn-neutral">Go</button>
  <button id="off" class="btn btn-primary" disabled>Go</button>
  <span id="badge" class="badge">Go</span>
  <input id="input" class="input-field">
  <div id="card" class="card p-4">Card</div>
  <div class="fixed inset-0 -z-10"><div id="modal" class="card p-4">Modal</div></div>
  <div id="menu" class="card absolute">Menu</div>
  <div class="page-header" id="bar" data-stuck>Bar</div>
`;

const open = async (page) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/sidebar_panels");
  await page.evaluate((html) => document.body.insertAdjacentHTML("beforeend", html), SPECIMENS);
  // A computed style mid-transition reads the old value, so nothing here animates. The lab starts light.
  await page.addStyleTag({ content: "*, *::before, *::after { transition: none !important; }" });
  await page.evaluate(() => document.documentElement.classList.remove("dark"));
};
const optIn = (page) => page.evaluate(() => { document.documentElement.dataset.surfaceStyle = "glass"; });
const theme = (page, dark) => page.evaluate((on) => document.documentElement.classList.toggle("dark", on), dark);
const css = (page, id, name, pseudo) =>
  page.evaluate(([i, n, p]) => getComputedStyle(document.getElementById(i), p)[n], [id, name, pseudo || null]);
const alpha = (color) => {
  const slash = /\/\s*([\d.]+)\s*\)/.exec(color);
  if (slash) return Number(slash[1]);
  const rgba = /rgba\([^)]*,\s*([\d.]+)\)/.exec(color);
  return rgba ? Number(rgba[1]) : 1;
};

test("without the opt-in nothing moves", async ({ page }) => {
  await open(page);

  expect(await css(page, "primary", "backgroundImage")).toBe("none");
  expect(await css(page, "primary", "boxShadow")).toBe("none");
  expect(await css(page, "primary", "content", "::after")).toBe("none");
  expect(await css(page, "badge", "boxShadow")).toBe("none");
  expect(alpha(await css(page, "card", "backgroundColor"))).toBe(1);
  
});

test("a full-size filled button is lit: gradient, contact and its own glow", async ({ page }) => {
  await open(page);
  await optIn(page);

  for (const id of ["primary", "danger"]) {
    expect(await css(page, id, "backgroundImage")).toContain("linear-gradient(oklch");
    expect(await css(page, id, "boxShadow")).toContain("-6px");
    expect(await css(page, id, "backgroundRepeat")).toBe("no-repeat");
  }
});

test("the top light and the bottom shade run edge to edge", async ({ page }) => {
  await open(page);
  await optIn(page);

  const shade = await css(page, "primary", "boxShadow", "::after");
  expect(shade).toContain("inset");
  expect(await css(page, "primary", "inset", "::after")).toBe("-1px");
  expect(await css(page, "primary", "borderTopColor")).toBe("rgba(0, 0, 0, 0)");
});

test("a small button has no glow, and a disabled one is flat", async ({ page }) => {
  await open(page);
  await optIn(page);

  expect(await css(page, "small", "backgroundImage")).toContain("linear-gradient(oklch");
  expect(await css(page, "small", "boxShadow")).not.toContain("-6px");
  expect(await css(page, "off", "backgroundImage")).toBe("none");
  expect(await css(page, "off", "boxShadow")).toBe("none");
  expect(await css(page, "off", "content", "::after")).toBe("none");
});

test("a press flips the shadow and moves 1px, unless motion is reduced", async ({ page }) => {
  await open(page);
  await optIn(page);
  await page.evaluate(() => document.getElementById("primary").setAttribute("data-lit-state", "pressed"));

  expect(await css(page, "primary", "translate")).toBe("0px 1px");
  expect(await css(page, "primary", "boxShadow")).not.toContain("-6px");
  expect(await css(page, "primary", "boxShadow", "::after")).toContain("2px 4px");

  await page.emulateMedia({ reducedMotion: "reduce" });
  expect(await css(page, "primary", "translate")).toBe("none");
});

test("keyboard focus keeps a visible outline", async ({ page }) => {
  await open(page);
  await optIn(page);
  await page.evaluate(() => document.getElementById("primary").focus({ focusVisible: true }));

  expect(await css(page, "primary", "outlineStyle")).toBe("solid");
  expect(await css(page, "primary", "outlineWidth")).toBe("2px");
});

test("full-size buttons are a touch transparent in dark and solid in light", async ({ page }) => {
  await open(page);
  await optIn(page);

  await theme(page, true);
  expect(await css(page, "primary", "backdropFilter")).toContain("blur");
  expect(await css(page, "primary", "backgroundImage")).toContain("/ 0.88");
  // An opaque fill under the gradient would hide the backdrop however thin the gradient is.
  expect(await css(page, "primary", "backgroundColor")).toBe("rgba(0, 0, 0, 0)");
  expect(await css(page, "small", "backdropFilter")).toBe("none");

  await theme(page, false);
  expect(await css(page, "primary", "backdropFilter")).toBe("none");
  expect(await css(page, "primary", "backgroundImage")).not.toContain("/ 0.88");
});

// The painted midpoint, read from a screenshot: it is what white text really sits on, gradient,
// alpha and backdrop included. A light consumer primary is not graded here: no app but the hub has opted in.
const lum = ([r, g, b]) => {
  const lin = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
};

for (const dark of [false, true]) {
  test(`white text holds 4.5:1 at each filled button's midpoint, ${dark ? "dark" : "light"}`, async ({ page, browser }) => {
    await open(page);
    await page.evaluate(() => document.body.insertAdjacentHTML("beforeend", ["secondary", "success", "warning"].map((v) =>
      `<button id="${v}" class="btn btn-${v}">Go</button>`).join("")));
    await optIn(page);
    await theme(page, dark);
    const reader = await browser.newPage();
    for (const id of ["primary", "secondary", "success", "danger", "warning"]) {
      await page.locator(`#${id}`).scrollIntoViewIfNeeded();
      const shot = await page.locator(`#${id}`).screenshot();
      const pixel = await reader.evaluate(async (url) => {
        const image = new Image();
        image.src = url;
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = image.width;
        canvas.height = image.height;
        const context = canvas.getContext("2d");
        context.drawImage(image, 0, 0);
        return [...context.getImageData(8, Math.floor(image.height / 2), 1, 1).data].slice(0, 3);
      }, `data:image/png;base64,${shot.toString("base64")}`);
      expect(1.05 / (lum(pixel) + 0.05), `${id} ${pixel}`).toBeGreaterThanOrEqual(4.5);
    }
    await reader.close();
  });
}

test("cards turn translucent, while a modal and a menu stay solid", async ({ page }) => {
  await open(page);
  await optIn(page);

  expect(alpha(await css(page, "card", "backgroundColor"))).toBeLessThan(1);
  expect(alpha(await css(page, "modal", "backgroundColor"))).toBe(1);
  expect(alpha(await css(page, "menu", "backgroundColor"))).toBe(1);
});

test("badges and inputs take their own light, and a stuck header is a glass bar", async ({ page }) => {
  await open(page);
  await optIn(page);

  expect(await css(page, "badge", "boxShadow")).toContain("inset");
  expect(await css(page, "input", "boxShadow")).toContain("inset");
  expect(await css(page, "bar", "backdropFilter")).toContain("blur");
  expect(alpha(await css(page, "bar", "backgroundColor"))).toBeLessThan(1);
});
