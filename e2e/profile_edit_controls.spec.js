const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The edit page's two browser-only controls (operator's call, 2026-08-15).
//
// WHY A BROWSER, as a property rather than a preference: for both of these the
// server emits the same bytes whether the program works or not.
//
//   · The "Change photo" label is in the document on every render. Whether it is
//     ever VISIBLE is a computed opacity set by a CSS hover rule, and whether
//     clicking it reaches the file picker is an event that only fires in a
//     browser.
//   · The birthday's day list has to FOLLOW the month — 30 in April, 29 in a leap
//     February — and clear a day the new month does not have. That is date
//     arithmetic running in a browser; the markup is identical whether it is
//     right or wrong.
//
// The calendar popover this file used to test is GONE, replaced by the engine's
// shared three-select date field (the same one the age-verify modal uses). Six
// specs went with it — all of them about positioning, and all of them written
// because a previous version of that positioning had shipped broken.

const CARD = "[data-studio-identity-full]";
const TRIGGER = "button.studio-avatar-trigger";
const OVERLAY = ".studio-avatar-overlay";
const HIDDEN_BIRTHDAY = 'input[type="hidden"][name="profile[birthday]"]';
const SAVE_BAR = "[data-studio-save-bar]";

async function overlayOpacity(page) {
  return await page.evaluate((sel) => {
    const el = document.querySelector(sel);
    return el ? window.getComputedStyle(el).opacity : null;
  }, OVERLAY);
}

// --- the avatar overlay -------------------------------------------------------

test("the avatar rests as a plain picture", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(TRIGGER)).toBeVisible();

  // The badge the operator removed must not have come back. Asserted here rather
  // than only in the view suite because a stray CSS rule could also reveal it.
  await expect(page.locator(".studio-avatar-badge")).toHaveCount(0);
  await expect.poll(() => overlayOpacity(page)).toBe("0");

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("hovering the card fades the label in over the avatar", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(TRIGGER)).toBeVisible();
  await expect.poll(() => overlayOpacity(page)).toBe("0");

  // THE CARD, AT A POINT THAT IS NOT THE PICTURE. This offset is the whole test.
  // The avatar is centred in the card, so a bare .hover() lands ON it and fires
  // `.studio-avatar-trigger:hover` instead — measured: deleting the card rule
  // entirely left this spec GREEN. Hovering the corner exercises the rule the
  // operator actually asked for.
  await page.locator(CARD).hover({ position: { x: 20, y: 20 } });

  await expect
    .poll(() => overlayOpacity(page), {
      message: "hovering the card did not reveal the label — the reveal rule is not matching the card",
    })
    .toBe("1");

  // OPACITY IS NOT ENOUGH ON ITS OWN. `display: none` computes an opacity of 1
  // under a hover rule just as happily, while rendering nothing and dropping the
  // label out of the accessibility tree — measured: that mutation passed an
  // opacity-only assertion. A box is the claim that it is actually on screen.
  const box = await page.locator(OVERLAY).boundingBox();
  expect(box, "the label has no box — it is hidden by display/visibility, not opacity").not.toBeNull();
  expect(box.width).toBeGreaterThan(0);
});

test("a keyboard reaches the same affordance", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(TRIGGER)).toBeVisible();

  // A keyboard never hovers, and this is the only route to changing the photo —
  // so focus has to do what hover does.
  await page.locator(TRIGGER).focus();

  await expect
    .poll(() => overlayOpacity(page), {
      message: "focusing the avatar left the label hidden — a keyboard user gets no affordance at all",
    })
    .toBe("1");
});

// THE WHOLE CARD IS THE TRIGGER, and it must fire EXACTLY ONCE. The card and the
// avatar button both carry the handler — the button so a keyboard can reach it,
// the card so the click matches the hover. Without `.stop` on the button, a click
// on the picture bubbles to the card and opens two file dialogs.
test("clicking anywhere on the card opens the picker, exactly once", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(TRIGGER)).toBeVisible();

  await page.evaluate(() => {
    window.__pickerClicks = 0;
    document.querySelector('input[type="file"]:not([name])')
      .addEventListener("click", (e) => { e.preventDefault(); window.__pickerClicks++; });
  });

  // A corner of the card — deliberately NOT the picture, which is what the
  // operator reported doing when nothing happened.
  await page.locator(CARD).click({ position: { x: 20, y: 20 } });
  expect(
    await page.evaluate(() => window.__pickerClicks),
    "clicking the card away from the avatar did nothing — the hover lights it up, so the click must act"
  ).toBe(1);

  // And the picture itself still fires once, not twice.
  await page.evaluate(() => { window.__pickerClicks = 0; });
  await page.locator(TRIGGER).click();
  expect(
    await page.evaluate(() => window.__pickerClicks),
    "the avatar's click bubbled to the card as well — two file dialogs"
  ).toBe(1);
});

