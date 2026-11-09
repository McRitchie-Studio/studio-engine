const { test, expect } = require("@playwright/test");
const {
  watchPageErrors, blockOffsiteRequests, expectStickyChromeIsLive, scrolledTo, navAtRest, stackSettled,
  watchInPageJumps, jumpEnded, traversed, scrollYAcrossWindow, inPageTimerWindow,
} = require("./helpers");

// [e2e] THE SECTION HEADER (studio/_section_header, docs/PAGE_HEADER.md). Alex McRitchie,
// 2026-11-05: "the style stays but a 'Modals' fixed header should be directly under, until
// the modals section is scrolled past and the Tricks section is reached." His screenshot
// had the section's own title half cut off under the page row.
//
// Every claim is a box or a computed style, so the response bytes cannot answer one.
//
// CONTROLS, each run against this file with the lab server restarted:
//   - data-pin-section removed from the partial: no bar and no layer. 10 red.
//   - the header wrapped in a div: it never sticks. 12 red.
//   - the partial's top off --pin-stack-bottom: the bar chases its own edge. 5 red.
//   - the stuck rule's fill removed: 1 red, the bar at rest and stuck.
//   - section-target on the old --pin-section-top, or on --nav-h + 5rem: 2 red, the tab's
//     jump with and without Turbo, on the highlight or the bar above.
//   - section-target on --nav-h alone, too high: 2 red, the same, on the section's top.
//   - the glass rule for the row's square corners removed: 1 red, glass.
//   - the short-screen floor removed: 1 red, the short screen.
//   - the sticky gate removed from the CSS: 1 red, the page with no publisher.
// The extra frame after a top moved and the read after a settle are controlled in
// test/javascript/pinned_stack.test.mjs. Hub and Turf were checked by hand on this engine:
// the lab's Turbo layout stops 30px short of the page's end, so the short last section
// is left out of TABS here.
//
// THE WAITS READ REAL CONDITIONS (engine-anchor-scroll-waits): a tab's landing is the in-page
// module's end event (jumpEnded) and the navbar at rest; a scroll to the top is the scroll
// event heard at 0; Back is the place restored two frames after its popstate (traversed),
// which holds when Back does not move. Two checks stay negative proofs, each over every frame
// of the module's own timer window (twice START_CAP_MS): nothing moves after Back, and the
// reader's scroll right after a jump holds. Controls, each red under the new spec: the end
// event never sent, red 3/3; Back's restore smooth or removed, red; a late aim 300ms after
// the end, red 2/2; the stuck bar never set, red (inner target); no tab highlighted, red
// (load with a hash).

const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };
const LAB = "/lab/section_header";
const STYLE = "/lab/style_chrome";

const TRANSPARENT = "rgba(0, 0, 0, 0)";
const header = (page, id) => page.locator(`#${id} > .section-header`);
const styleRow = (page) => page.locator(".page-header:has(> nav[aria-label='Style guide sections'])");

async function open(page, url, viewport) {
  await blockOffsiteRequests(page);
  await page.setViewportSize(viewport);
  await page.goto(url);
  await expectStickyChromeIsLive(page, expect);
}

// Scrolls so the element's top is `offset` below the window's top, then waits two frames.
const scrollTo = (page, selector, offset) => page.evaluate(async ({ selector, offset }) => {
  const top = document.querySelector(selector).getBoundingClientRect().top;
  window.scrollBy({ top: top - offset, behavior: "instant" });
  for (let i = 0; i < 2; i++) await new Promise((resolve) => requestAnimationFrame(resolve));
  await new Promise((resolve) => setTimeout(resolve, 0));
}, { selector, offset });

const bottomOf = (locator) => locator.evaluate((el) => el.getBoundingClientRect().bottom);
const topOf = (locator) => locator.evaluate((el) => el.getBoundingClientRect().top);
const stack = (page) => page.evaluate(() => window.studioPinnedStack.read());
// Polled: the navbar's collapse takes a moment to settle after a jump.
const expectUnder = (lower, upper) => expect.poll(async () => Math.abs((await topOf(lower)) - (await bottomOf(upper)))).toBeLessThanOrEqual(1);

