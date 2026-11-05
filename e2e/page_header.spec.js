const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests, expectStickyChromeIsLive } = require("./helpers");

// [e2e] THE TRIPLE STACK (studio/_page_header, docs/PAGE_HEADER.md): navbar,
// page row, table header, each below the last, on the real /admin/models and the
// real style guide. Alex McRitchie's QA note of 2026-11-03: the row was a grey bar
// at rest, and on /admin/models the table's sticky header sat on top of the row.
//
// Every claim here is a computed style or a box, so the response bytes cannot
// answer any of them.
//
// CONTROLS, each run against this file with the lab server restarted:
//   - data-pin removed from the row: the clone sits at the navbar's bottom, on top
//     of the row. 3 red, every spec that reads the clone.
//   - the row positioned off --pin-stack-bottom: the row chases its own edge. 4 red.
//   - the row's background not transparent: 3 red, every spec that reads the rest.
//   - "page-header" removed from LAZY: 7 red, every spec that needs the controller.
//   - revealOpenTab not called: 1 red, the open tab.
//   - the failed-load selector dropped from the bar's rule: 1 red, the failed load.
//   - no fix to the title's layout (before this spec's fix): 1 red, the long title,
//     on the page's sideways overflow.
//   - the flex and grid measure removed from the controller: 1 red, the parents, on
//     the bar at rest.

const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };
const MODELS = "/lab/admin_models/sessions";
const TIMELINE = `${MODELS}?timeline=1`;
const STYLE = "/lab/style_nav";
const LAB = "/lab/page_header";

const modelsRow = (page) => page.locator("nav[aria-label='Models']");
const styleRow = (page) => page.locator("nav[aria-label='Style guide sections']");

const TRANSPARENT = "rgba(0, 0, 0, 0)";

// Polls: the bar fades over 150ms, so a single read can catch the fade.
const paint = (locator) => locator.evaluate((el) => {
  const s = getComputedStyle(el);
  return { background: s.backgroundColor, top: s.borderTopColor, bottom: s.borderBottomColor };
});

async function expectAtRest(locator) {
  await expect.poll(() => paint(locator)).toEqual({ background: TRANSPARENT, top: TRANSPARENT, bottom: TRANSPARENT });
  await expect(locator).not.toHaveAttribute("data-stuck", "");
}

async function expectBar(locator) {
  await expect(locator).toHaveAttribute("data-stuck", "");
  await expect.poll(async () => (await paint(locator)).background).not.toBe(TRANSPARENT);
  await expect.poll(async () => (await paint(locator)).bottom).not.toBe(TRANSPARENT);
}

// What one painted frame shows. Read after the frame's paint, so a placement made
// in the frame's ResizeObserver pass counts.
const READ = () => {
  const box = (el) => el.getBoundingClientRect();
  const nav = box(document.querySelector("header.nav-shell"));
  const row = box(document.querySelector("nav[aria-label='Models']"));
  const clone = document.querySelector(".sticky-table-header-clone");
  const shown = !!clone && getComputedStyle(clone).display !== "none";
  const round = (n) => Math.round(n * 10) / 10;
  return {
    y: Math.round(window.scrollY),
    nav: round(nav.bottom),
    rowTop: round(row.top),
    rowBottom: round(row.bottom),
    clone: shown ? round(box(clone).top) : null
  };
};

const scrollAndSample = (page, steps, tail = 16) => page.evaluate(async ({ steps, tail, readSrc }) => {
  const read = eval(`(${readSrc})`);
  const painted = () => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
  const rows = [];
  for (const s of steps) { window.scrollBy(0, s); await painted(); rows.push(read()); }
  for (let i = 0; i < tail; i++) { await painted(); rows.push(read()); }
  return rows;
}, { steps, tail, readSrc: READ.toString() });

// Small steps through the collapse, then a flick.
const STEPS = [...Array(40).fill(14), 90, 140, 200];

function expectStacked(rows, label) {
  const shown = rows.filter((r) => r.clone !== null);
  expect(shown.length, `${label}: the table pinned its header on some frame`).toBeGreaterThan(0);

  const overlaps = shown.filter((r) => Math.abs(r.clone - r.rowBottom) > 1);
  expect(overlaps, `${label}: frames where the table header's top was not the row's bottom`).toEqual([]);

  const under = rows.filter((r) => r.rowTop < r.nav - 1);
  expect(under, `${label}: frames where the row's top rode up under the navbar`).toEqual([]);
}

async function open(page, url, viewport) {
  await blockOffsiteRequests(page);
  await page.setViewportSize(viewport);
  await page.goto(url);
  await expectStickyChromeIsLive(page, expect);
}

// Each spec walks both widths inside one test: the lane's static guard counts
// test() calls in the source, so a loop around test() would not match the lister.
const WIDTHS = [["desktop", DESKTOP], ["phone", PHONE]];

