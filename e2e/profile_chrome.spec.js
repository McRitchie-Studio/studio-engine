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
const SAVE_CONTROLS_CARD = '[data-studio-save-controls="card"]';
const SAVE_CONTROLS_COMPACT = '[data-studio-save-controls="compact"]';
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
    page.locator(SAVE_CONTROLS_CARD),
    "Alpine never initialised the save controls — every hidden-state assertion below would " +
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

// --- the save controls ---------------------------------------------------------
//
// THEY MOVED, AND SO DID THESE SPECS (operator's call, 2026-08-15). The controls
// used to be a bar fixed across the bottom of the viewport, and two of the specs
// below asserted exactly that: `bar.y + bar.height === viewport.height`. That is
// no longer the design — they now live in the identity chrome, floating in the
// full card's south-east corner and riding the compact bar once the card has
// scrolled away.
//
// THE REQUIREMENT SURVIVED THE REDESIGN, which is why the specs were rewritten
// rather than deleted: a save control "not dependent on where you are in the
// scroll context". The old design met it by pinning to the viewport bottom; the
// new one meets it by riding a bar that is itself fixed under the nav. The
// assertion changes from "at the bottom edge" to "still on screen", which is the
// requirement stated directly instead of through one implementation of it.
//
// They also moved PAGE: /lab/profile renders the read identity, which is not
// editable and now carries no controls at all. /lab/profile_edit is where the
// editable card lives.

test("the save controls stay down until something actually changes", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await expectAlpineBooted(page, expect);

  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeHidden();

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("the save controls rise on an edit and count it", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");

  await page.locator(FIRST_NAME).fill("Patricia");

  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();
  await expect(page.locator(SAVE_CONTROLS_CARD)).toContainText("1 unsaved change");
});

// THE SOUTH-EAST CORNER, measured rather than described. The controls are
// absolutely positioned inside the card, and "absolutely positioned" is a claim
// about markup — whether they actually land in the card's bottom-right corner is
// a fact about two boxes, which only a browser has.
test("the controls sit in the card's south-east corner", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  const card = await page.locator(FULL).boundingBox();
  const controls = await page.locator(SAVE_CONTROLS_CARD).boundingBox();

  // MEASURED FROM THE CORNER THEY ARE ANCHORED TO, which is the south-east one:
  // the gap to the card's RIGHT edge and to its BOTTOM edge. Those two are what
  // `right: 1.5rem; bottom: 1.5rem` actually claims, and both stay true however
  // wide the controls get or however the name wraps.
  //
  // The first version of this asserted the controls' LEFT edge was past the
  // card's midpoint — a proxy for "on the right" that failed honestly: the
  // controls are ~300px wide in a ~672px card, so their left edge lands 4px
  // LEFT of centre while their right edge is flush with the card's. The proxy
  // was wrong about a layout that was right.
  const PAD = 24; // 1.5rem, the card's own p-6

  expect(
    Math.abs(card.x + card.width - (controls.x + controls.width) - PAD),
    "the controls are not tucked against the card's right edge"
  ).toBeLessThan(2);

  expect(
    Math.abs(card.y + card.height - (controls.y + controls.height) - PAD),
    "the controls are not tucked against the card's bottom edge"
  ).toBeLessThan(2);

  // And below the middle of the card, so "south" is not satisfied by a card that
  // happens to be short.
  expect(controls.y, "the controls are not in the card's bottom half")
    .toBeGreaterThan(card.y + card.height / 2);
});

// A DIRTY FORM MUST NOT RESIZE THE CARD. The controls are absolute so the card
// keeps its height when they appear — otherwise the first keystroke shoves every
// row below it down the page, under the reader's cursor.
test("the card does not change height when the controls appear", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  const before = await page.locator(FULL).boundingBox();

  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  const after = await page.locator(FULL).boundingBox();
  expect(
    Math.abs(after.height - before.height),
    "the card grew to fit the controls — every row below it just jumped"
  ).toBeLessThan(2);
});