test("the style guide: Style stays, Tricks sits directly under it, and Loaders takes its place", async ({ page }) => {
  const errors = watchPageErrors(page);
  for (const viewport of [DESKTOP, PHONE]) {
    await open(page, STYLE, viewport);
    const row = styleRow(page);

    await scrollTo(page, "#tricks", -600);
    const tricks = header(page, "tricks");
    await expect(tricks).toHaveAttribute("data-stuck", "");
    await expect(tricks).toHaveText("Tricks");
    await expectUnder(tricks, row);
    await expect(row).toHaveAttribute("data-stuck", "");

    // The last of Tricks: still its header.
    const rowBottom = await bottomOf(row);
    await scrollTo(page, "#loaders", rowBottom + 120);
    await expect(tricks).toHaveAttribute("data-stuck", "");
    await expect(header(page, "loaders")).not.toHaveAttribute("data-stuck", "");

    // Loaders has reached the line.
    await scrollTo(page, "#loaders", -40);
    const loaders = header(page, "loaders");
    await expect(loaders).toHaveAttribute("data-stuck", "");
    await expect(tricks).not.toHaveAttribute("data-stuck", "");
    await expectUnder(loaders, row);
    expect(await page.locator("[data-pin-section][data-stuck]").count()).toBe(1);
    await expect(row.locator("a[aria-current='true']")).toHaveText("Loaders");

    const bleed = await loaders.boundingBox();
    expect(bleed.x, "the bar's bleed stays on the page").toBeGreaterThanOrEqual(0);
    expect(bleed.x + bleed.width, "the bar's bleed stays on the page").toBeLessThanOrEqual(await page.evaluate(() => window.innerWidth));
  }
  expect(errors).toEqual([]);
});

// A jump goes by the stack once pinned. At the top of the page the navbar is still tall, so
// the first jump lands by the navbar's collapse below the line, in the gap above the section.
// Later jumps land on the line, with the title on the section's own bar.
async function expectLanded(page, row, label, id, viewport, exact) {
  const bar = header(page, id);
  await expect(row.locator("a[aria-current='true']"), `${label}: the highlight`).toHaveText(label);
  const title = await topOf(bar);
  await expect.poll(async () => (await topOf(bar)) >= (await bottomOf(row)) - 1, `${label}: the title is below the row`).toBe(true);
  expect(title, `${label}: the title is on the screen`).toBeLessThan(viewport.height - 40);
  // Whatever bar is up is this section's, or none: never the section above, cut by its end.
  const stuck = page.locator("[data-pin-section][data-stuck]");
  if (exact) await expect(stuck, `${label}: its own bar`).toHaveText(label);
  else if (await stuck.count()) await expect(stuck, `${label}: no other section's bar`).toHaveText(label);
  if (exact) {
    await expectUnder(bar, row);
    await expect.poll(async () => Math.abs((await topOf(page.locator(`#${id}`))) - (await bottomOf(row))), `${label}: the section's top`).toBeLessThanOrEqual(3);
  }
}

// The Loaders section's feed lives at /admin/style/loaders_feed, which a host serves to its
// admins. The dummy gates that route, so it is answered from the lab's own feed. A smooth tab
// scroll passes the section, and its next page loads as on a reader's own scroll.
const serveFeed = (page) => page.route("**/admin/style/loaders_feed*", async (route) => {
  const url = new URL(route.request().url());
  await route.fulfill({ response: await route.fetch({ url: `${url.origin}/lab/loaders_feed${url.search}` }) });
});

// A tab's click is a smooth scroll (studio/in_page_links). It has landed when the module's
// jump ended (its scrollend after the last aim; jumpEnded), the navbar's collapse that the
// scroll drove is at rest, and the pinned stack has written its settled values to the root
// (stackSettled), which the section bars' sticky line reads. `count` is the jumps since the
// page loaded.
async function landed(page, count) {
  await jumpEnded(page, count);
  await navAtRest(page);
  await stackSettled(page);
}

