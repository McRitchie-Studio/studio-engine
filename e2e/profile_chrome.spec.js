const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The two browser programs /profile and /profile/edit add.
//
// WHY THEY NEED A BROWSER, stated as the property rather than as a preference:
// for BOTH of these the server emits the SAME BYTES whether the program works or
// not. The compact header is in the document on every render; the save bar is in
// the document on every render. Each is hidden by a mechanism no String assertion
// can observe — an IntersectionObserver callback toggling a class, and Alpine's
// x-show setting display from a computed getter. A markup test asserting
// `x-show="dirty"` is green on a page where Alpine threw on init and neither bar
// will ever move again.
//
// That is the exact shape of the defect this lane was built after: a guard test
// that passed on a broken page because it asserted a token in the markup rather
// than the program running.
//
// Both are driven on ONE page (/lab/profile) because that is how a consumer ships
// them — the mini bar fixed at the top, the save bar fixed at the bottom, live at
// the same time on /profile/edit.
//
// NAMED GAP: the lab page renders the READ identity header, so it carries ONE form.
// The real /profile/edit carries two — the avatar uploader (an imageUploadHost
// component) nested inside studioProfileForm, and BOTH declare x-ref="form". If the
// outer component's $refs.form resolved to the inner one, its submit-teardown would
// never fire and saving would prompt the author about the very changes they had just
// chosen to save. That was checked in this browser rather than reasoned about: an
// inner component's x-ref does NOT reach an ancestor's $refs (Alpine collects refs
// per component root, and $refs walks UP), so the outer resolves to its own form.
// Left as a note rather than a spec because the property belongs to Alpine, not to
// this engine — if that ever changes it changes for every component here, not only
// this page.

const FULL = "[data-studio-identity-full]";
const MINI = "[data-studio-identity-mini]";
const SAVE_BAR = "[data-studio-save-bar]";
const FIRST_NAME = 'input[name="profile[first_name]"]';

// ALPINE HAVING BOOTED IS A PRECONDITION FOR EVERY NEGATIVE BELOW, and it needs a
// receipt rather than an assumption. `toHaveValue("Pat")` proves only that the
// SERVER rendered the field — it is equally true on a page where Alpine threw on
// init, and on that page every `toBeHidden()` below passes for the wrong reason.
//
// Alpine strips the x-cloak attribute as it initialises an element, so its ABSENCE
// is the one signal in the DOM that means "this component is live".
async function expectAlpineBooted(page, expect) {
  await expect(
    page.locator(SAVE_BAR),
    "Alpine never initialised the save bar — every hidden-state assertion below would " +
      "pass vacuously on this page"
  ).not.toHaveAttribute("x-cloak", /.*/);
}

// The mini bar animates opacity, so "showing" is a COMPUTED value and not a class
// name. Asserting the class would re-assert the source: `classList.toggle` is what
// the script does, and a spec that checks the class checks that toggle ran, not
// that anything became visible. Opacity is the effect a reader gets.
async function miniOpacity(page) {
  return await page.evaluate((selector) => {
    const el = document.querySelector(selector);
    return el ? window.getComputedStyle(el).opacity : null;
  }, MINI);
}

// DELIBERATELY ABSENT: "the compact header stays down while the card is on screen".
// It was written, and the mutation run showed it could pass without meaning anything.
// The page STARTS with the bar at opacity 0, so polling for 0 is satisfied by the
// initial CSS before the observer's first callback has run — under a mutation that
// pins the bar permanently visible it failed only half the time, winning the race
// the other half. "Hands back when the card returns" below makes the same claim as a
// TRANSITION, which cannot pass vacuously, so the weak one was deleted rather than
// kept. Same reasoning as the dirty-check normalisation spec in config/e2e_lane.yml.

