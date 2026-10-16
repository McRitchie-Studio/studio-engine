const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// THE SCROLL-DRIVEN COLLAPSE (engine.css; studio/nav_collapse's timeline mode;
// config.navbar_scroll_timeline). From 768px the header keeps one height, its
// top band scrolls away with the page, and its contents shrink by transforms
// on the page's scroll timeline, so no script runs per frame and no frame
// relayouts. The lab page opts in for its own request with ?timeline=1.

const DESKTOP = { width: 1280, height: 800 };
const TIMELINE = "/lab/bar_stack?one_row=1&sidebar=1&timeline=1";

// Scrolls in steps (slow, then a flick down and back) and reads every frame:
// the header's box, the document's height, where the page's own content sits,
// and every inline style write the header took.
const flick = (page) => page.evaluate(async () => {
  const h = document.querySelector("header.nav-shell");
  const frame = () => new Promise((r) => requestAnimationFrame(r));
  const writes = [];
  new MutationObserver((ms) => ms.forEach((m) => writes.push(m.attributeName)))
    .observe(h, { attributes: true, attributeFilter: ["style"] });
  // The first in-flow block of the page's own content after the header.
  const probe = [...document.body.querySelectorAll("*")].find((el) =>
    (h.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING) && !h.contains(el) &&
    getComputedStyle(el).position === "static" && el.getBoundingClientRect().height > 0);
  const rows = [];
  const read = () => {
    const r = h.getBoundingClientRect();
    rows.push({ box: r.height, bottom: r.bottom, docH: document.documentElement.scrollHeight,
      content: probe.getBoundingClientRect().top + window.scrollY });
  };
  read();
  for (const s of [10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 600]) { window.scrollBy(0, s); await frame(); read(); }
  const collapsed = rows[rows.length - 1];
  window.scrollBy(0, -2000); await frame(); read();
  return { rows, collapsed, styleWrites: writes.length };
});

