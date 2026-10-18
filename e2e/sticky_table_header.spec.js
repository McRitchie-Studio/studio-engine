const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests, expectStickyChromeIsLive } = require("./helpers");

// THE STICKY TABLE HEADER'S CLONE SITS ON THE PINNED BAR (config.sticky_table_headers;
// app/assets/javascripts/studio/sticky_table_header.js).
//
// The clone is a position:fixed copy of a table's header row, shown once the real
// one scrolls up under the navbar. Its top used to come from --nav-h, re-read only
// on a scroll, a resize or a header resize. On a scroll-timeline header the compact
// height is published only once the nav-collapse controller starts, and that
// republish resizes nothing, so a page loaded at a restored scroll position placed
// the clone at the EXPANDED height and left it there, rows showing in the gap,
// until the first scroll. Turf Monster /contests measured {"bar":50,"clone":96}.
//
// Every assertion here is the same one: the clone's top equals the pinned bar's
// bottom, within 1px, on every frame the clone is showing.

const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };
const TIMELINE = "/lab/sticky_table?one_row=1&timeline=1";
const SCRIPT = "/lab/sticky_table?one_row=1";

// What one painted frame shows: the header's bottom edge (the pinned bar's, on
// the timeline, where the band above it has scrolled out of the window) and the
// clone's top. Read after the frame's paint (a task queued from the frame
// callback), so a placement made in the frame's ResizeObserver pass counts.
const READ = () => {
  const header = document.querySelector("header.nav-shell");
  const clone = document.querySelector(".sticky-table-header-clone");
  const shown = !!clone && getComputedStyle(clone).display !== "none";
  return {
    y: Math.round(window.scrollY),
    bar: Math.round(header.getBoundingClientRect().bottom * 10) / 10,
    clone: shown ? Math.round(clone.getBoundingClientRect().top * 10) / 10 : null,
    timeline: header.hasAttribute("data-nav-timeline-on")
  };
};

const settled = (page) => page.evaluate(() => new Promise((resolve) => {
  let n = 0;
  const tick = () => (++n >= 6 ? resolve() : requestAnimationFrame(tick));
  requestAnimationFrame(tick);
}));

const readNow = (page) => page.evaluate(`(${READ.toString()})()`);

// Scrolls by each step, one step per frame, and reads every painted frame,
// including the frames a script-mode collapse keeps settling after the last
// step.
const scrollAndSample = (page, steps, tail = 16) => page.evaluate(async ({ steps, tail, readSrc }) => {
  const read = eval(`(${readSrc})`);
  const painted = () => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
  const rows = [];
  for (const s of steps) { window.scrollBy(0, s); await painted(); rows.push(read()); }
  for (let i = 0; i < tail; i++) { await painted(); rows.push(read()); }
  return rows;
}, { steps, tail, readSrc: READ.toString() });

function expectGlued(rows, label) {
  const shown = rows.filter((r) => r.clone !== null);
  expect(shown.length, `${label}: the clone showed on some frame (the table pinned its header)`).toBeGreaterThan(0);
  const off = shown.filter((r) => Math.abs(r.clone - r.bar) > 1);
  expect(off, `${label}: frames where the clone's top was not the bar's bottom`).toEqual([]);
}

// Holds the header's nav-collapse controller back for `ms` after the document
// loads: the attribute Stimulus binds by is taken off the header as it is parsed
// and put back later, so the controller starts late, exactly as a slow module
// load starts it on a real host.
const holdController = (page, ms) => page.addInitScript((ms) => {
  const ATTR = "data-studio-controller";
  const take = (header) => {
    if (!header || !header.matches("header.nav-shell") || !header.hasAttribute(ATTR)) return;
    const value = header.getAttribute(ATTR);
    header.removeAttribute(ATTR);
    window.__heldController = () => header.setAttribute(ATTR, value);
  };
  const watch = new MutationObserver((ms) => ms.forEach((m) => m.addedNodes.forEach((n) => n.nodeType === 1 && take(n))));
  watch.observe(document, { childList: true, subtree: true });
  window.addEventListener("load", () => {
    watch.disconnect();
    setTimeout(() => window.__heldController && window.__heldController(), ms);
  });
}, ms);

async function scrollToPinned(page, y) {
  await page.evaluate((y) => window.scrollTo(0, y), y);
  await settled(page);
}

