const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The app-to-app page transition (studio/page_transitions, docs/PAGE_TRANSITIONS.md).
// The animation names, the groups and the frames are observable only in a browser. A recorder
// walks document.getAnimations() each frame and keeps what each view-transition pseudo ran.
const LAB = "/lab/page_transitions";
const FADE_OUT = "vt-page-out";
const PIXEL_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEBgIApD5fRAAAAABJRU5ErkJggg==";

async function record(page, randomValue = 0) {
  await page.addInitScript((value) => {
    Math.random = () => value;
    window.__seen = [];
    window.__frames = [];
    const tick = () => {
      for (const animation of document.getAnimations()) {
        const pseudo = animation.effect && animation.effect.pseudoElement;
        if (!pseudo || !pseudo.startsWith("::view-transition")) continue;
        const key = `${pseudo} ${animation.animationName || ""}`;
        if (!window.__seen.includes(key)) window.__seen.push(key);
      }
      if (document.documentElement.hasAttribute("data-page-transition")) {
        const read = (pseudo) => getComputedStyle(document.documentElement, pseudo).transform;
        const box = (selector) => { const el = document.querySelector(selector); return el ? el.getBoundingClientRect().top : null; };
        window.__frames.push({
          root: read("::view-transition-old(root)"),
          stack: read("::view-transition-group(studio-bar-stack)"),
          header: read("::view-transition-group(studio-header)"),
          stackTop: box("[data-vt-held]"),
        });
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, randomValue);
}

const seen = (page) => page.evaluate(() => window.__seen);

async function go(page, testId = "other") {
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.locator(`[data-test="${testId}"]`).first().click();
  await load;
}

async function open(page, query, randomValue) {
  await blockOffsiteRequests(page);
  await record(page, randomValue);
  await page.route("**/e2e/img/pt-hung.png", () => {});
  await page.route("**/e2e/img/pt-failed.png", (route) => route.abort());
  await page.goto(`${LAB}?${query}`);
  await page.waitForFunction(() => window.Turbo);
}

function expectPlayed(names, oldName, newName) {
  expect(names).toContain(`::view-transition-old(root) ${oldName}`);
  expect(names).toContain(`::view-transition-new(root) ${newName}`);
}

test("left plays its fade, then its unfold, moving left", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, "direction=left", 0);
  await go(page);
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
  await page.evaluate(() => { Math.random = () => 0.99; window.__seen.length = 0; });
  await go(page);
  expectPlayed(await seen(page), "pt-out-left", "pt-unfold-right");
  expect(errors).toEqual([]);
});

test("right plays its fade, then its unfold, moving right", async ({ page }) => {
  await open(page, "direction=right", 0);
  await go(page);
  expectPlayed(await seen(page), "pt-out-right", "pt-in-from-left");
  await page.evaluate(() => { Math.random = () => 0.99; window.__seen.length = 0; });
  await go(page);
  expectPlayed(await seen(page), "pt-out-right", "pt-unfold-left");
});

test("top plays its fade, then its unfold, moving up", async ({ page }) => {
  await open(page, "direction=top", 0);
  await go(page);
  expectPlayed(await seen(page), "pt-out-top", "pt-in-from-bottom");
  await page.evaluate(() => { Math.random = () => 0.99; window.__seen.length = 0; });
  await go(page);
  expectPlayed(await seen(page), "pt-out-top", "pt-unfold-bottom");
});

test("bottom plays its fade, then its unfold, moving down", async ({ page }) => {
  await open(page, "direction=bottom", 0);
  await go(page);
  expectPlayed(await seen(page), "pt-out-bottom", "pt-in-from-top");
  await page.evaluate(() => { Math.random = () => 0.99; window.__seen.length = 0; });
  await go(page);
  expectPlayed(await seen(page), "pt-out-bottom", "pt-unfold-top");
});

test("the page moves while the banner stack and the navbar hold still", async ({ page }) => {
  await open(page, "direction=left", 0);
  await expect(page.locator("[data-vt-held]")).toBeVisible();
  await go(page);
  const frames = await page.evaluate(() => window.__frames);
  const distinct = (key) => new Set(frames.map((frame) => frame[key]));
  expect(distinct("root").size, "the page never moved, so this measured nothing").toBeGreaterThan(3);
  expect(distinct("stack").size).toBe(1);
  expect(distinct("header").size).toBe(1);
  const names = await seen(page);
  expect(names.filter((name) => /(old|new)\(studio-bar-stack\)/.test(name))).toEqual([]);
  expect(names.filter((name) => /(old|new)\(studio-header\)/.test(name))).toEqual([]);
});

test("a second banner stack gets no second name, so the transition still plays", async ({ page }) => {
  await open(page, "direction=left&twice=1", 0);
  await expect(page.locator(".studio-bar-stack")).toHaveCount(2);
  await expect(page.locator("[data-vt-held]")).toHaveCount(1);
  await go(page);
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
});

test("a same-page visit plays nothing", async ({ page }) => {
  await open(page, "direction=left", 0);
  await go(page, "same");
  const names = await seen(page);
  expect(names.filter((name) => /\((root)\) /.test(name) && !name.includes("group"))).toEqual([]);
});

test("the setting off keeps the engine's fade, with no script, no marks and no name", async ({ page }) => {
  await open(page, "", 0);
  const requests = [];
  page.on("request", (request) => requests.push(request.url()));
  expect(await page.locator('meta[name="page-transition-direction"]').count()).toBe(0);
  expect(await page.evaluate(() => document.documentElement.dataset.pageTransitionDirection)).toBeUndefined();
  await expect(page.locator("[data-vt-held]")).toHaveCount(0);
  await page.locator('[data-test="other"]').first().click();
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  expect(requests.filter((url) => url.includes("page_transitions-") || url.endsWith("page_transitions.js"))).toEqual([]);
});

test("a hung image releases the swap at the cap", async ({ page }) => {
  await open(page, "direction=left&img=hung", 0);
  const waited = await page.evaluate(() => new Promise((done) => {
    document.addEventListener("turbo:before-render", () => {
      const started = performance.now();
      document.addEventListener("turbo:render", () => done(performance.now() - started), { once: true });
    }, { once: true });
    document.querySelector('[data-test="other"]').click();
  }));
  expect(waited).toBeGreaterThanOrEqual(450);
  expect(waited).toBeLessThan(1500);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
});

test("a failed image does not hold the visit", async ({ page }) => {
  await open(page, "direction=left&img=failed", 0);
  const waited = await page.evaluate(() => new Promise((done) => {
    document.addEventListener("turbo:before-render", () => {
      const started = performance.now();
      document.addEventListener("turbo:render", () => done(performance.now() - started), { once: true });
    }, { once: true });
    document.querySelector('[data-test="other"]').click();
  }));
  expect(waited).toBeLessThan(400);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
});

test("the incoming image is decoded before the swap, and another listener's resume cannot cut it short", async ({ page }) => {
  await open(page, "direction=left&img=slow", 0);
  await page.route("**/e2e/img/pt-slow.png", async (route) => {
    await new Promise((done) => setTimeout(done, 300));
    await route.fulfill({ body: Buffer.from(PIXEL_PNG, "base64"), contentType: "image/png" });
  });
  // What Turf's turbo_snapshot_cache.js does: a hold of one tick.
  await page.evaluate(() => document.addEventListener("turbo:before-render", (event) => {
    const { resume } = event.detail;
    event.preventDefault();
    setTimeout(resume, 0);
  }));
  const complete = await page.evaluate(() => new Promise((done) => {
    document.addEventListener("turbo:render", () => {
      const img = document.querySelector('[data-test="eager-image"]');
      done({ complete: img.complete, width: img.naturalWidth });
    }, { once: true });
    document.querySelector('[data-test="other"]').click();
  }));
  expect(complete.width, "the real image had not loaded when the page swapped").toBeGreaterThan(0);
});

test("the overlay never shows during the image wait", async ({ page }) => {
  await open(page, "direction=left&img=hung&overlay=1", 0);
  // From before-render on: a slow response may show the overlay, as it always has.
  await page.evaluate(() => {
    window.__overlayShown = 0;
    document.addEventListener("turbo:before-render", () => {
      const overlay = document.querySelector("[data-studio-loader-overlay]");
      if (!overlay.hidden) window.__overlayShown += 1;
      new MutationObserver(() => { if (!overlay.hidden) window.__overlayShown += 1; }).observe(overlay, { attributes: true });
    }, { once: true });
  });
  await go(page);
  expect(await page.evaluate(() => window.__overlayShown)).toBe(0);
});

test("a chat head on one page alone moves with the page", async ({ page }) => {
  await open(page, "direction=left&morph=a", 0);
  await go(page);
  const names = await seen(page);
  expectPlayed(names, "pt-out-left", "pt-in-from-right");
  expect(names.filter((name) => name.includes("agent-portrait"))).toEqual([]);
});

test("a chat head on both pages morphs, and no style plays", async ({ page }) => {
  await open(page, "direction=left&morph=both", 0);
  await go(page);
  const names = await seen(page);
  expect(names.some((name) => name.startsWith("::view-transition-group(agent-portrait)"))).toBe(true);
  expect(names).toContain(`::view-transition-old(root) ${FADE_OUT}`);
  expect(names.filter((name) => name.includes(" pt-"))).toEqual([]);
});

test("Back between two chat heads still morphs, from Turbo's cache", async ({ page }) => {
  await open(page, "direction=left&morph=both", 0);
  await go(page);
  await page.evaluate(() => { window.__seen.length = 0; });
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.goBack();
  await load;
  const names = await seen(page);
  expect(names.some((name) => name.startsWith("::view-transition-group(agent-portrait)"))).toBe(true);
  expect(names.filter((name) => name.includes(" pt-"))).toEqual([]);
});

test("Back from a scrolled page plays the app's direction and restores the scroll", async ({ page }) => {
  await open(page, "direction=left", 0);
  await page.evaluate(() => window.scrollTo(0, 800));
  await page.waitForTimeout(200); // Turbo records the position on a throttled scroll.
  // Not locator.click: Playwright would scroll the link into view first.
  const left = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => document.querySelector('[data-test="other"]').click());
  await left;
  await page.waitForTimeout(200); // Past the page's own load: Turbo ignores an early popstate.
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
  await page.evaluate(() => { window.__seen.length = 0; });
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.goBack();
  await load;
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
  await expect(page.locator('[data-test="page-a"]')).toBeVisible();
  expect(await page.evaluate(() => window.scrollY)).toBe(800);
});

