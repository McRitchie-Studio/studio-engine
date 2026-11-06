const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests, expectStickyChromeIsLive } = require("./helpers");

// [e2e] IN-PAGE LINKS (studio/in_page_links, docs/PAGE_HEADER.md "In-page links"). Alex
// McRitchie, 2026-11-06, on QA /admin/style: "I don't like when clicking the admin/style pills
// there seems to be a full page load. The system needs to understand when a scroll down is
// the solution rather than a page change."
//
// Turbo 8 makes a click on "#tricks" a full visit: a fetch, a render, turbo:visit, and the
// page transition's flags on <html>. The style guide under the real navbar, with Turbo and a
// page transition on, is the page he saw.
//
// CONTROL: with the module's own install line (the last line of studio/in_page_links) taken
// out, four of the six go red: the first on the visit count (1, a full Turbo visit), Back on
// five Turbo visits, reduced motion on its visit, and the Turbo-free page on the frames
// mid-scroll (none: a cut). The highlight and cross-page tests stay green: an instant jump
// passes no tab, and a cross-page link is Turbo's either way.

const DESKTOP = { width: 1280, height: 800 };
const TURBO = "/lab/style_chrome?turbo=1&direction=left";
const PLAIN = "/lab/style_chrome";
const styleRow = (page) => page.locator(".page-header:has(> nav[aria-label='Style guide sections'])");
const pill = (page, label) => styleRow(page).locator("a", { hasText: label });

// The Loaders section's feed lives at /admin/style/loaders_feed, which a host serves to its
// admins. The dummy gates that route, so it is answered from the lab's own feed. A smooth tab
// scroll passes the section, and its next page loads as on a reader's own scroll.
const serveFeed = (page) => page.route("**/admin/style/loaders_feed*", async (route) => {
  const url = new URL(route.request().url());
  await route.fulfill({ response: await route.fetch({ url: `${url.origin}/lab/loaders_feed${url.search}` }) });
});

async function open(page, url) {
  await blockOffsiteRequests(page);
  await serveFeed(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(url);
  await expectStickyChromeIsLive(page, expect);
  await page.waitForFunction(() => document.documentElement.hasAttribute("data-pin-live"));
}

// Counts what a page change would fire, and samples every frame from the click on: the
// scroll, the flags on <html>, and which tab is current.
async function watch(page) {
  await page.evaluate(() => {
    const seen = { visits: 0, fetches: 0, scrolls: 0, ends: 0, frames: [] };
    window.__inPage = seen;
    document.addEventListener("turbo:visit", () => { seen.visits += 1; });
    // A fetch of this page itself. The Loaders section's lazy frame fetches its own feed.
    document.addEventListener("turbo:before-fetch-request", (event) => {
      if (new URL(event.detail.url).pathname === location.pathname) seen.fetches += 1;
    });
    document.addEventListener("studio:in-page-scroll", () => { seen.scrolls += 1; });
    document.addEventListener("studio:in-page-scroll-end", () => { seen.ends += 1; });
    const tick = () => {
      const root = document.documentElement;
      const current = document.querySelector("nav[aria-label='Style guide sections'] a[aria-current='true']");
      seen.frames.push({
        y: window.scrollY,
        transition: root.hasAttribute("data-page-transition") || root.hasAttribute("data-page-transition-visit"),
        loader: [...document.querySelectorAll("[data-studio-loader-overlay]")].some((el) => !el.hidden) || root.hasAttribute("aria-busy"),
        current: current ? current.textContent.trim() : null,
      });
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
}
const seen = (page) => page.evaluate(() => window.__inPage);
// The module's end event, or, with the module gone (the control), a moment for the visit.
const settled = (page) => page
  .waitForFunction(() => window.__inPage.ends >= window.__inPage.scrolls && window.__inPage.scrolls > 0, null, { timeout: 4000 })
  .catch(() => page.waitForTimeout(1000));

async function clickAndSettle(page, label, id) {
  await pill(page, label).click();
  await page.waitForFunction((want) => location.hash === `#${want}`, id);
  await settled(page);
  await page.waitForTimeout(200);
}

test("a style tab scrolls down the page, with no Turbo visit and no page transition", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, TURBO);
  await expect(page.locator("html")).toHaveAttribute("data-page-transition-direction", "left");
  await watch(page);
  const start = await page.evaluate(() => window.scrollY);

  await clickAndSettle(page, "Modals", "modals");
  const result = await seen(page);

  expect(result.visits, "no turbo:visit").toBe(0);
  expect(result.fetches, "the page is not fetched again").toBe(0);
  expect(result.frames.some((f) => f.transition), "no page-transition flag on <html> in any frame").toBe(false);
  expect(result.frames.some((f) => f.loader), "no loader overlay and no busy page in any frame").toBe(false);

  const ys = result.frames.map((f) => f.y);
  const end = ys[ys.length - 1];
  expect(end, "the page scrolled down").toBeGreaterThan(start + 500);
  const between = ys.filter((y) => y > start + 20 && y < end - 20);
  expect(between.length, `frames mid-scroll, a smooth scroll and not a cut (${ys.join(",")})`).toBeGreaterThanOrEqual(3);
  for (let i = 1; i < ys.length; i++) expect(ys[i], "the scroll only goes down").toBeGreaterThanOrEqual(ys[i - 1] - 1);

  // The section lands under the page row, not beneath the pinned chrome.
  const row = await styleRow(page).evaluate((el) => el.getBoundingClientRect().bottom);
  const top = await page.locator("#modals").evaluate((el) => el.getBoundingClientRect().top);
  expect(top, "the section's top is not under the row").toBeGreaterThanOrEqual(row - 3);
  expect(top, "the section's top is near the row").toBeLessThan(row + 120);

  // Focus goes to the section, for the next Tab.
  expect(await page.evaluate(() => document.activeElement && document.activeElement.id)).toBe("modals");
  expect(errors).toEqual([]);
});

test("the clicked tab is current for the whole scroll, not each tab it passes", async ({ page }) => {
  await open(page, TURBO);
  await watch(page);
  await clickAndSettle(page, "Tasks", "tasks");
  const { frames } = await seen(page);
  const after = frames.slice(frames.findIndex((f) => f.current === "Tasks"));
  expect(after.length, "the tab became current").toBeGreaterThan(3);
  expect([...new Set(after.map((f) => f.current))], "no other tab in between").toEqual(["Tasks"]);
  await expect(pill(page, "Tasks")).toHaveAttribute("aria-current", "true");

  // After the scroll, the highlight follows the reader's own scroll again.
  await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
  await expect(pill(page, "Theme")).toHaveAttribute("aria-current", "true");
});

test("Back returns to where the reader was, and Forward to the section, with no visit", async ({ page }) => {
  await open(page, TURBO);
  await watch(page);
  await clickAndSettle(page, "Tricks", "tricks");
  const tricks = await page.evaluate(() => window.scrollY);
  await clickAndSettle(page, "Tasks", "tasks");
  const tasks = await page.evaluate(() => window.scrollY);
  expect(tasks).toBeGreaterThan(tricks);

  await page.goBack();
  await page.waitForFunction(() => location.hash === "#tricks");
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => window.scrollY), "Back lands at Tricks").toBeCloseTo(tricks, -1);
  await expect(pill(page, "Tricks"), "the highlight follows Back").toHaveAttribute("aria-current", "true");

  await page.goBack();
  await page.waitForFunction(() => location.hash === "");
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => window.scrollY), "Back again: the top").toBeLessThan(5);

  await page.goForward();
  await page.waitForFunction(() => location.hash === "#tricks");
  await page.waitForTimeout(300);
  expect(Math.abs(await page.evaluate(() => window.scrollY) - tricks), "Forward: Tricks").toBeLessThan(100);

  const result = await seen(page);
  expect(result.visits, "no Turbo restore visit").toBe(0);
  expect(result.fetches).toBe(0);
  expect(result.frames.some((f) => f.transition)).toBe(false);
  expect(result.frames.some((f) => f.loader)).toBe(false);
});