test("the compact header takes over once the card has mostly scrolled past", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");
  await expect(page.locator(FULL)).toBeVisible();

  await page.evaluate(() => window.scrollTo(0, 1200));

  // toBeVisible() would NOT catch this: the bar is in the layout with opacity 0
  // and pointer-events none, which Playwright still counts as visible because it
  // has a non-empty bounding box. The computed opacity is the claim.
  await expect
    .poll(() => miniOpacity(page), {
      message:
        "the compact header never appeared. Either the IntersectionObserver never " +
        "wired (the script did not run) or its ratio test never crossed.",
    })
    .toBe("1");

  // It must be pinned to the viewport, not scrolled away with the card it replaced
  // — `fixed`, deliberately, so it reserves no height while hidden.
  const box = await page.locator(MINI).boundingBox();
  expect(box.y, "the compact header scrolled away with the page — it is not fixed").toBeLessThan(200);

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("the compact header hands back when the card returns", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");
  await page.evaluate(() => window.scrollTo(0, 1200));
  await expect.poll(() => miniOpacity(page)).toBe("1");

  await page.evaluate(() => window.scrollTo(0, 0));

  // The handover is symmetric or it is a one-way trapdoor: a reader who scrolls
  // back up would be left with two headers stacked on each other.
  await expect
    .poll(() => miniOpacity(page), {
      message: "the compact header stayed up after the full card came back — two headers at once",
    })
    .toBe("0");
});

test("the compact header matches the card's width rather than the viewport's", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");

  const card = await page.locator(FULL).boundingBox();
  await page.evaluate(() => window.scrollTo(0, 1200));
  await expect.poll(() => miniOpacity(page)).toBe("1");
  const mini = await page.locator(MINI).boundingBox();

  // Operator's call, and a geometric relationship between two laid-out boxes —
  // which is the one thing markup can never answer. `width: min(42rem, ...)` in
  // the stylesheet is the source; this is whether it actually resolved to the
  // card's width on a real viewport.
  expect(Math.abs(mini.width - card.width)).toBeLessThan(2);
});

test("the save bar stays down until something actually changes", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await expectAlpineBooted(page, expect);

  await expect(page.locator(SAVE_BAR)).toBeHidden();

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("the save bar rises on an edit and counts it", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");

  await page.locator(FIRST_NAME).fill("Patricia");

  await expect(page.locator(SAVE_BAR)).toBeVisible();
  await expect(page.locator(SAVE_BAR)).toContainText("1 unsaved change");

  // Fixed to the BOTTOM of the viewport — the whole point of the design is that it
  // does not depend on where the reader is in the scroll.
  const bar = await page.locator(SAVE_BAR).boundingBox();
  const viewport = page.viewportSize();
  expect(Math.abs(bar.y + bar.height - viewport.height)).toBeLessThan(2);
});

test("the save bar follows the reader down the page", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_BAR)).toBeVisible();

  await page.evaluate(() => window.scrollTo(0, 1500));

  // THE FEATURE, in one assertion. The operator's requirement was a save control
  // "not dependent on where you are in the scroll context", and the only tier that
  // can answer that is one with a scroll position.
  const bar = await page.locator(SAVE_BAR).boundingBox();
  const viewport = page.viewportSize();
  expect(
    Math.abs(bar.y + bar.height - viewport.height),
    "the save bar scrolled off with the page — it is not reachable from the bottom of a long form"
  ).toBeLessThan(2);
});

test("whitespace is not a change", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await expectAlpineBooted(page, expect);

  // DIRTY IT FIRST, ON PURPOSE. Asserting `toBeHidden()` straight after typing is a
  // RACE that always passes: the bar starts hidden, Playwright polls, and the first
  // poll lands before Alpine has reacted — so the assertion is satisfied by the
  // state the page was already in. Verified: with the trim removed from changed(),
  // that version of this spec stayed GREEN.
  //
  // Raising the bar first turns the claim into a TRANSITION — hidden again, from
  // visible — which no amount of polling can satisfy vacuously.
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_BAR)).toBeVisible();

  // The dirty check trims both sides because the controller trims on the way in, so
  // the bar agrees with what saving would actually do. Offering to save a change
  // that would be a no-op teaches the reader the bar is noise.
  await page.locator(FIRST_NAME).fill("  Pat  ");

  await expect(
    page.locator(SAVE_BAR),
    "padding a value with spaces kept the save bar up, but saving it would change nothing"
  ).toBeHidden();
});

test("discarding puts the bar back down and the fields back", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await expectAlpineBooted(page, expect);

  // Visible first, so the toBeHidden() below is a transition rather than a poll that
  // wins the race against Alpine.
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_BAR)).toBeVisible();

  await page.locator(SAVE_BAR).getByRole("button", { name: "Discard" }).click();

  await expect(page.locator(SAVE_BAR)).toBeHidden();
  await expect(
    page.locator(FIRST_NAME),
    "Discard lowered the bar without restoring the field — the edit is still there, unsaved and unannounced"
  ).toHaveValue("Pat");
});