test("a modal open across the swap is gone on arrival, and the move still plays", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, "direction=left&modal=1", 0);
  await page.evaluate(() => window.Alpine.store("modals").open("lab-first", { title: "Card" }));
  await expect(page.locator('[role="dialog"]')).toBeVisible();
  const left = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => window.Turbo.visit(document.querySelector('[data-test="other"]').href));
  await left;
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  await expect(page.locator('[role="dialog"]')).toHaveCount(0);
  expect(await page.evaluate(() => document.body.classList.contains("modal-open"))).toBe(false);
  expect(errors).toEqual([]);
});

test("a sidebar open across the swap comes back closed, and the move still plays", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, "direction=left&sidebar=1", 0);
  await page.waitForFunction(() => window.Alpine && window.Alpine.store("sidebars"));
  await page.evaluate(() => { window.Alpine.store("sidebars").linkTreeOpen = true; });
  await expect(page.locator("#studio-link-sidebar")).toBeVisible();
  const left = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => window.Turbo.visit(document.querySelector('[data-test="other"]').href));
  await left;
  expectPlayed(await seen(page), "pt-out-left", "pt-in-from-right");
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
  await expect(page.locator("#studio-link-sidebar")).toBeHidden();
  expect(errors).toEqual([]);
});

test("at phone width the chrome holds still while the page moves", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await open(page, "direction=top", 0);
  await go(page);
  const frames = await page.evaluate(() => window.__frames);
  expect(new Set(frames.map((frame) => frame.root)).size).toBeGreaterThan(3);
  expect(new Set(frames.map((frame) => frame.stack)).size).toBe(1);
  expect(new Set(frames.map((frame) => frame.header)).size).toBe(1);
  expectPlayed(await seen(page), "pt-out-top", "pt-in-from-bottom");
});

