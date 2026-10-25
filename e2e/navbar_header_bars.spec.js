const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// Studio.navbar_header_bars: a control bar INSIDE the pinned header (an
// impersonation bar's JS-free "Return to admin") must stay on screen, and its
// button must stay the topmost thing under the pointer, however far the page
// scrolls. Three shapes of the header: the scroll timeline from 768px (the
// header sticks at minus its band, so engine.css carries the bars down by it),
// the --nav-p collapse from 768px, and a phone. The lab adds the bar for its
// own request with ?header_bars=1 (e2e_lab_controller#bar_stack_locals).

const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };

// Where the bar and its button sit, and what the pointer would hit at the
// button's centre.
const readBar = (page) => page.evaluate(() => {
  const bar = document.querySelector("[data-nav-header-bars]");
  const button = document.querySelector("[data-test=header-bar-escape]");
  const r = bar.getBoundingClientRect();
  const b = button.getBoundingClientRect();
  const hit = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2);
  return { top: r.top, bottom: r.bottom, inHeader: !!bar.closest("header.nav-shell"), buttonOnTop: hit === button };
});

// One test per shape, each spelled out so the lane's contract counts it.
const holdsPinned = async (page, viewport, query) => {
  await blockOffsiteRequests(page);
  const errors = watchPageErrors(page);
  await page.setViewportSize(viewport);
  await page.goto(`/lab/bar_stack?signed_in=1&header_bars=1${query}`);
  await page.evaluate(() => document.fonts.ready);

  const rest = await readBar(page);
  expect(rest.inHeader, "the bar renders inside the header").toBe(true);
  expect(rest.buttonOnTop, "unscrolled, the escape button takes the pointer").toBe(true);

  // Slow steps through the collapse, then far down the page.
  const rows = [];
  for (const y of [10, 20, 40, 60, 80, 120, 200, 600, 1500, 3000]) {
    await page.evaluate((y) => window.scrollTo(0, y), y);
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    rows.push({ y, ...(await readBar(page)) });
  }
  for (const row of rows) {
    expect(row.top, `at scrollY ${row.y} the bar's top is on screen ${JSON.stringify(row)}`).toBeGreaterThanOrEqual(-0.5);
    expect(row.buttonOnTop, `at scrollY ${row.y} the escape button takes the pointer ${JSON.stringify(row)}`).toBe(true);
  }
  // Once the bar stack above has scrolled away, the bar holds the window's top.
  const far = rows[rows.length - 1];
  expect(Math.abs(far.top), `far down the page the bar sits at the top ${JSON.stringify(far)}`).toBeLessThanOrEqual(1);
  expect(errors).toEqual([]);
};

test("header bars stay pinned and clickable on the scroll timeline, desktop", async ({ page }) => {
  await holdsPinned(page, DESKTOP, "&timeline=1");
});

test("header bars stay pinned and clickable on the --nav-p collapse, desktop", async ({ page }) => {
  await holdsPinned(page, DESKTOP, "");
});

test("header bars stay pinned and clickable on a phone", async ({ page }) => {
  await holdsPinned(page, PHONE, "&timeline=1");
});