test("clicking the avatar reaches the file picker", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(TRIGGER)).toBeVisible();

  // THE WIRING, observed rather than assumed. A native file dialog cannot be
  // driven from a spec, so this listens for the click the button forwards to the
  // hidden input — which is the whole of what the button is responsible for. The
  // cropper beyond it is a CDN script this lane deliberately does not load.
  await page.evaluate(() => {
    window.__pickerClicked = false;
    const picker = document.querySelector('input[type="file"]:not([name])');
    picker.addEventListener("click", (e) => {
      e.preventDefault();
      window.__pickerClicked = true;
    });
  });

  await page.locator(TRIGGER).click();

  expect(
    await page.evaluate(() => window.__pickerClicked),
    "clicking the avatar did not reach the file picker — $refs.filePicker is out of scope or the handler is gone"
  ).toBe(true);
});

// --- the birthday, as three selects -------------------------------------------
//
// THIS REPLACED A CALENDAR POPOVER, and the specs it replaced are worth naming
// as they go. There were six, covering: the seven-column grid, fitting on
// screen, not being clipped by its card, staying anchored through a scroll,
// flipping above when short of room, and keeping the side it opened on. Every
// one of them described a positioning problem, and every one existed because a
// previous version of that positioning had shipped broken.
//
// Three selects have no position, no flip, no popover and no scroll listener, so
// none of those specs has anything left to assert. What IS worth asserting moved
// to the date arithmetic — which is where a select-based field can actually be
// wrong.

test("the birthday renders as three selects, not a popover", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");

  const row = page.locator('[data-profile-section="birthday"]');
  await expect(row.locator("select")).toHaveCount(3);

  // The native input is the JS-less branch and must NOT be in the DOM once
  // Alpine has booted — two inputs sharing name="profile[birthday]" would submit
  // both, and the last duplicate wins in Rack's params.
  await expect(page.locator('input[type="date"]')).toHaveCount(0);
  await expect(page.locator(".studio-birthday-popover")).toHaveCount(0);

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("a full date fills the submitted field and raises the save bar", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(SAVE_BAR)).toBeHidden();

  const row = page.locator('[data-profile-section="birthday"]');
  await row.locator("select").nth(0).selectOption("6");
  await row.locator("select").nth(1).selectOption("15");
  await row.locator("select").nth(2).selectOption("1991");

  // The submitted value and the dirty check are two different objects: the field
  // writes the hidden input AND reaches through Alpine's scope chain into the
  // enclosing form's `fields`. A field that set only its own state would leave
  // the save bar down and the edit unsaveable.
  await expect(page.locator(HIDDEN_BIRTHDAY)).toHaveValue("1991-06-15");
  await expect(
    page.locator(SAVE_BAR),
    "the birthday changed but the save bar stayed down — the field never reached the dirty check"
  ).toBeVisible();
});

// A PARTIAL date submits NOTHING. Month alone is not a birthday, and writing
// "1991--" or a half-formed value would be worse than writing nothing.
test("an incomplete date submits no value", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");

  const row = page.locator('[data-profile-section="birthday"]');
  await row.locator("select").nth(0).selectOption("6");

  await expect(page.locator(HIDDEN_BIRTHDAY)).toHaveValue("");
  await expect(page.locator(SAVE_BAR)).toBeHidden();
});

// THE DAY LIST FOLLOWS THE MONTH, which is the one thing three selects can get
// wrong that a calendar could not: a calendar draws only the days that exist,
// while a static 1–31 list happily offers the 31st of February.
test("the day list matches the month, leap years included", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");

  const row = page.locator('[data-profile-section="birthday"]');
  const month = row.locator("select").nth(0);
  const day = row.locator("select").nth(1);
  const year = row.locator("select").nth(2);
  // minus the disabled placeholder option
  const days = async () => (await day.locator("option").count()) - 1;

  await year.selectOption("1991");
  await month.selectOption("4");
  expect(await days(), "April has 30 days").toBe(30);

  await month.selectOption("2");
  expect(await days(), "February 1991 is not a leap year").toBe(28);

  await year.selectOption("1992");
  expect(await days(), "February 1992 IS a leap year").toBe(29);
});

// Pick the 31st, then a month without one. The day must CLEAR rather than submit
// a date that does not exist.
test("switching to a shorter month clears an impossible day", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");

  const row = page.locator('[data-profile-section="birthday"]');
  await row.locator("select").nth(2).selectOption("1991");
  await row.locator("select").nth(0).selectOption("1");
  await row.locator("select").nth(1).selectOption("31");
  await expect(page.locator(HIDDEN_BIRTHDAY)).toHaveValue("1991-01-31");

  await row.locator("select").nth(0).selectOption("2");

  await expect(
    page.locator(HIDDEN_BIRTHDAY),
    "February 31st was submitted — the day did not clear when the month lost it"
  ).toHaveValue("");
});

// A birthday cannot be in the future, and the cheapest way to say so is not to
// offer one: the year list ends at the current year.
test("the year list does not offer the future", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");

  const years = await page.locator('[data-profile-section="birthday"] select').nth(2)
    .locator("option").allTextContents();
  const numeric = years.map(Number).filter((n) => !Number.isNaN(n) && n > 0);
  const thisYear = new Date().getFullYear();

  expect(Math.max(...numeric), "a year later than this one is selectable").toBeLessThanOrEqual(thisYear);
  expect(numeric.length, "the list should span a lifetime, not a handful of years").toBeGreaterThan(100);
});