// A feed fetch the scroll started can still be in flight when a test ends; its route
// handler then fails on "Test ended". Waiting for every handler to finish closes that.
test.afterEach(async ({ page }) => { await page.unrouteAll({ behavior: "wait" }); });

const TABS = [["Modals", "modals"], ["Tricks", "tricks"], ["Tasks", "tasks"], ["Theme", "theme"]];

// Each check runs without Turbo and under it. Declared bare, twice: the lane's census counts
// test( in the source, so a loop around test() would not match what runs.
async function tabJump(page, url) {
  const errors = watchPageErrors(page);
  await watchInPageJumps(page);
  for (const viewport of [DESKTOP, PHONE]) {
    await blockOffsiteRequests(page);
    await serveFeed(page);
    await page.setViewportSize(viewport);
    await page.goto(url);
    await page.waitForFunction(() => document.documentElement.hasAttribute("data-pin-live"));
    const row = styleRow(page);
    for (const [index, [label, id]] of TABS.entries()) {
      await row.locator("a", { hasText: label }).click();
      await page.waitForFunction((want) => location.hash === `#${want}`, id);
      await landed(page, index + 1);
      await expectLanded(page, row, label, id, viewport, index > 0);
    }
  }
  expect(errors).toEqual([]);
}
async function backKeepsPlace(page, url) {
  await blockOffsiteRequests(page);
  await watchInPageJumps(page);
  await page.setViewportSize(PHONE);
  await page.goto(url);
  await page.waitForFunction(() => document.documentElement.hasAttribute("data-pin-live"));
  const row = styleRow(page);
  // Tricks comes before Modals, so the second jump lands further down.
  await row.locator("a", { hasText: "Tricks" }).click();
  await page.waitForFunction(() => location.hash === "#tricks");
  await landed(page, 1);
  await scrolledTo(page, 0);
  await navAtRest(page);
  await row.locator("a", { hasText: "Modals" }).click();
  await page.waitForFunction(() => location.hash === "#modals");
  await landed(page, 2);
  const before = await page.evaluate(() => window.scrollY);
  // The place Back restored, read two frames after its popstate: Back may not move the page,
  // and then no scrollend comes.
  const held = await traversed(page, () => page.goBack());
  expect(await page.evaluate(() => location.hash)).toBe("#tricks");
  expect(held, "Back left the jump's place").toBeLessThan(before);
  // Back starts no jump, so none is left to end. What stays is a negative proof: every frame
  // of the module's own timer window reads the same place.
  await jumpEnded(page, 2);
  await navAtRest(page);
  expect(new Set(await scrollYAcrossWindow(page, inPageTimerWindow())), "nothing moves the page after Back settles").toEqual(new Set([held]));
}
async function scrollHolds(page, url) {
  await blockOffsiteRequests(page);
  await watchInPageJumps(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(url);
  await page.waitForFunction(() => document.documentElement.hasAttribute("data-pin-live"));
  await styleRow(page).locator("a", { hasText: "Modals" }).click();
  await page.waitForFunction(() => location.hash === "#modals");
  // Right after the jump's end: its scrollend after the last aim.
  await jumpEnded(page, 1);
  await page.evaluate(() => window.scrollBy({ top: -300, behavior: "instant" }));
  const held = await page.evaluate(() => window.scrollY);
  // A negative proof: nothing fires for a move that does not happen, so every frame of the
  // module's own timer window must read the reader's place.
  expect(new Set(await scrollYAcrossWindow(page, inPageTimerWindow())), "the reader's scroll holds").toEqual(new Set([held]));
}
test("a tab's jump shows the section's title under the row, on the right bar and tab, without Turbo", async ({ page }) => tabJump(page, STYLE));
test("a tab's jump shows the section's title under the row, on the right bar and tab, under Turbo", async ({ page }) => tabJump(page, `${STYLE}?turbo=1`));
test("Back keeps the reader's place after two jumps, without Turbo", async ({ page }) => backKeepsPlace(page, STYLE));
test("Back keeps the reader's place after two jumps, under Turbo", async ({ page }) => backKeepsPlace(page, `${STYLE}?turbo=1`));
test("a scroll right after a jump is the reader's or the app's, and holds, without Turbo", async ({ page }) => scrollHolds(page, STYLE));
test("a scroll right after a jump is the reader's or the app's, and holds, under Turbo", async ({ page }) => scrollHolds(page, `${STYLE}?turbo=1`));

test("a load with a hash shows the title, with no error on a hash that cannot be decoded", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(`${STYLE}#modals`);
  // The browser jumps to #modals as the page loads; the stack and the highlight read it once
  // the chrome is live. Both checks below are polled.
  await expectStickyChromeIsLive(page, expect);
  await page.waitForFunction(() => document.documentElement.hasAttribute("data-pin-live"));
  const row = styleRow(page);
  await expect(row.locator("a[aria-current='true']")).toHaveText("Modals");
  await expect.poll(async () => (await topOf(header(page, "modals"))) >= (await bottomOf(row)) - 1).toBe(true);

  await page.goto(`${LAB}#100%`);
  await page.waitForFunction(() => document.documentElement.hasAttribute("data-pin-live"));
  await expect(page.locator("header[data-nav-timeline-on], header")).toHaveCount(1);
  expect(errors).toEqual([]);
});