// THE REQUIREMENT, RESTATED FOR THE NEW DESIGN: reachable wherever you are in a
// long form. The card scrolls away, and the compact bar — fixed under the nav —
// takes the controls with it.
test("the save controls follow the reader down the page", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  await page.evaluate(() => window.scrollTo(0, 1500));
  await expect(page.locator(MINI)).toHaveClass(/is-visible/);

  const controls = await page.locator(SAVE_CONTROLS_COMPACT).boundingBox();
  const viewport = page.viewportSize();

  expect(
    controls,
    "no save control is on screen after scrolling — a long form has no reachable Save"
  ).not.toBeNull();
  expect(controls.y).toBeGreaterThanOrEqual(0);
  expect(
    controls.y + controls.height,
    "the save controls scrolled off with the page — they are not reachable from a long form"
  ).toBeLessThanOrEqual(viewport.height);
});

// REACHABLE MEANS CLICKABLE, and measuring a bounding box does not prove it.
// The spec above finds the compact controls on screen after a scroll, and that
// stayed GREEN against the compact bar keeping `pointer-events: none` — the bar
// carries it so an invisible strip cannot swallow clicks meant for the page
// under it, which was harmless for as long as it held nothing but a picture and
// a name. With Save and Discard in it, the buttons are visible, focusable, and
// completely dead to the mouse, and nothing but an actual click notices.
test("the compact controls can actually be used after scrolling", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  await page.evaluate(() => window.scrollTo(0, 1500));
  await expect(page.locator(MINI)).toHaveClass(/is-visible/);

  // A real click, with the default timeout — Playwright waits for the element to
  // be able to RECEIVE the event, so a pointer-events: none bar fails here and
  // nowhere else.
  await page
    .locator(SAVE_CONTROLS_COMPACT)
    .getByRole("button", { name: "Discard" })
    .click();

  await expect(
    page.locator(FIRST_NAME),
    "the compact bar's Discard did nothing — the controls are on screen but not usable"
  ).toHaveValue("Pat");
  await expect(page.locator(SAVE_CONTROLS_COMPACT)).toBeHidden();
});

test("whitespace is not a change", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await expectAlpineBooted(page, expect);

  // DIRTY IT FIRST, ON PURPOSE. Asserting `toBeHidden()` straight after typing is a
  // RACE that always passes: the controls start hidden, Playwright polls, and the
  // first poll lands before Alpine has reacted — so the assertion is satisfied by
  // the state the page was already in. Verified: with the trim removed from
  // changed(), that version of this spec stayed GREEN.
  //
  // Raising them first turns the claim into a TRANSITION — hidden again, from
  // visible — which no amount of polling can satisfy vacuously.
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  // The dirty check trims both sides because the controller trims on the way in, so
  // the controls agree with what saving would actually do. Offering to save a change
  // that would be a no-op teaches the reader they are noise.
  await page.locator(FIRST_NAME).fill("  Pat  ");

  await expect(
    page.locator(SAVE_CONTROLS_CARD),
    "padding a value with spaces kept the save controls up, but saving it would change nothing"
  ).toBeHidden();
});

test("discarding puts the controls away and the fields back", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  await expectAlpineBooted(page, expect);

  // Visible first, so the toBeHidden() below is a transition rather than a poll that
  // wins the race against Alpine.
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  await page.locator(SAVE_CONTROLS_CARD).getByRole("button", { name: "Discard" }).click();

  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeHidden();
  await expect(
    page.locator(FIRST_NAME),
    "Discard put the controls away without restoring the field — the edit is still there, unsaved and unannounced"
  ).toHaveValue("Pat");
});

// DISCARD MUST NOT OPEN THE FILE PICKER. The whole editable card is a click
// target for the photo picker, so a control inside it that lets its click bubble
// opens a file dialog on the way to doing its own job. Both buttons stop
// propagation; this is the half that can be observed without a native dialog.
test("clicking Discard inside the card does not open the picker", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  await page.evaluate(() => {
    window.__picks = 0;
    const picker = document.querySelector('input[type="file"]:not([name])');
    picker.addEventListener("click", (e) => { window.__picks += 1; e.preventDefault(); });
  });

  await page.locator(SAVE_CONTROLS_CARD).getByRole("button", { name: "Discard" }).click();

  expect(
    await page.evaluate(() => window.__picks),
    "Discard bubbled to the card and opened the photo picker"
  ).toBe(0);
});