test("reload at a restored scroll position with the controller held back: the clone sits on the compact bar", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(TIMELINE);
  await expectStickyChromeIsLive(page, expect);
  await expect(page.locator("header.nav-shell")).toHaveAttribute("data-nav-timeline-on", "");
  await scrollToPinned(page, 608);
  const before = await readNow(page);
  expect(before.clone, "the table's header row is pinned at 608").not.toBeNull();

  await holdController(page, 1200);
  await page.reload();
  await page.waitForFunction(() => window.__heldController);
  const restored = await readNow(page);
  expect(restored.y, "the reload restored the scroll position").toBeGreaterThan(400);
  expect(restored.timeline, "the controller is still held back").toBe(false);

  await expect(page.locator("header.nav-shell")).toHaveAttribute("data-nav-timeline-on", "", { timeout: 5000 });
  await settled(page);
  const after = await readNow(page);
  expect(after.timeline).toBe(true);
  expect(after.y, "nothing scrolled the page").toBe(restored.y);
  expect(after.clone, "the clone is showing").not.toBeNull();
  expect(Math.abs(after.clone - after.bar), `clone ${after.clone} vs compact bar ${after.bar}`).toBeLessThanOrEqual(1);
  expect(errors).toEqual([]);
});

test("timeline header: the clone stays on the bar through a slow scroll and a flick", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(TIMELINE);
  await expectStickyChromeIsLive(page, expect);
  await expect(page.locator("header.nav-shell")).toHaveAttribute("data-nav-timeline-on", "");
  await page.evaluate(() => document.fonts.ready);
  await scrollToPinned(page, 150);

  const slow = await scrollAndSample(page, Array(40).fill(8));
  expectGlued(slow, "slow scroll");
  const flick = await scrollAndSample(page, [700, -1200, 900]);
  expectGlued(flick, "flick");
  expect(errors).toEqual([]);
});

test("script-mode header on a phone: the clone follows the bar's bottom through the collapse", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(PHONE);
  await page.goto(TIMELINE);
  await expectStickyChromeIsLive(page, expect);
  const header = page.locator("header.nav-shell");
  // Below 768px the timeline host runs the script collapse: --nav-p per frame.
  await expect(header).not.toHaveAttribute("data-nav-timeline-on", "");
  await page.evaluate(() => document.fonts.ready);
  await settled(page);

  // A flick from the top lands the table's header row well above the bar in one
  // frame, and the collapse then catches up over the frames that follow (its
  // per-frame clamp): the bar's bottom moves on every one of them under a
  // showing clone.
  const flick = await scrollAndSample(page, [900], 24);
  const moving = flick.filter((r, i) => i > 0 && r.bar !== flick[i - 1].bar && r.clone !== null);
  expect(moving.length, "frames where the bar moved under a showing clone").toBeGreaterThan(2);
  expectGlued(flick, "flick through the collapse");

  // Back toward the top and down again slowly: the bar expands and collapses
  // while the clone shows or hides.
  const slow = await scrollAndSample(page, [...Array(40).fill(-20), ...Array(40).fill(20)]);
  expectGlued(slow, "slow scroll");
  expect(errors).toEqual([]);
});

test("crossing 768px while scrolled re-places the clone on the bar each way", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(TIMELINE);
  await expectStickyChromeIsLive(page, expect);
  const header = page.locator("header.nav-shell");
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");
  await scrollToPinned(page, 608);

  await page.setViewportSize({ width: 700, height: 800 });
  await expect(header).not.toHaveAttribute("data-nav-timeline-on", "");
  await settled(page);
  const narrow = await readNow(page);
  expect(narrow.clone, "the clone shows at 700px").not.toBeNull();
  expect(Math.abs(narrow.clone - narrow.bar), `700px: clone ${narrow.clone} vs bar ${narrow.bar}`).toBeLessThanOrEqual(1);

  await page.setViewportSize(DESKTOP);
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");
  await settled(page);
  const wide = await readNow(page);
  expect(wide.clone, "the clone shows back at 1280px").not.toBeNull();
  expect(Math.abs(wide.clone - wide.bar), `1280px: clone ${wide.clone} vs bar ${wide.bar}`).toBeLessThanOrEqual(1);
  expect(errors).toEqual([]);
});

test("a plain script-mode host (no timeline): the clone sits on the bar after a reload at scroll", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(SCRIPT);
  await expectStickyChromeIsLive(page, expect);
  await scrollToPinned(page, 608);
  await page.reload();
  await settled(page);
  const after = await readNow(page);
  expect(after.y).toBeGreaterThan(400);
  expect(after.clone).not.toBeNull();
  expect(Math.abs(after.clone - after.bar), `clone ${after.clone} vs bar ${after.bar}`).toBeLessThanOrEqual(1);
  expect(errors).toEqual([]);
});
