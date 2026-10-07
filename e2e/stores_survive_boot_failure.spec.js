const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The Alpine stores survive a boot that fails to load.
//
// Every host's <body> binds :class="{ 'dev-mode': $store.devMode }", and the
// engine's theme toggle reads $store.theme. Those stores are studio/alpine_stores,
// which layouts/studio/_head imports by its OWN nonced module tag as well as
// through the boot's graph. So when studio/application fails to load (a missing
// digest after a deploy, a network drop, a throw in its graph) the stores still
// register, and the host's body binding never throws.
//
// The failure is real here: the browser's request for studio/application is
// aborted, both the modulepreload and the import. The CONTROL: delete the
// `javascript_import_module_tag "studio/alpine_stores"` line from the head and
// this spec fails: no theme store, no devMode store, and Alpine's expression
// error from the body binding.

// The boot module's URL, digested or not. Nothing else is blocked: its imports
// (studio/alpine_stores among them) stay reachable, as they would when only the
// boot module's own file is missing.
const BOOT_MODULE = /\/studio\/application(?:-[0-9a-f]+)?\.js(?:\?|$)/;

// A host's body, as every consumer layout writes it, plus a theme binding.
const HOST_BODY =
  `<body x-data class="bg-page text-body" ` +
  `:class="{ 'dev-mode': $store.devMode, 'host-dark': $store.theme.isDark }">`;

async function breakTheBoot(page) {
  const aborted = [];
  await page.route((url) => BOOT_MODULE.test(url.pathname + url.search), (route) => {
    aborted.push(route.request().url());
    return route.abort();
  });
  return aborted;
}

// Serve the lab page with the host's body bindings, so the page under test binds
// the stores exactly as a consumer does.
async function withHostBody(page, path) {
  await page.route((url) => url.pathname === path, async (route) => {
    const response = await route.fetch();
    const html = await response.text();
    const body = '<body class="bg-page text-body">';
    if (!html.includes(body)) throw new Error(`the lab layout's <body> changed; update HOST_BODY's anchor`);
    await route.fulfill({ response, body: html.replace(body, HOST_BODY) });
  });
}

// Every thrown error, and every console error but the aborted boot module's own
// failed-load report, which is the failure this spec stages.
function watchErrors(page) {
  const errors = [];
  page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    if (BOOT_MODULE.test(message.location().url || "")) return;
    errors.push(`console.error: ${message.text()}`);
  });
  return errors;
}

test("the theme and devMode stores register when studio/application fails to load", async ({ page }) => {
  await blockOffsiteRequests(page);
  const aborted = await breakTheBoot(page);
  await withHostBody(page, "/lab/bar_stack");
  const errors = watchErrors(page);
  // Alpine has walked the page (so the body binding has evaluated) once it
  // announces alpine:initialized; nothing here waits for a store to appear.
  await page.addInitScript(() => {
    document.addEventListener("alpine:initialized", () => { window.__alpineReady = true; });
  });

  await page.goto("/lab/bar_stack");
  await page.waitForFunction(() => window.__alpineReady === true);

  // The failure happened: the boot module was requested and refused, and none
  // of what it installs is on the page.
  expect(aborted.length, "studio/application was never requested, so nothing failed").toBeGreaterThan(0);
  expect(await page.evaluate(() => typeof window.navCollapse)).toBe("undefined");

  // Both stores, with their stored defaults.
  const stores = await page.evaluate(() => {
    const theme = window.Alpine.store("theme");
    return theme === undefined
      ? { theme: "MISSING", devMode: window.Alpine.store("devMode") }
      : { theme: theme.value, isDark: theme.isDark, devMode: window.Alpine.store("devMode") };
  });
  expect(stores).toEqual({ theme: "dark", isDark: true, devMode: false });

  // The host's body binding evaluated against them, and follows them.
  const body = page.locator("body");
  await expect(body).toHaveClass(/\bhost-dark\b/);
  await expect(body).not.toHaveClass(/\bdev-mode\b/);
  await page.evaluate(() => { window.Alpine.store("devMode", true); });
  await expect(body).toHaveClass(/\bdev-mode\b/);

  // The theme store still toggles the root and remembers the choice.
  const after = await page.evaluate(() => {
    window.Alpine.store("theme").toggle();
    return {
      value: window.Alpine.store("theme").value,
      dark: document.documentElement.classList.contains("dark"),
      stored: localStorage.getItem("theme")
    };
  });
  expect(after).toEqual({ value: "light", dark: false, stored: "light" });
  await expect(body).not.toHaveClass(/\bhost-dark\b/);

  expect(errors).toEqual([]);
});

test("with the boot loaded, the stores register once and the host body binds them", async ({ page }) => {
  await blockOffsiteRequests(page);
  await withHostBody(page, "/lab/bar_stack");
  const errors = watchErrors(page);
  // Count every registration of the two names, from whichever path makes it.
  await page.addInitScript(() => {
    window.__storeWrites = [];
    document.addEventListener("alpine:init", () => {
      const store = window.Alpine.store.bind(window.Alpine);
      window.Alpine.store = function (name, value) {
        if (value !== undefined && (name === "theme" || name === "devMode")) window.__storeWrites.push(name);
        return store(name, value);
      };
    }, { capture: true });
  });

  await page.goto("/lab/bar_stack");
  await page.waitForFunction(() => Boolean(window.Alpine && window.Alpine.store("theme")));

  expect(await page.evaluate(() => typeof window.navCollapse)).toBe("function");
  expect((await page.evaluate(() => window.__storeWrites)).sort()).toEqual(["devMode", "theme"]);
  await expect(page.locator("body")).toHaveClass(/\bhost-dark\b/);
  expect(errors).toEqual([]);
});