test("a link to another page is still a Turbo visit, and data-turbo=false is the browser's", async ({ page }) => {
  await open(page, TURBO);
  await watch(page);
  await page.evaluate(() => {
    const off = Object.assign(document.createElement("a"), { href: "#tasks", textContent: "native" });
    off.dataset.turbo = "false";
    off.dataset.test = "native";
    const away = Object.assign(document.createElement("a"), { href: "/lab/section_header#x", textContent: "away" });
    away.dataset.test = "away";
    document.querySelector("header").prepend(off, away);
  });

  await page.locator("[data-test=native]").click();
  await page.waitForFunction(() => location.hash === "#tasks");
  let result = await seen(page);
  expect(result.scrolls, "not taken: the browser jumps").toBe(0);
  expect(result.visits).toBe(0);

  const load = page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
  await page.locator("[data-test=away]").click();
  await load;
  result = await page.evaluate(() => ({ path: location.pathname }));
  expect(result.path).toBe("/lab/section_header");
});

test("under reduced motion the tab jumps", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await open(page, TURBO);
  await watch(page);
  await clickAndSettle(page, "Loaders", "loaders");
  const { frames, visits } = await seen(page);
  const ys = frames.map((f) => f.y);
  const end = ys[ys.length - 1];
  expect(ys.filter((y) => y > 20 && y < end - 20), "no frame mid-scroll").toEqual([]);
  expect(visits).toBe(0);
});

test("without Turbo the tab scrolls smoothly too, and Back returns", async ({ page }) => {
  await open(page, PLAIN);
  await watch(page);
  await clickAndSettle(page, "Loaders", "loaders");
  const ys = (await seen(page)).frames.map((f) => f.y);
  const end = ys[ys.length - 1];
  expect(ys.filter((y) => y > 20 && y < end - 20).length, "frames mid-scroll").toBeGreaterThanOrEqual(3);
  await page.goBack();
  await page.waitForFunction(() => location.hash === "");
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeLessThan(5);
});