test("the header collapses on the scroll timeline: one box height, no per-frame writes", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(TIMELINE);
  await page.evaluate(() => document.fonts.ready);
  const header = page.locator("header.nav-shell");
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");

  // What the controller measured: the band is the header's own collapse.
  const measured = await header.evaluate((h) => {
    const band = parseFloat(h.style.getPropertyValue("--nav-band"));
    h.style.setProperty("--nav-p", "1");
    const collapsed = h.offsetHeight;
    h.style.removeProperty("--nav-p");
    return { band, rest: h.offsetHeight, collapsed };
  });
  expect(measured.band).toBeGreaterThan(0);
  expect(measured.band).toBeCloseTo(measured.rest - measured.collapsed, 0);

  const run = await flick(page);
  expect(new Set(run.rows.map((r) => r.box)).size, "the header's box never changes height").toBe(1);
  expect(new Set(run.rows.map((r) => r.docH)).size, "the document never changes height").toBe(1);
  const content = run.rows.map((r) => r.content);
  expect(Math.max(...content) - Math.min(...content), `the page never moves by itself ${JSON.stringify(content)}`).toBeLessThanOrEqual(0.5);
  expect(run.styleWrites, "inline style writes on the header during the scroll").toBe(0);

  // Stuck, what shows is the compact bar: the collapsed height.
  expect(Math.abs(run.collapsed.bottom - measured.collapsed)).toBeLessThanOrEqual(1);
  // Stuck: --nav-h is the compact bar too, so an anchor's scroll-margin clears the bar.
  await page.evaluate(() => window.scrollTo(0, 1200));
  await expect(header).toHaveClass(/is-scrolled/);
  await expect.poll(() => page.evaluate(() => parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--nav-h"))))
    .toBeCloseTo(measured.collapsed, 0);
  // Nothing of the header takes the pointer below the bar: the row's slide
  // leaves its empty padding hanging under it, and that ate clicks on the
  // hub's pinned lane headers.
  const below = await page.evaluate(() => {
    const bar = document.querySelector("header.nav-shell").getBoundingClientRect();
    return [0.1, 0.5, 0.9].map((fx) => {
      const el = document.elementFromPoint(innerWidth * fx, bar.bottom + 4);
      return !!(el && el.closest("header.nav-shell"));
    });
  });
  expect(below, "the header takes the pointer under its bar").toEqual([false, false, false]);
  // The scrolled marker, but not the border: a border would add a pixel of
  // height. The line and shadow are drawn by ::after on the timeline.
  await expect(header).not.toHaveClass(/border-b/);
  const lit = await header.evaluate((h) => getComputedStyle(h, "::after").opacity);
  expect(Number(lit)).toBe(1);
  expect(errors).toEqual([]);
});

test("collapsed, the avatar and name land on the --nav-p path's sizes, the controls still evenly spaced", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(TIMELINE);
  await page.evaluate(() => document.fonts.ready);
  await page.evaluate(() => window.scrollTo(0, 1200));
  await expect(page.locator("header.nav-shell")).toHaveClass(/is-scrolled/);

  const read = () => page.evaluate(() => {
    // Ink to ink, as e2e/navbar_account_row.spec.js measures it at rest.
    const ink = (svg) => {
      let left = Infinity, right = -Infinity;
      svg.querySelectorAll("path, circle").forEach((el) => {
        const box = el.getBBox(), m = el.getScreenCTM();
        [box.x, box.x + box.width].forEach((x) => {
          const sx = m.a * x + m.c * box.y + m.e;
          left = Math.min(left, sx);
          right = Math.max(right, sx);
        });
      });
      return [left, right];
    };
    const shown = (list) => [...list].find((el) => el.getBoundingClientRect().width > 0);
    const moon = ink(shown(document.querySelectorAll("header [data-nav-theme-toggle='desktop'] .nav-toggle-icon svg")));
    const gear = ink(shown(document.querySelectorAll("header [data-nav-tools] [data-link-sidebar-trigger] svg")));
    const range = document.createRange();
    const nameEl = document.querySelector("header [data-nav-name]");
    range.selectNodeContents(nameEl);
    const name = range.getBoundingClientRect();
    const avatar = document.querySelector("header [data-nav-account] [aria-hidden] > *").getBoundingClientRect();
    return {
      avatar: avatar.height,
      name: parseFloat(getComputedStyle(nameEl).fontSize) * (nameEl.getBoundingClientRect().height / parseFloat(getComputedStyle(nameEl).height)),
      gaps: [gear[0] - moon[1], name.left - gear[1], avatar.left - name.right],
    };
  });
  await expect.poll(async () => Math.round((await read()).avatar)).toBe(32);
  const m = await read();
  expect(m.name).toBeCloseTo(32 / 3 / 0.7, 0);
  const gaps = m.gaps;
  gaps.forEach((gap) => expect(Math.abs(gap - 12), JSON.stringify(gaps)).toBeLessThanOrEqual(1));
});

test("below 768px the header runs the --nav-p collapse, and widening hands it back", async ({ page }) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(TIMELINE);
  const header = page.locator("header.nav-shell");
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(header).not.toHaveAttribute("data-nav-timeline-on", /.*/);
  await page.evaluate(() => window.scrollTo(0, 600));
  await expect.poll(() => header.evaluate((h) => h.style.getPropertyValue("--nav-p"))).toBe("1.0000");

  await page.evaluate(() => window.scrollTo(0, 0));
  await page.setViewportSize(DESKTOP);
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");
  // Nothing the --nav-p path wrote survives the swap.
  const left = await header.evaluate((h) => ["--nav-p", "--nav-hold", "--nav-hold-fix", "margin-bottom"].map((p) => h.style.getPropertyValue(p)).join(""));
  expect(left).toBe("");
  expect(errors).toEqual([]);
});

test("without the opt-in the header is on the --nav-p collapse, as before", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto("/lab/bar_stack?one_row=1&sidebar=1");
  const header = page.locator("header.nav-shell");
  await expect(header).not.toHaveAttribute("data-nav-timeline", /.*/);
  await page.evaluate(() => window.scrollTo(0, 1200));
  await expect.poll(() => header.evaluate((h) => h.style.getPropertyValue("--nav-p"))).toBe("1.0000");
});
