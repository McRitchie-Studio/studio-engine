const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] A PANEL SLIDING OUT WHEN TURBO TAKES ITS SNAPSHOT (studio/transition_snapshot).
//
// Turbo clones the page one tick after turbo:before-cache. A link in a panel closes
// the panel on its click, so a response inside the panel's 200ms leave clones the
// page mid-slide. The clone keeps Alpine's phase classes, and no running transition
// is left to remove them. Alpine's transition removes only the classes it added
// itself, so the stale `translate-x-full` is never removed: after Back the gear
// sets the flag, x-show shows the panel, and the panel sits one width off-screen
// for good. Only a full load clears it.
//
// offsetWidth is 320 the whole time. These specs read the rect.
//
// DETERMINISM. Two things would make this a race on a loaded machine, and the spec
// removes both. The response is held until the panel is in its leave, and the leave
// is stretched to LONG_LEAVE, so the snapshot lands mid-slide on every run.
//
// CONTROLS: see the ledger line in config/e2e_lane.yml.

const LONG_LEAVE = 3000;
const PHASE_CLASS = /^(transition|ease-in|ease-out|duration-\d+|translate-x-\S+)$/;
const DESKTOP = "#studio-link-sidebar";
const PHONE = "#studio-link-sidebar-mobile";
const HOST = "#lab-host-panel";

const onLabPage = (page, name) => expect(page.locator(`[data-lab-page="${name}"]`)).toBeVisible();
const trigger = (page) => page.locator("[data-link-sidebar-trigger]:visible").first();

async function rect(page, selector) {
  return page.evaluate((sel) => {
    const panel = document.querySelector(sel);
    const box = panel.getBoundingClientRect();
    return { x: Math.round(box.x), right: Math.round(box.right), width: Math.round(box.width), viewport: window.innerWidth };
  }, selector);
}

// The panel at rest inside the viewport, its right edge on the viewport's. Not
// offsetWidth: the broken panel has its full width, one width to the right.
async function expectOnScreen(page, selector) {
  await expect
    .poll(async () => {
      const box = await rect(page, selector);
      return box.width > 0 && box.x < box.viewport && box.right === box.viewport ? "on screen" : `off: ${JSON.stringify(box)}`;
    }, { message: `${selector} on screen` })
    .toBe("on screen");
}

const phaseClasses = (page, selector) =>
  page.evaluate(([sel, source]) => [...document.querySelector(sel).classList].filter((c) => new RegExp(source).test(c)),
    [selector, PHASE_CLASS.source]);

// What Turbo filed for `path`, as a restore would bring it back.
const snapshotOf = (page, path, selector) =>
  page.evaluate(([where, sel, source]) => {
    const snapshot = window.Turbo.session.view.snapshotCache.get(new URL(where, location.href));
    const panel = snapshot && snapshot.element.querySelector(sel);
    if (!panel) return null;
    return { phase: [...panel.classList].filter((c) => new RegExp(source).test(c)), opacity: panel.style.opacity };
  }, [path, selector, PHASE_CLASS.source]);

const waitForSnapshot = (page, path) =>
  page.waitForFunction((where) => !!window.Turbo.session.view.snapshotCache.get(new URL(where, location.href)), path);

const stretchLeave = (page, selector) =>
  page.addStyleTag({ content: `${selector} { transition-duration: ${LONG_LEAVE}ms !important; }` });

// Holds the visit's document until the returned function is called.
async function holdVisit(page, path) {
  let release;
  const gate = new Promise((done) => { release = done; });
  await page.route((url) => url.pathname === path, async (route) => {
    await gate;
    await route.continue();
  });
  return release;
}

const inLeave = (page, selector) =>
  page.waitForFunction((sel) => {
    const panel = document.querySelector(sel);
    return !!panel._x_transitioning && panel.classList.contains("translate-x-full");
  }, selector);

// Clicks the panel's link, and lets the response through only once the panel is
// sliding out. The page changes with the leave nearly all still to run.
async function clickLinkMidLeave(page, panelSelector, linkSelector, to = "b") {
  const release = await holdVisit(page, "/lab/sidebar_snapshot_b");
  await stretchLeave(page, panelSelector);
  await page.locator(linkSelector).click();
  await inLeave(page, panelSelector);
  release();
  await onLabPage(page, to);
}

async function openLinkSidebar(page, selector) {
  await trigger(page).click();
  await expectOnScreen(page, selector);
  await page.waitForFunction((sel) => !document.querySelector(sel)._x_transitioning, selector);
}

