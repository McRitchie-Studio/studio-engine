const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests, expectStickyChromeIsLive } = require("./helpers");

// [e2e] THE SECTION HEADER (studio/_section_header, docs/PAGE_HEADER.md). Alex McRitchie,
// 2026-11-05: "the style stays but a 'Modals' fixed header should be directly under, until
// the modals section is scrolled past and the Tricks section is reached." His screenshot
// had the section's own title half cut off under the page row.
//
// Every claim is a box or a computed style, so the response bytes cannot answer one.
//
// CONTROLS, each run against this file with the lab server restarted:
//   - data-pin-section removed from the partial: no bar and no layer. 8 red.
//   - the header not a direct child of its section (a wrapper div): it never sticks. 5 red.
//   - the partial's top off --pin-stack-bottom: the bar chases its own edge. 3 red.
//   - the stuck rule's background removed: 1 red, the bar.
//   - section-target back to --nav-h + 0: the jump lands the title under the row. 1 red.
//   - the glass rule for the row's square corners removed: 1 red, glass.
//   - the short-screen floor removed: 1 red, the short screen.
//   - the sticky gate removed from the CSS: 1 red, the page with no publisher.

const DESKTOP = { width: 1280, height: 800 };
const PHONE = { width: 390, height: 844 };
const LAB = "/lab/section_header";
const STYLE = "/lab/style_chrome";

const TRANSPARENT = "rgba(0, 0, 0, 0)";
const header = (page, id) => page.locator(`#${id} > .section-header`);
const styleRow = (page) => page.locator("nav[aria-label='Style guide sections']");

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

test("the style guide: Style stays, Modals sits directly under it, and Tricks takes its place", async ({ page }) => {
  const errors = watchPageErrors(page);
  for (const viewport of [DESKTOP, PHONE]) {
    await open(page, STYLE, viewport);
    const row = styleRow(page);

    await scrollTo(page, "#modals", -600);
    const modals = header(page, "modals");
    await expect(modals).toHaveAttribute("data-stuck", "");
    await expect(modals).toHaveText("Modals");
    await expectUnder(modals, row);
    await expect(row).toHaveAttribute("data-stuck", "");

    // The last of Modals: still its header.
    const rowBottom = await bottomOf(row);
    await scrollTo(page, "#tricks", rowBottom + 120);
    await expect(modals).toHaveAttribute("data-stuck", "");
    await expect(header(page, "tricks")).not.toHaveAttribute("data-stuck", "");

    // Tricks has reached the line.
    await scrollTo(page, "#tricks", -40);
    const tricks = header(page, "tricks");
    await expect(tricks).toHaveAttribute("data-stuck", "");
    await expect(modals).not.toHaveAttribute("data-stuck", "");
    await expectUnder(tricks, row);
    expect(await page.locator("[data-pin-section][data-stuck]").count()).toBe(1);
    await expect(row.locator("a[aria-current='true']")).toHaveText("Tricks");

    const bleed = await tricks.boundingBox();
    expect(bleed.x, "the bar's bleed stays on the page").toBeGreaterThanOrEqual(0);
    expect(bleed.x + bleed.width, "the bar's bleed stays on the page").toBeLessThanOrEqual(await page.evaluate(() => window.innerWidth));
  }
  expect(errors).toEqual([]);
});

test("a tab's jump lands the section's title on the bar under the row, at both widths", async ({ page }) => {
  for (const viewport of [DESKTOP, PHONE]) {
    await open(page, STYLE, viewport);
    const row = styleRow(page);
    // Modals first: the jump from the top of the page is the one whose line rises after it.
    for (const [label, id] of [["Modals", "modals"], ["Tricks", "tricks"], ["Tasks", "tasks"], ["Components", "components"], ["Theme", "theme"]]) {
      await row.locator("a", { hasText: label }).click();
      await page.waitForFunction((want) => location.hash === `#${want}`, id);
      const bar = header(page, id);
      await expect(row.locator("a[aria-current='true']"), `${label}: the highlight`).toHaveText(label);
      if (id === "components") {
        // The last section is too short to reach the line, so the one above keeps its bar.
        await expect.poll(async () => (await topOf(bar)) >= (await bottomOf(page.locator("[data-pin-section][data-stuck]"))) - 1, `${label}: in view under the bar`).toBe(true);
        expect(await topOf(bar)).toBeLessThan(viewport.height - 40);
        continue;
      }
      await expect(page.locator("[data-pin-section][data-stuck]"), `${label}: only its own bar`).toHaveText(label);
      await expectUnder(bar, row);
    }
  }
});

test("a reader who scrolls back up right after a jump keeps their place", async ({ page }) => {
  await open(page, STYLE, DESKTOP);
  await styleRow(page).locator("a", { hasText: "Modals" }).click();
  await page.mouse.move(400, 500);
  // Up: the section is then below its line, which is what a landing would correct.
  await page.mouse.wheel(0, -300);
  await page.waitForTimeout(800);
  const modalsTop = await page.locator("#modals").evaluate((el) => el.getBoundingClientRect().top);
  const line = await page.evaluate(() => window.studioPinnedStack.read().layers.section.top);
  expect(modalsTop, "not hauled back to the section's top").toBeGreaterThan(line + 100);
});

test("a load with a hash lands the title on the bar too", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.setViewportSize(DESKTOP);
  await page.goto(`${STYLE}#modals`);
  await expect(page.locator("[data-pin-section][data-stuck]")).toHaveText("Modals");
  await expectUnder(header(page, "modals"), styleRow(page));
});

test("a jump to a target inside a section lands below the section's bar", async ({ page }) => {
  await open(page, LAB, DESKTOP);
  await scrollTo(page, "#second", -300);
  await page.evaluate(() => { location.hash = "#inner"; });
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 200))));
  const bar = header(page, "second");
  await expect(bar).toHaveAttribute("data-stuck", "");
  expect(await topOf(page.locator("#inner"))).toBeGreaterThanOrEqual((await bottomOf(bar)) - 1);
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
  const clipped = await bar.locator("h2").evaluate((el) => el.scrollWidth > el.clientWidth);
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
  await page.evaluate(() => document.documentElement.removeAttribute("data-pin-live"));
  expect(await header(page, "second").evaluate((el) => getComputedStyle(el).position)).toBe("relative");
});
