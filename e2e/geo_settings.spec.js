const { test, expect } = require("@playwright/test");

// The geo manager (/admin/geo), driven in a browser.
//
// WHY THIS FILE EXISTS. The page ships an inline program and three CSS mechanisms
// whose response bytes are IDENTICAL whether any of them works: the squares paint
// from their own checkboxes, the summary chips rebuild from the editor, the tabs
// swap panels, and the preview repaints the navbar badge for the visitor's own
// region. Every one of those was shipped once as a server-rendered class instead —
// and the operator's report was "the state buttons don't seem to be working" while
// the database was recording every click. A String assertion cannot tell those two
// pages apart; a computed style can.
//
// Each spec below asserts something only a live browser produces, and each was
// verified RED against its own defect reintroduced (see docs/E2E_LANE.md).

// Two different reds, and they are not interchangeable: a blocked SQUARE gets the
// wash as its background, a blocked BADGE gets the brighter tone as its text.
// (Measured — the first draft asserted the wash against the badge's colour.)
const BLOCKED_WASH = /rgba?\(\s*239,\s*68,\s*68/;
const BLOCKED_TEXT = /rgba?\(\s*248,\s*113,\s*113/;

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/geo_settings");
});

// The click the operator reported as dead. The square paints from its checkbox,
// so it repaints immediately — no save, no reload.
test("a square repaints the moment it is ticked", async ({ page }) => {
  const square = page.locator('.geo-grid-states label:has(input[value="NY"])');
  const background = () => square.evaluate((el) => getComputedStyle(el).backgroundColor);

  const quiet = await background();
  expect(quiet).not.toMatch(BLOCKED_WASH);

  await square.click();
  await expect.poll(background).toMatch(BLOCKED_WASH);

  await square.click();
  await expect.poll(background).toBe(quiet);
});

// A square the server rendered as blocked must go quiet on the way OUT too —
// the direction a server-painted class could never answer.
test("a blocked square goes quiet when it is unticked", async ({ page }) => {
  const square = page.locator('.geo-grid-states label:has(input[value="WA"])');
  const background = () => square.evaluate((el) => getComputedStyle(el).backgroundColor);

  expect(await background()).toMatch(BLOCKED_WASH);
  await square.click();
  await expect.poll(background).not.toMatch(BLOCKED_WASH);
});

// THE PREVIEW. The lab visitor is standing in US-CO; ticking CO must repaint the
// badge that shows where they are, before anything is saved.
test("ticking the visitor's own region repaints the badge", async ({ page }) => {
  const badge = page.locator("[data-geo-badge]").first();
  const color = () => badge.evaluate((el) => getComputedStyle(el).color);
  const square = page.locator('.geo-grid-states label:has(input[value="CO"])');

  const allowed = await color();
  expect(allowed).not.toMatch(BLOCKED_TEXT);

  await square.click();
  await expect.poll(color).toMatch(BLOCKED_TEXT);
  await expect(page.locator("[data-geo-verdict]")).toContainText("YES");

  await square.click();
  await expect.poll(color).toBe(allowed);
  await expect(page.locator("[data-geo-verdict]")).toContainText("NO");
});

// The kill switch is part of the same verdict: with the gate off, nothing is
// blocked, including the region that is on the list.
test("the preview obeys the kill switch", async ({ page }) => {
  const badge = page.locator("[data-geo-badge]").first();
  const color = () => badge.evaluate((el) => getComputedStyle(el).color);

  await page.locator('.geo-grid-states label:has(input[value="CO"])').click();
  await expect.poll(color).toMatch(BLOCKED_TEXT);

  await page.locator('input[name="geo_setting[enabled]"][type="checkbox"]').uncheck();
  await expect.poll(color).not.toMatch(BLOCKED_TEXT);
  await expect(page.locator("[data-geo-verdict]")).toContainText("NO");
});

// The summary card answers "what does this app block?" — and it answers for the
// policy you are about to save, not the one on disk.
test("the summary chips and counts follow the editor", async ({ page }) => {
  const chips = page.locator('[data-geo-summary="states"] .geo-chip');
  const before = await chips.count();

  await page.locator('.geo-grid-states label:has(input[value="NY"])').click();

  await expect(chips).toHaveCount(before + 1);
  await expect(chips.filter({ hasText: "NY" })).toHaveCount(1);
  for (const count of await page.locator('[data-geo-summary-count="states"]').all()) {
    await expect(count).toHaveText(String(before + 1));
  }
});

// Two editors, one space. The tab is a checked radio and the swap is CSS, so it
// works before any script does — but "works" is a computed display, not markup.
test("the tab swaps the two editors", async ({ page }) => {
  const states = page.locator(".geo-grid-states");
  const countries = page.locator(".geo-grid-countries");

  await expect(states).toBeVisible();
  await expect(countries).toBeHidden();

  await page.locator('label[for="geo_tab_countries"]').click();

  await expect(countries).toBeVisible();
  await expect(states).toBeHidden();
});

// A blocked country is the other half of the policy, and it previews the same way
// — the lab visitor is in the US, so blocking the US blocks them.
test("blocking the visitor's country previews too", async ({ page }) => {
  const badge = page.locator("[data-geo-badge]").first();
  const color = () => badge.evaluate((el) => getComputedStyle(el).color);

  await page.locator('label[for="geo_tab_countries"]').click();
  await page.locator('.geo-grid-countries label:has(input[value="US"])').click();

  await expect.poll(color).toMatch(BLOCKED_TEXT);
  await expect(page.locator('[data-geo-summary="countries"] .geo-chip').filter({ hasText: "US" })).toHaveCount(1);
});

// The flags are the page's character, and a 404'd flag is a broken square that
// still reads fine in markup.
test("every state square renders its flag", async ({ page }) => {
  const images = page.locator(".geo-grid-states img");
  await expect(images).toHaveCount(52);

  const broken = await page.evaluate(() =>
    Array.from(document.querySelectorAll(".geo-grid-states img")).filter(
      (img) => !img.complete || img.naturalWidth === 0
    ).length
  );
  expect(broken).toBe(0);
});