async function start(page, query = "") {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto(`/lab/sidebar_snapshot${query}`);
  await onLabPage(page, "a");
  await page.waitForFunction(() => window.Turbo && window.Alpine && window.Alpine.store("sidebars"));
  return errors;
}

const LINK_IN = (panel) => `${panel} a[href*="sidebar_snapshot_b"]`;

test("after a panel link mid-leave and Back, the gear opens the sidebar on screen", async ({ page }) => {
  const errors = await start(page);
  await openLinkSidebar(page, DESKTOP);
  await clickLinkMidLeave(page, DESKTOP, LINK_IN(DESKTOP));
  await waitForSnapshot(page, "/lab/sidebar_snapshot");

  await page.goBack();
  await onLabPage(page, "a");
  await trigger(page).click();

  await expectOnScreen(page, DESKTOP);
  expect(errors).toEqual([]);
});

test("the same at phone width, on the phone panel", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 800 });
  const errors = await start(page);
  await openLinkSidebar(page, PHONE);
  await clickLinkMidLeave(page, PHONE, LINK_IN(PHONE));
  await waitForSnapshot(page, "/lab/sidebar_snapshot");

  await page.goBack();
  await onLabPage(page, "a");
  await trigger(page).click();

  await expectOnScreen(page, PHONE);
  expect(errors).toEqual([]);
});

test("a host's own panel on the shared partial comes back on screen too", async ({ page }) => {
  const errors = await start(page);
  await page.locator("[data-test='open-host-panel']").click();
  await expectOnScreen(page, HOST);
  await page.waitForFunction((sel) => !document.querySelector(sel)._x_transitioning, HOST);
  const atRest = await page.locator(HOST).getAttribute("class");

  await clickLinkMidLeave(page, HOST, "[data-test='host-panel-link']");
  await waitForSnapshot(page, "/lab/sidebar_snapshot");

  await page.goBack();
  await onLabPage(page, "a");
  await page.locator("[data-test='open-host-panel']").click();

  await expectOnScreen(page, HOST);
  await page.waitForFunction((sel) => !document.querySelector(sel)._x_transitioning, HOST);
  expect(await page.locator(HOST).getAttribute("class"), "the panel's class at rest, whole").toBe(atRest);
  expect(errors).toEqual([]);
});

test("the same with the page transition on", async ({ page }) => {
  const errors = await start(page, "?direction=left");
  await openLinkSidebar(page, DESKTOP);
  await clickLinkMidLeave(page, DESKTOP, LINK_IN(DESKTOP));
  await waitForSnapshot(page, "/lab/sidebar_snapshot?direction=left");

  await page.goBack();
  await onLabPage(page, "a");
  await trigger(page).click();

  await expectOnScreen(page, DESKTOP);
  expect(errors).toEqual([]);
});

test("the snapshot holds no phase class when the link started the leave", async ({ page }) => {
  await start(page);
  await openLinkSidebar(page, DESKTOP);
  await clickLinkMidLeave(page, DESKTOP, LINK_IN(DESKTOP));
  await waitForSnapshot(page, "/lab/sidebar_snapshot");

  const snapshot = await snapshotOf(page, "/lab/sidebar_snapshot", DESKTOP);
  expect(snapshot.phase).toEqual([]);
});

test("the snapshot holds no phase class when turbo:before-cache itself started the leave", async ({ page }) => {
  await start(page);
  await openLinkSidebar(page, DESKTOP);
  await stretchLeave(page, DESKTOP);

  // No click on the panel: the panel is open until the module's own before-cache
  // handler closes it, so the clone is one tick from the leave's first phase.
  await page.evaluate(() => window.Turbo.visit("/lab/sidebar_snapshot_b"));
  await onLabPage(page, "b");
  await waitForSnapshot(page, "/lab/sidebar_snapshot");

  const snapshot = await snapshotOf(page, "/lab/sidebar_snapshot", DESKTOP);
  expect(snapshot.phase).toEqual([]);

  // x-show owns display, and the leave's own hide may land after the clone: what
  // counts is that the page comes back closed, and the gear opens it on screen.
  await page.goBack();
  await onLabPage(page, "a");
  await expect(page.locator(DESKTOP)).toBeHidden();
  await trigger(page).click();
  await expectOnScreen(page, DESKTOP);
});

