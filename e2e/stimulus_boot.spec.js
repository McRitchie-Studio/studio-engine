const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The engine's browser boot: studio/application runs its own Stimulus
// application, and the Alpine names consumers still bind to are in place
// BEFORE Alpine starts.
//
// The order is the claim no server tier can make. layouts/studio/_head loads
// Alpine after the module tags, and the shims (studio/alpine_shims) depend on
// deferred classic scripts and module scripts executing in document order. Put
// Alpine back above the module tags and Alpine evaluates the hub's
// x-data="navCollapse()" before the module has defined it, and the stores
// $store.theme and $store.devMode never register. The tests below fail that way.

test("the engine navbar collapses under its Stimulus controller", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/lab/bar_stack");

  const header = page.locator("header[data-controller~='studio--nav-collapse']");
  await expect(header).toHaveCount(1);
  await expect(header).not.toHaveClass(/is-scrolled/);

  await page.evaluate(() => window.scrollTo(0, 400));
  // The shadow's hysteresis flips the controller's scrolled classes.
  await expect(header).toHaveClass(/\bis-scrolled\b/);
  await expect(header).toHaveClass(/\bshadow-lg\b/);
  await expect.poll(() => header.evaluate((el) => el.style.getPropertyValue("--nav-p"))).toBe("1.0000");

  await page.evaluate(() => window.scrollTo(0, 0));
  await expect(header).not.toHaveClass(/is-scrolled/);
  await expect.poll(() => header.evaluate((el) => el.style.getPropertyValue("--nav-p"))).toBe("0.0000");

  expect(errors).toEqual([]);
});

test("Alpine starts after the boot module, so the shims and stores are there first", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  // Record, at the moment Alpine announces itself, whether the shim existed.
  await page.addInitScript(() => {
    document.addEventListener("alpine:init", () => {
      window.__shimAtAlpineInit = typeof window.navCollapse;
    });
  });
  await page.goto("/lab/bar_stack");
  await page.waitForFunction(() => Boolean(window.Alpine));

  expect(await page.evaluate(() => window.__shimAtAlpineInit)).toBe("function");
  const stores = await page.evaluate(() => ({
    theme: window.Alpine.store("theme").value,
    isDark: window.Alpine.store("theme").isDark,
    devMode: window.Alpine.store("devMode")
  }));
  expect(stores).toEqual({ theme: "dark", isDark: true, devMode: false });

  // The globals consumers call keep their names.
  const globals = await page.evaluate(() =>
    ["navCollapse", "showNavSpinner", "hideNavSpinner", "fireSuccessConfetti"].map((name) => typeof window[name]));
  expect(globals).toEqual(["function", "function", "function", "function"]);
  expect(errors).toEqual([]);
});

test("a host header bound with x-data=\"navCollapse()\" still collapses through the shim", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/lab/bar_stack");
  await page.waitForFunction(() => Boolean(window.Alpine));

  // The hub's own header shape: nav-shell plus the Alpine binding.
  const state = await page.evaluate(async () => {
    const host = document.createElement("div");
    host.className = "nav-shell";
    host.setAttribute("x-data", "navCollapse()");
    host.setAttribute(":class", "scrolled && 'host-scrolled'");
    document.body.prepend(host);
    window.Alpine.initTree(host);

    window.scrollTo(0, 400);
    for (let i = 0; i < 30; i++) await new Promise((resolve) => requestAnimationFrame(resolve));
    return { p: host.style.getPropertyValue("--nav-p"), scrolled: host.classList.contains("host-scrolled") };
  });

  expect(state).toEqual({ p: "1.0000", scrolled: true });
});

test("the theme store toggles the root class and remembers the choice", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/bar_stack");
  await page.waitForFunction(() => Boolean(window.Alpine && window.Alpine.store("theme")));

  const after = await page.evaluate(() => {
    window.Alpine.store("theme").toggle();
    return {
      value: window.Alpine.store("theme").value,
      dark: document.documentElement.classList.contains("dark"),
      stored: localStorage.getItem("theme")
    };
  });
  expect(after).toEqual({ value: "light", dark: false, stored: "light" });
});
