const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] One theme flip ($store.theme, studio/alpine_stores; the rules in engine.css under
// data-theme-flip). Which animations ran is observable only in a browser. No host rule lives in
// this lab, so the page carries the hub's theme-transition rule and 200 elements that would show
// it: going back to the old class reddens the transition count here, not only a string match.
const LAB = "/lab/page_transitions?direction=left&morph=both";
const TOGGLE = "header button[title='Toggle theme']:visible";

async function record(page) {
  await page.addInitScript(() => {
    window.__seen = [];
    window.__durations = [];
    window.__transitions = [];
    window.__rejections = [];
    window.addEventListener("unhandledrejection", (event) => window.__rejections.push(String(event.reason)));
    document.addEventListener("transitionrun", (event) => {
      window.__transitions.push(`${event.target.tagName} ${event.propertyName}`);
    }, true);
    const tick = () => {
      for (const animation of document.getAnimations()) {
        const pseudo = animation.effect && animation.effect.pseudoElement;
        if (!pseudo || !pseudo.startsWith("::view-transition")) continue;
        const key = `${pseudo} ${animation.animationName || ""}`;
        if (!window.__seen.includes(key)) {
          window.__seen.push(key);
          window.__durations.push(animation.effect.getComputedTiming().duration);
        }
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}

async function open(page, url = LAB) {
  await blockOffsiteRequests(page);
  await record(page);
  await page.goto(url);
  await page.waitForFunction(() => window.Alpine && window.Alpine.store("theme") && window.Turbo);
  await page.addStyleTag({
    content: `
      .theme-transition *, .theme-transition *::before, .theme-transition *::after {
        transition: background-color 200ms, color 200ms, border-color 200ms, box-shadow 200ms !important;
      }
      .flip-lab { color: rgb(0 0 0); }
      .dark .flip-lab { color: rgb(255 255 255); }
    `,
  });
  await page.evaluate(() => {
    const box = document.createElement("div");
    box.dataset.flipBox = "";
    for (let i = 0; i < 200; i += 1) {
      const line = document.createElement("span");
      line.className = i % 2 ? "flip-lab" : "flip-lab transition-colors";
      line.style.transition = i % 2 ? "" : "color 200ms";
      line.textContent = "x";
      box.append(line);
    }
    document.querySelector("main").append(box);
  });
  // The first frames after the insert settle before anything is counted.
  await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  await page.evaluate(() => { window.__transitions.length = 0; window.__seen.length = 0; window.__durations.length = 0; });
}

const state = (page) => page.evaluate(() => ({
  value: window.Alpine.store("theme").value,
  dark: document.documentElement.classList.contains("dark") ? "dark" : "light",
  stored: localStorage.getItem("theme"),
  flip: document.documentElement.dataset.themeFlip === undefined ? "off" : "on",
  hasOldClass: document.documentElement.classList.contains("theme-transition"),
}));

const agreed = (theme) => ({ value: theme, dark: theme, stored: theme, flip: "off", hasOldClass: false });

const noCrossfadeRunning = (page) => page.waitForFunction(() =>
  !document.getAnimations().some((a) => (a.effect && a.effect.pseudoElement || "").startsWith("::view-transition")));

test("a toggle is one root crossfade under 200ms: no element transition, no page motion", async ({ page }) => {
  await open(page);
  await page.locator(TOGGLE).first().click();
  await expect.poll(() => state(page)).toEqual(agreed("light"));
  await noCrossfadeRunning(page);

  const { seen, durations, transitions, rejections } = await page.evaluate(() => ({
    seen: window.__seen, durations: window.__durations, transitions: window.__transitions, rejections: window.__rejections,
  }));
  expect(seen.sort()).toEqual([
    "::view-transition-old(root) vt-theme-out",
    "::view-transition-new(root) vt-theme-in",
  ].sort());
  expect(Math.max(...durations)).toBeLessThan(200);
  expect(transitions, "an element ran its own transition").toEqual([]);
  expect(rejections).toEqual([]);
});

test("the crossfade wins while a stale page-transition style is on the root", async ({ page }) => {
  await open(page);
  // Past the visit guard: the store is told nothing is visiting, the style is still there.
  await page.evaluate(() => new Promise((done) => {
    const root = document.documentElement;
    const start = document.startViewTransition.bind(document);
    document.startViewTransition = (callback) => {
      root.dataset.pageTransition = "slide-left";
      const transition = start(callback);
      transition.finished.then(() => { delete root.dataset.pageTransition; });
      done();
      return transition;
    };
    window.Alpine.store("theme").toggle();
  }));
  await expect.poll(() => state(page)).toEqual(agreed("light"));
  await noCrossfadeRunning(page);
  const seen = await page.evaluate(() => window.__seen);
  expect(seen.filter((name) => /pt-|vt-page/.test(name))).toEqual([]);
  expect(seen).toContain("::view-transition-new(root) vt-theme-in");
});

test("a reduced-motion reader flips at once, with no transition of any kind", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await open(page);
  const during = await page.evaluate(() => {
    window.Alpine.store("theme").toggle();
    return document.documentElement.classList.contains("dark");
  });
  expect(during, "the flip must be synchronous").toBe(false);
  await expect.poll(() => state(page)).toEqual(agreed("light"));
  const { seen, transitions } = await page.evaluate(() => ({ seen: window.__seen, transitions: window.__transitions }));
  expect(seen).toEqual([]);
  expect(transitions).toEqual([]);
});

test("a browser with no view transitions flips at once, with no transition of any kind", async ({ page }) => {
  await page.addInitScript(() => { delete Document.prototype.startViewTransition; });
  await open(page);
  const during = await page.evaluate(() => {
    window.Alpine.store("theme").toggle();
    return document.documentElement.classList.contains("dark");
  });
  expect(during).toBe(false);
  await expect.poll(() => state(page)).toEqual(agreed("light"));
  const { seen, transitions } = await page.evaluate(() => ({ seen: window.__seen, transitions: window.__transitions }));
  expect(seen).toEqual([]);
  expect(transitions).toEqual([]);
});

test("two real clicks inside one crossfade both land, and the three agree", async ({ page }) => {
  await open(page);
  const button = page.locator(TOGGLE).first();
  const box = await button.boundingBox();
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.mouse.click(x, y);
  await page.waitForFunction(() => !document.documentElement.classList.contains("dark"));
  await page.mouse.click(x, y);
  await expect.poll(() => state(page)).toEqual(agreed("dark"));
  await noCrossfadeRunning(page);
  expect(await page.evaluate(() => window.__rejections)).toEqual([]);
});

test("two toggles in one tick skip a transition with no rejection reaching the console", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await open(page);
  await page.evaluate(() => {
    const theme = window.Alpine.store("theme");
    theme.toggle();
    theme.toggle();
    theme.toggle();
  });
  await expect.poll(() => state(page)).toEqual(agreed("light"));
  await noCrossfadeRunning(page);
  expect(await page.evaluate(() => window.__rejections)).toEqual([]);
  expect(errors).toEqual([]);
});

test("set by value lands on that theme and opens nothing when it is there already", async ({ page }) => {
  await open(page);
  await page.evaluate(() => { window.Alpine.store("theme").set("dark"); });
  expect(await page.evaluate(() => window.__seen)).toEqual([]);
  await page.evaluate(() => { window.Alpine.store("theme").set("light"); });
  await expect.poll(() => state(page)).toEqual(agreed("light"));
});

test("a toggle during a slow Turbo visit flips at once, and the slide still plays", async ({ page }) => {
  await open(page, `${LAB}&slow=400`);
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.locator('[data-test="other"]').first().click();
  await page.waitForFunction(() => document.documentElement.dataset.turboVisitDirection !== undefined);
  await page.evaluate(() => { window.Alpine.store("theme").toggle(); });
  expect(await page.evaluate(() => document.documentElement.classList.contains("dark"))).toBe(false);
  await load;
  await expect.poll(() => state(page)).toEqual(agreed("light"));
  const seen = await page.evaluate(() => window.__seen);
  expect(seen).toContain("::view-transition-old(root) pt-out-left");
  expect(seen.filter((name) => name.includes("vt-theme"))).toEqual([]);
});

test("a visit started right after a toggle plays its slide, in the new theme", async ({ page }) => {
  await open(page);
  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.evaluate(() => {
    window.Alpine.store("theme").toggle();
    document.querySelector('[data-test="other"]').click();
  });
  await load;
  await expect.poll(() => state(page)).toEqual(agreed("light"));
  const { seen, rejections } = await page.evaluate(() => ({ seen: window.__seen, rejections: window.__rejections }));
  expect(seen).toContain("::view-transition-new(root) pt-in-from-right");
  expect(rejections).toEqual([]);
});