test("the snapshot holds no phase class with the page transition on", async ({ page }) => {
  const errors = await start(page, "?direction=left");
  await openLinkSidebar(page, DESKTOP);
  await clickLinkMidLeave(page, DESKTOP, LINK_IN(DESKTOP));
  await waitForSnapshot(page, "/lab/sidebar_snapshot?direction=left");

  const snapshot = await snapshotOf(page, "/lab/sidebar_snapshot?direction=left", DESKTOP);
  expect(snapshot.phase).toEqual([]);
  expect(errors).toEqual([]);
});

test("an x-transition with no class names is filed without its inline style", async ({ page }) => {
  await start(page);
  const fade = "[data-test='lab-fade']";
  await page.locator("[data-test='toggle-fade']").click();
  await expect(page.locator(fade)).toBeVisible();
  await page.waitForFunction((sel) => !document.querySelector(sel)._x_transitioning, fade);
  await page.locator("[data-test='toggle-fade']").click();
  await page.waitForFunction((sel) => !!document.querySelector(sel)._x_transitioning, fade);

  await page.evaluate(() => window.Turbo.visit("/lab/sidebar_snapshot_b"));
  await onLabPage(page, "b");
  await waitForSnapshot(page, "/lab/sidebar_snapshot");

  const snapshot = await snapshotOf(page, "/lab/sidebar_snapshot", fade);
  expect(snapshot.opacity, "the leave's inline opacity").toBe("");
});

test("a snapshot already filed mid-slide recovers on restore, and the panel slides", async ({ page }) => {
  await start(page);
  await openLinkSidebar(page, DESKTOP);
  await page.keyboard.press("Escape");
  await page.waitForFunction((sel) => !document.querySelector(sel)._x_transitioning, DESKTOP);
  await page.evaluate(() => window.Turbo.visit("/lab/sidebar_snapshot_b"));
  await onLabPage(page, "b");
  await waitForSnapshot(page, "/lab/sidebar_snapshot");

  // The bytes an unfixed clone holds, written straight into the cache: this reaches
  // the restore path alone, whatever the live cleanup does.
  await page.evaluate((sel) => {
    const snapshot = window.Turbo.session.view.snapshotCache.get(new URL("/lab/sidebar_snapshot", location.href));
    const panel = snapshot.element.querySelector(sel);
    panel.classList.add("transition", "ease-in", "duration-200", "translate-x-full");
    panel.style.removeProperty("display");
  }, DESKTOP);

  await page.goBack();
  await onLabPage(page, "a");
  expect(await phaseClasses(page, DESKTOP), "before the gear").toEqual([]);

  await trigger(page).click();
  await expectOnScreen(page, DESKTOP);
  await expectSlides(page, DESKTOP, () => page.keyboard.press("Escape"), () => trigger(page).click());
});

// Reads the rect each frame across one close and one open. A slide has frames
// between on-screen and off-screen; a pop has none.
async function expectSlides(page, selector, close, open) {
  await page.waitForFunction((sel) => !document.querySelector(sel)._x_transitioning, selector);
  for (const [name, act] of [["slides out", close], ["slides in", open]]) {
    await page.evaluate((sel) => {
      window.__frames = [];
      const panel = document.querySelector(sel);
      const sample = () => {
        window.__frames.push(panel.getBoundingClientRect().x);
        if (window.__frames.length < 60) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    }, selector);
    await act();
    await page.waitForFunction(() => window.__frames.length >= 60);
    const between = await page.evaluate(() => {
      const width = window.innerWidth;
      return window.__frames.filter((x) => x > 0 && x < width && x > width - 320 + 1 && x < width - 1).length;
    });
    expect(between, `${selector} ${name}: frames between on-screen and off-screen`).toBeGreaterThan(0);
  }
}

test("the panel still slides in and out, before a visit and after Back", async ({ page }) => {
  const errors = await start(page);
  await openLinkSidebar(page, DESKTOP);
  await expectSlides(page, DESKTOP, () => page.keyboard.press("Escape"), () => trigger(page).click());

  await clickLinkMidLeave(page, DESKTOP, LINK_IN(DESKTOP));
  await waitForSnapshot(page, "/lab/sidebar_snapshot");
  await page.goBack();
  await onLabPage(page, "a");

  await trigger(page).click();
  await expectOnScreen(page, DESKTOP);
  await expectSlides(page, DESKTOP, () => page.keyboard.press("Escape"), () => trigger(page).click());
  await expectOnScreen(page, DESKTOP);
  expect(errors).toEqual([]);
});