test("the row is a plain header at rest and takes the bar once stuck, at both widths", async ({ page }) => {
  const errors = watchPageErrors(page);
  for (const [, viewport] of WIDTHS) {
    await open(page, MODELS, viewport);
    await expectAtRest(modelsRow(page));

    await page.evaluate(() => window.scrollTo({ top: 400, behavior: "instant" }));
    await expectBar(modelsRow(page));

    // A transition, both ways: the bar leaves again at the top.
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
    await expectAtRest(modelsRow(page));
  }
  expect(errors).toEqual([]);
});

test("navbar, row and table header stack with no overlap on every frame, at both widths", async ({ page }) => {
  for (const [name, viewport] of WIDTHS) {
    await open(page, MODELS, viewport);
    const rows = await scrollAndSample(page, STEPS);
    expectStacked(rows, name);

    const last = rows[rows.length - 1];
    expect(Math.abs(last.rowTop - last.nav), `${name}: the row's top is the navbar's bottom`).toBeLessThanOrEqual(1);
  }
});

test("the style guide's row rests plain and takes the bar, at both widths", async ({ page }) => {
  await blockOffsiteRequests(page);
  for (const [, viewport] of WIDTHS) {
    await page.setViewportSize(viewport);
    await page.goto(STYLE);
    await expectAtRest(styleRow(page));

    await page.evaluate(() => window.scrollTo({ top: 600, behavior: "instant" }));
    await expectBar(styleRow(page));
    expect((await styleRow(page).boundingBox()).y).toBeLessThanOrEqual(1);
  }
});

test("on a scroll-timeline header the stack holds too", async ({ page }) => {
  await open(page, TIMELINE, DESKTOP);
  await expect(page.locator("header.nav-shell")).toHaveAttribute("data-nav-timeline-on", "");
  await expectAtRest(modelsRow(page));

  const rows = await scrollAndSample(page, STEPS);
  expectStacked(rows, "timeline");
  await expectBar(modelsRow(page));
});

test("a page loaded already scrolled has the bar and the stack", async ({ page }) => {
  await open(page, MODELS, DESKTOP);
  await page.evaluate(() => window.scrollTo({ top: 500, behavior: "instant" }));
  await page.reload();
  await page.evaluate(() => window.scrollTo({ top: 500, behavior: "instant" }));
  await expectBar(modelsRow(page));
  expectStacked(await scrollAndSample(page, [], 12), "restored");
});

test("at desktop width the version sits beside the title and the tabs float right", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(STYLE);

  const row = await styleRow(page).boundingBox();
  const title = await styleRow(page).locator("h1").boundingBox();
  const meta = await styleRow(page).locator(".page-header-meta").boundingBox();
  const first = await styleRow(page).locator("a").first().boundingBox();
  const last = await styleRow(page).locator("a").last().boundingBox();

  expect(meta.x - (title.x + title.width), "the version is beside the title").toBeLessThan(16);
  expect(first.x, "the tabs start past the version").toBeGreaterThan(meta.x + meta.width);
  const padding = await styleRow(page).evaluate((el) => parseFloat(getComputedStyle(el).paddingRight));
  expect(Math.abs(row.x + row.width - padding - (last.x + last.width)), "the last tab meets the row's right edge").toBeLessThanOrEqual(1);
});

test.describe("at phone width", () => {
  test.use({ viewport: PHONE });

  test("the tabs scroll sideways inside the row and the page does not", async ({ page }) => {
    await blockOffsiteRequests(page);
    await page.goto("/lab/admin_models/users");
    const tabs = modelsRow(page).locator(".page-header-tabs");

    const before = await tabs.evaluate((el) => ({ client: el.clientWidth, scroll: el.scrollWidth, left: el.scrollLeft }));
    expect(before.scroll, "the lab's tabs overflow a phone").toBeGreaterThan(before.client);
    await expect(tabs).toHaveAttribute("data-fade-end", "");
    await expect(tabs).not.toHaveAttribute("data-fade-start", "");

    await tabs.evaluate((el) => { el.scrollLeft = 120; });
    await expect.poll(() => tabs.evaluate((el) => el.scrollLeft)).toBe(120);
    await expect(tabs).toHaveAttribute("data-fade-start", "");

    const page_ = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
    expect(page_.scroll).toBeLessThanOrEqual(page_.client);
  });

  test("the open tab is scrolled into view", async ({ page }) => {
    await blockOffsiteRequests(page);
    await page.goto("/lab/admin_models/invoices");
    const tabs = modelsRow(page).locator(".page-header-tabs");
    const open = modelsRow(page).locator("a[aria-current='page']");
    await expect(open).toHaveText("Invoices");

    await expect.poll(() => tabs.evaluate((el) => el.scrollLeft)).toBeGreaterThan(0);
    const box = await tabs.boundingBox();
    const tab = await open.boundingBox();
    expect(tab.x, "the open tab starts inside the tabs").toBeGreaterThanOrEqual(box.x);
    expect(tab.x + tab.width, "and ends inside them").toBeLessThanOrEqual(box.x + box.width + 1);
  });
});

