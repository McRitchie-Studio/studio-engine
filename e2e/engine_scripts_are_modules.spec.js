const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests, watchPageErrors } = require("./helpers");

// [e2e] The engine's scripts are ES modules, and every one of them still runs.
//
// Six engine scripts were classic until this lane's change: Alpine,
// canvas-confetti, studio/studio_confetti, studio/session,
// studio/sticky_table_header and Leaflet. The view tests prove the head names
// each as a type="module" tag below the import map. Only a browser proves the
// consequences: that a module tag below the map leaves the map honoured (a bare
// specifier still resolves), that the unedited vendored builds still assign
// their globals when evaluated as modules (strict mode, no `this`), that a
// module's export and the compatibility global it keeps are one object (the
// tag and an import are one module instance), and that the effects work.
// Leaflet's import() is e2e/site_footer.spec.js's; Alpine's boot is
// e2e/vendored_alpine.spec.js's and e2e/stimulus_boot.spec.js's.

test("every script the head loads by URL is a module below the import map, and the page throws nothing", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);

  await page.goto("/lab/sticky_table");
  await page.waitForFunction(() => Boolean(window.Alpine && window.StudioStickyTableHeaders && window.studioConfetti), null, { timeout: 10_000 });

  const head = await page.evaluate(() => {
    const scripts = [...document.head.querySelectorAll("script")];
    const map = scripts.findIndex((script) => script.type === "importmap");
    return {
      map,
      bySrc: scripts.map((script, index) => ({ index, src: script.getAttribute("src"), type: script.type })).filter((script) => script.src)
    };
  });

  expect(head.map).toBeGreaterThanOrEqual(0);
  const names = head.bySrc.map((script) => script.src).join(" ");
  for (const name of ["studio/studio_confetti", "studio/alpine", "studio/sticky_table_header"]) {
    expect(names, `${name} is not loaded by the head`).toContain(name);
  }
  for (const script of head.bySrc) {
    expect(script.type, `${script.src} is a classic script`).toBe("module");
    expect(script.index, `${script.src} is above the import map`).toBeGreaterThan(head.map);
  }

  // The map is honoured: a bare specifier resolves through it.
  const resolved = await page.evaluate(async () => typeof (await import("studio/local_path")).isLocalPath);
  expect(resolved).toBe("function");

  // The unedited vendored builds still define their globals as modules.
  const globals = await page.evaluate(() => ({
    alpine: window.Alpine.version,
    confetti: typeof window.confetti,
    sticky: window.StudioStickyTableHeaders.loaded
  }));
  expect(globals).toEqual({ alpine: "3.16.1", confetti: "function", sticky: true });
  expect(errors).toEqual([]);
});

test("each converted module's export is the compatibility global it keeps, one instance", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/sticky_table");
  await page.waitForFunction(() => Boolean(window.StudioStickyTableHeaders && window.studioConfetti), null, { timeout: 10_000 });

  const same = await page.evaluate(async () => {
    const confetti = await import("studio/studio_confetti");
    const sticky = await import("studio/sticky_table_header");
    return {
      confettiDefault: confetti.default === window.studioConfetti,
      burst: confetti.burst === window.studioConfetti.burst,
      cannons: confetti.cannons === window.studioConfetti.cannons,
      library: typeof confetti.confetti,
      sticky: sticky.default === window.StudioStickyTableHeaders
    };
  });
  expect(same).toEqual({ confettiDefault: true, burst: true, cannons: true, library: "function", sticky: true });
});

test("the session store is a module whose export is window.StudioSession", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/session_drift?fp=fp-alice&issued=1000&state=authenticated");
  await page.waitForFunction(() => Boolean(window.StudioSession && window.StudioSession.loaded), null, { timeout: 10_000 });

  const store = await page.evaluate(async () => {
    const tag = [...document.head.querySelectorAll("script[src]")].find((script) => script.src.includes("studio/session"));
    const { default: exported } = await import("studio/session");
    return { type: tag && tag.type, same: exported === window.StudioSession, state: window.StudioSession.current().state };
  });
  expect(store).toEqual({ type: "module", same: true, state: "authenticated" });
});

test("confetti fires from the module, and not under reduced motion", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/bar_stack");
  await page.waitForFunction(() => Boolean(window.studioConfetti), null, { timeout: 10_000 });

  // canvas-confetti draws on a full-screen canvas it appends on the first call.
  expect(await page.locator("canvas").count()).toBe(0);
  await page.evaluate(async () => (await import("studio/studio_confetti")).burst(document.body));
  await expect(page.locator("canvas")).toHaveCount(1);

  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/lab/bar_stack");
  await page.waitForFunction(() => Boolean(window.studioConfetti), null, { timeout: 10_000 });
  await page.evaluate(() => { window.studioConfetti.burst(document.body); window.studioConfetti.cannons(); });
  await page.waitForTimeout(250);
  expect(await page.locator("canvas").count(), "reduced motion fires nothing").toBe(0);
});