test("leaving a page scrolled, the stack does not slide in, and the collapsed navbar still pins", async ({ page }) => {
  await open(page, "direction=left", 0);
  await page.evaluate(() => window.scrollTo(0, 800));
  await page.waitForTimeout(100);
  const left = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => document.querySelector('[data-test="other"]').click());
  await left;
  const frames = await page.evaluate(() => window.__frames);
  expect(new Set(frames.map((frame) => frame.root)).size).toBeGreaterThan(3);
  expect(new Set(frames.map((frame) => frame.stack)).size, "the stack slid in from above the viewport").toBe(1);
  expect((await seen(page)).filter((name) => name.includes("group(studio-bar-stack)"))).toEqual([]);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
});

test.describe("with reduced motion", () => {
  test.use({ contextOptions: { reducedMotion: "reduce" } });

  test("the swap is plain: no transition, no pause, nothing marked to play", async ({ page }) => {
    const errors = watchPageErrors(page);
    await open(page, "direction=left&img=hung", 0);
    const result = await page.evaluate(() => new Promise((done) => {
      const started = {};
      document.addEventListener("turbo:before-render", (event) => {
        started.at = performance.now();
        started.prevented = () => event.defaultPrevented;
      }, { once: true });
      document.addEventListener("turbo:render", () => done({
        waited: performance.now() - started.at,
        attribute: document.documentElement.dataset.pageTransition ?? null,
      }), { once: true });
      document.querySelector('[data-test="other"]').click();
    }));
    expect(result.attribute).toBeNull();
    expect(result.waited, "a hung image held a reduced-motion visit").toBeLessThan(300);
    expect(await seen(page)).toEqual([]);
    await expect(page.locator('[data-test="page-b"]')).toBeVisible();
    expect(errors).toEqual([]);
  });
});

test("a browser without view transitions gets the plain swap, with no pause", async ({ page }) => {
  await page.addInitScript(() => { delete Document.prototype.startViewTransition; });
  await open(page, "direction=left&img=hung", 0);
  const attribute = await page.evaluate(() => new Promise((done) => {
    let started;
    document.addEventListener("turbo:before-render", () => { started = performance.now(); }, { once: true });
    document.addEventListener("turbo:render", () => done({
      waited: performance.now() - started,
      attribute: document.documentElement.dataset.pageTransition ?? null,
    }), { once: true });
    document.querySelector('[data-test="other"]').click();
  }));
  expect(attribute.attribute).toBeNull();
  expect(attribute.waited).toBeLessThan(300);
  await expect(page.locator('[data-test="page-b"]')).toBeVisible();
});