test("a row whose controller failed to load keeps its bar", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.route("**/page_header_controller*", (route) => route.abort());
  await page.setViewportSize(DESKTOP);
  await page.goto(MODELS);

  await expect(page.locator(".page-header-sentinel")).toHaveAttribute("data-studio-controller-failed", "page-header");
  await expect.poll(async () => (await paint(modelsRow(page))).background).not.toBe(TRANSPARENT);
});

// What a long title must leave true at one width: nothing past the viewport, the
// control on the right inside it, and the stack still reading the row's real height.
async function expectLongTitleHolds(page, viewport, query, label) {
  await page.setViewportSize(viewport);
  await page.goto(`${LAB}?${new URLSearchParams(query)}`);
  const row = page.locator("[data-pin='page']");
  const title = row.locator("h1");

  const widths = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }));
  expect(widths.scroll, `${label}: the page has no sideways overflow`).toBeLessThanOrEqual(widths.client);

  const box = await title.boundingBox();
  expect(box.x + box.width, `${label}: the title ends inside the viewport`).toBeLessThanOrEqual(viewport.width);
  const lines = await title.evaluate((el) => el.clientHeight / parseFloat(getComputedStyle(el).lineHeight));
  expect(lines, `${label}: the title stops at three lines`).toBeLessThanOrEqual(3.01);

  if (query.right === "actions") {
    const action = await row.locator(".page-header-actions a").boundingBox();
    expect(action.x + action.width, `${label}: the action is on the page`).toBeLessThanOrEqual(viewport.width);
  } else if (query.right !== "none") {
    const tabs = row.locator(".page-header-tabs");
    await tabs.evaluate((el) => { el.scrollLeft = el.scrollWidth; });
    const strip = await tabs.boundingBox();
    const last = await row.locator(".page-header-tabs a").last().boundingBox();
    expect(strip.width, `${label}: the tabs keep room to show a tab`).toBeGreaterThanOrEqual(96);
    expect(last.x + last.width, `${label}: the last tab scrolls into view`).toBeLessThanOrEqual(viewport.width);
  }

  // The row may be taller now: what sits under it has to know.
  await page.evaluate(() => window.scrollTo({ top: 400, behavior: "instant" }));
  await expect(row).toHaveAttribute("data-stuck", "");
  await expect.poll(() => row.evaluate((el) => {
    const published = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--pin-stack-bottom"));
    return Math.abs(published - el.getBoundingClientRect().bottom);
  }), `${label}: the stack reads the row's height`).toBeLessThanOrEqual(1);
}

test("a long title wraps inside the page and leaves the tabs reachable, at 320, 390 and 1280", async ({ page }) => {
  await blockOffsiteRequests(page);
  const words = "The quarterly reconciliation of every outstanding contest entry, its settlement and each of its late corrections, by operator and by week, for the whole of the season";
  const unbroken = "Supercalifragilisticexpialidocious".repeat(4);

  for (const width of [320, 390, 1280]) {
    const viewport = { width, height: 800 };
    await expectLongTitleHolds(page, viewport, { title: words, right: "tabs" }, `${width} words, tabs`);
    await expectLongTitleHolds(page, viewport, { title: unbroken, right: "tabs", meta: "1" }, `${width} unbroken, meta, tabs`);
    await expectLongTitleHolds(page, viewport, { title: words, right: "actions" }, `${width} words, action`);
    await expectLongTitleHolds(page, viewport, { title: unbroken, right: "none" }, `${width} unbroken, title only`);
  }

  // A short title does not wrap the row: the tabs stay on its line at the narrowest width.
  await page.setViewportSize({ width: 320, height: 800 });
  await page.goto(STYLE);
  const title = await styleRow(page).locator("h1").boundingBox();
  const tabs = await styleRow(page).locator(".page-header-tabs").boundingBox();
  expect(tabs.y, "the tabs are beside a short title").toBeLessThan(title.y + title.height);
});

// Scrolled first, so the rest is a transition and cannot pass before the controller
// has connected. In these parents the sentinel stays at the parent's start.
test("a row in a flex or grid parent with a sibling above it has no bar at rest", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  for (const parent of ["flex", "grid"]) {
    await page.goto(`${LAB}?parent=${parent}`);
    const row = page.locator("[data-pin='page']");

    await page.evaluate(() => window.scrollTo({ top: 600, behavior: "instant" }));
    await expectBar(row);

    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
    await expectAtRest(row);
  }
});