test("a jump to a target inside a section lands below the section's bar", async ({ page }) => {
  await open(page, LAB, DESKTOP);
  await scrollTo(page, "#second", -300);
  // The browser's jump to the fragment runs in the hash change's own navigation, ahead of
  // its hashchange event. Then the navbar's collapse comes to rest, and the bar is read.
  await page.evaluate(() => new Promise((resolve) => {
    window.addEventListener("hashchange", resolve, { once: true });
    location.hash = "#inner";
  }));
  await navAtRest(page);
  const bar = header(page, "second");
  await expect(bar).toHaveAttribute("data-stuck", "");
  await expect.poll(async () => (await topOf(page.locator("#inner"))) - (await bottomOf(bar))).toBeGreaterThanOrEqual(-1);
});

test("at rest a plain title; stuck a bar in light and dark, its box unchanged", async ({ page }) => {
  await open(page, LAB, DESKTOP);
  const bar = header(page, "second");

  await scrollTo(page, "#second", 500);
  const rest = await bar.boundingBox();
  await expect(bar).not.toHaveAttribute("data-stuck", "");
  await expect.poll(() => bar.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe(TRANSPARENT);

  await scrollTo(page, "#second", -200);
  await expect(bar).toHaveAttribute("data-stuck", "");
  for (const dark of [false, true]) {
    await page.evaluate((on) => document.documentElement.classList.toggle("dark", on), dark);
    await expect.poll(() => bar.evaluate((el) => {
      const s = getComputedStyle(el);
      return s.backgroundColor === getComputedStyle(document.querySelector(".page-header")).backgroundColor && s.borderBottomColor !== "rgba(0, 0, 0, 0)";
    })).toBe(true);
    const fill = await bar.evaluate((el) => getComputedStyle(el).backgroundColor);
    expect(fill).not.toBe(TRANSPARENT);
    expect(fill, "solid: content does not show through").not.toMatch(/rgba\(.*, 0(\.\d+)?\)/);
  }
  const stuck = await bar.boundingBox();
  expect(stuck.height).toBe(rest.height);
  expect(stuck.width).toBe(rest.width);
});

test("under glass the bar blurs, and the row above it goes square until it leaves", async ({ page }) => {
  await open(page, LAB, DESKTOP);
  await page.evaluate(() => { document.documentElement.dataset.surfaceStyle = "glass"; });
  const row = page.locator(".page-header");
  const bar = header(page, "second");

  await scrollTo(page, "#first", -200);
  await scrollTo(page, "#second", -200);
  await expect(bar).toHaveAttribute("data-stuck", "");
  await expect.poll(() => bar.evaluate((el) => getComputedStyle(el).backdropFilter)).toContain("blur");
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).borderBottomLeftRadius)).toBe("0px");
  await expect.poll(() => bar.evaluate((el) => getComputedStyle(el).borderBottomLeftRadius)).not.toBe("0px");

  // Back in the gap above a section: no bar, and the row has its corners back.
  await page.evaluate(() => {
    const top = document.getElementById("second").getBoundingClientRect().top;
    const rowBottom = document.querySelector(".page-header").getBoundingClientRect().bottom;
    window.scrollBy({ top: top - rowBottom - 30, behavior: "instant" });
  });
  await expect(page.locator("[data-pin-section][data-stuck]")).toHaveCount(0);
  await expect.poll(() => row.evaluate((el) => getComputedStyle(el).borderBottomLeftRadius)).not.toBe("0px");
});

test("a table's sticky header sits under the stuck bar, and the stack's bottom is the bar's", async ({ page }) => {
  for (const url of [LAB, `${LAB}?timeline=1`]) {
    await open(page, url, DESKTOP);
    const bar = header(page, "second");
    await scrollTo(page, "[data-test='lab-table']", -400);
    await expect(bar).toHaveAttribute("data-stuck", "");

    await expect.poll(async () => Math.abs((await stack(page)).bottom - (await bottomOf(bar))), `${url}: the stack`).toBeLessThanOrEqual(1);
    const clone = page.locator(".sticky-table-header-clone");
    await expect(clone).toBeVisible();
    await expect.poll(async () => Math.abs((await topOf(clone)) - (await bottomOf(bar))), `${url}: the clone`).toBeLessThanOrEqual(1);

    // Pushed out at the section's end, the bar gives its room back.
    await page.evaluate(() => window.scrollTo({ top: 0, behavior: "instant" }));
    await expect(page.locator("[data-pin-section][data-stuck]")).toHaveCount(0);
  }
});

test("headers below the fold do not move the stack, and only one is stuck at a time", async ({ page }) => {
  await open(page, LAB, DESKTOP);
  const atTop = await stack(page);
  expect(atTop.layers.section.h).toBe(0);
  expect(atTop.bottom).toBeLessThan(400);

  await page.evaluate(() => window.scrollTo({ top: 5000, behavior: "instant" }));
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 200))));
  expect(await page.locator("[data-pin-section][data-stuck]").count()).toBe(1);
  await expect.poll(() => page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--pin-section-h"))).not.toBe("0px");
});

test("a long title stays on one line, and the phone's stack leaves the page its room", async ({ page }) => {
  await open(page, LAB, PHONE);
  const bar = header(page, "second");
  await scrollTo(page, "#second", -200);
  await expect(bar).toHaveAttribute("data-stuck", "");
  const box = await bar.boundingBox();
  expect(box.height).toBeLessThanOrEqual(37);
  const clipped = await bar.evaluate((el) => el.scrollWidth > el.clientWidth);
  expect(clipped, "the title ends in an ellipsis").toBe(true);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  expect((await bottomOf(bar)) / PHONE.height, "the stack takes under a quarter of a phone").toBeLessThan(0.25);
});

test("a short screen keeps the header in the flow", async ({ page }) => {
  await open(page, LAB, { width: 844, height: 390 });
  const bar = header(page, "second");
  await scrollTo(page, "#second", -200);
  expect(await bar.evaluate((el) => getComputedStyle(el).position)).toBe("relative");
  await expect(bar).not.toHaveAttribute("data-stuck", "");
  expect((await stack(page)).layers.section.h).toBe(0);
});

test("with no publisher the header stays a plain title in the flow", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(LAB);
  await expectStickyChromeIsLive(page, expect);
  // Removed and read in one task: the publisher sets data-pin-live again on its next
  // publish, so a read a round trip later could see the attribute back (red 1 in 160).
  const position = await header(page, "second").evaluate((el) => {
    document.documentElement.removeAttribute("data-pin-live");
    return getComputedStyle(el).position;
  });
  expect(position).toBe("relative");
});
