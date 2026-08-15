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
//   · The calendar popover is `position: fixed`, and proving that took two specs
//     rather than one. At scroll 0 fixed and absolute render in the SAME PLACE,
//     so swapping them left every geometry assertion green; the difference only
//     appears once the page moves, because place() writes viewport coordinates
//     that absolute reinterprets as document ones. Either way the failure renders
//     perfectly correct markup and is simply in the wrong place — the defect class
//     no String assertion can reach.
//
// The lab page reproduces the edit page's `overflow-hidden` container on purpose,
// so these specs run against a page shaped like the real one.

const CARD = "[data-studio-identity-full]";
const TRIGGER = "button.studio-avatar-trigger";
const OVERLAY = ".studio-avatar-overlay";
const POPOVER = ".studio-birthday-popover";
const DATE_TRIGGER = '[x-ref="trigger"]';
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

// --- the birthday calendar ----------------------------------------------------

test("the birthday field opens a calendar rather than a text box", async ({ page }) => {
  const pageErrors = watchPageErrors(page);

  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");

  // The native input is the JS-less branch and must NOT be in the DOM once Alpine
  // has booted — two inputs sharing name="profile[birthday]" would submit both,
  // and the last duplicate wins in Rack's params.
  await expect(page.locator(DATE_TRIGGER)).toBeVisible();
  await expect(page.locator('input[type="date"]')).toHaveCount(0);

  await expect(page.locator(POPOVER)).toBeHidden();

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("the calendar is not clipped by the card it opens inside", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(DATE_TRIGGER).click();

  await expect(page.locator(POPOVER)).toBeVisible();

  const box = await page.locator(POPOVER).boundingBox();
  const viewport = page.viewportSize();

  expect(box, "the popover has no box at all — it did not render").not.toBeNull();
  expect(box.width, "the popover collapsed to nothing").toBeGreaterThan(100);
  expect(box.y, "the popover opened above the viewport").toBeGreaterThanOrEqual(0);
  expect(
    box.y + box.height,
    "the popover's bottom is off-screen — it was clipped or placed past the fold"
  ).toBeLessThanOrEqual(viewport.height + 1);
});

test("the calendar stays anchored to its field when the page scrolls", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(DATE_TRIGGER).click();
  await expect(page.locator(POPOVER)).toBeVisible();

  // THIS IS WHERE FIXED AND ABSOLUTE ACTUALLY DIVERGE, and the previous spec does
  // not reach it: at scroll 0 the two render in the same place, so swapping
  // `position: fixed` for `absolute` left every assertion above green.
  //
  // place() writes VIEWPORT coordinates from the trigger's rect. Fixed keeps
  // them meaningful as the page moves; absolute reinterprets them as document
  // coordinates, so the popover drifts by exactly the scroll offset and detaches
  // from the field it belongs to.
  await page.evaluate(() => window.scrollBy(0, 300));
  await page.waitForTimeout(100);

  const trigger = await page.locator(DATE_TRIGGER).boundingBox();
  const popover = await page.locator(POPOVER).boundingBox();

  expect(
    Math.abs(popover.y - (trigger.y + trigger.height)),
    "the calendar detached from its field after a scroll — it is positioned in document space, not viewport space"
  ).toBeLessThan(24);
});

test("picking a day fills the field and raises the save bar", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(SAVE_BAR)).toBeHidden();

  await page.locator(DATE_TRIGGER).click();
  await page.locator(POPOVER).locator("select").first().selectOption("5"); // June
  await page.locator(POPOVER).getByRole("button", { name: "15", exact: true }).click();

  // The submitted value, and the dirty check, are two different objects — the
  // picker writes the hidden input AND reaches through Alpine's scope chain into
  // the enclosing form's `fields`. A picker that set only its own state would
  // leave the save bar down and the edit unsaveable.
  await expect(page.locator(HIDDEN_BIRTHDAY)).toHaveValue(/^\d{4}-06-15$/);
  await expect(
    page.locator(SAVE_BAR),
    "the birthday changed but the save bar stayed down — the picker never reached the dirty check"
  ).toBeVisible();
  await expect(page.locator(POPOVER)).toBeHidden();
});

test("a birthday cannot be set in the future", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(DATE_TRIGGER).click();

  // Drive the view to THIS month, where the boundary actually falls — a whole
  // future year would be a weaker test, because every cell in it is future and a
  // naive year-level clamp would pass.
  const now = await page.evaluate(() => ({ y: new Date().getFullYear(), m: new Date().getMonth(), d: new Date().getDate() }));
  const selects = page.locator(POPOVER).locator("select");
  await selects.nth(1).selectOption(String(now.y));
  await selects.nth(0).selectOption(String(now.m));

  const lastDay = await page.evaluate(({ y, m }) => new Date(y, m + 1, 0).getDate(), now);

  if (lastDay > now.d) {
    await expect(
      page.locator(POPOVER).getByRole("button", { name: String(lastDay), exact: true }),
      "a day later this month is selectable — a birthday cannot be in the future"
    ).toBeDisabled();
  }

  // Today itself is a legal birthday (someone born today), and the same guard
  // must not swallow it.
  await expect(
    page.locator(POPOVER).getByRole("button", { name: String(now.d), exact: true })
  ).toBeEnabled();
});

// --- the calendar's own layout ------------------------------------------------

// THE BUG THE OPERATOR SAW, and the one this lane was structurally blind to.
//
// The popover first shipped using `grid grid-cols-7`. The engine ships a PREBUILT
// bundle, so a Tailwind utility exists in a consuming app only if that app's own
// views already emitted it — and `grid-cols-7` is rare enough that none had.
// Measured in mcritchie-studio's compiled bundle: zero occurrences. With no grid
// the seven weekday letters stacked into one vertical column and the popover grew
// to the height of the page.
//
// THIS SPEC ALONE WOULD NOT HAVE CAUGHT IT, and that is worth saying plainly:
// e2e/tailwind_input.css carries `@source "../app/views"`, so the lane compiles
// the ENGINE's views and emits grid-cols-7 that no consumer has. What makes the
// assertion meaningful now is that the rule is OWNED CSS shipped in the partial,
// which is true in every app regardless of what its bundle emitted.
test("the calendar lays out as seven columns", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(DATE_TRIGGER).click();
  await expect(page.locator(POPOVER)).toBeVisible();

  const grid = await page.evaluate(() => {
    const el = document.querySelector(".studio-birthday-grid");
    if (!el) return null;
    const s = window.getComputedStyle(el);
    return { display: s.display, tracks: s.gridTemplateColumns.split(" ").length };
  });

  expect(grid, "no .studio-birthday-grid — the calendar is not using its own layout").not.toBeNull();
  expect(grid.display, "the day grid is not a grid at all — this is the stacked-column bug").toBe("grid");
  expect(grid.tracks, "a week has seven days; anything else means the columns did not resolve").toBe(7);
});

// The popover must not be taller than the viewport it has to be placed inside.
// When the grid collapsed, it became as tall as the page — which is what made the
// placement look, in the operator's words, like it "freaks out" on scroll.
test("the calendar fits on screen", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(DATE_TRIGGER).click();
  await expect(page.locator(POPOVER)).toBeVisible();

  const box = await page.locator(POPOVER).boundingBox();
  const viewport = page.viewportSize();

  expect(
    box.height,
    "the popover is taller than the viewport — its rows are stacking instead of gridding"
  ).toBeLessThan(viewport.height);
});

// THE FLIP BRANCH, which no earlier spec ever ran.
//
// The lab page's birthday field sits near the top with plenty of room below, so
// every placement assertion above exercised the BELOW branch only. The flip path
// — used whenever the field is near the bottom of the viewport — shipped
// untested, and it was wrong: it placed the popover using a hardcoded
// `estimatedHeight = 340` while the real popover is about 245px, so a flipped
// calendar floated ~95px above its field and jumped on every scroll. The operator
// found it in turf-monster.
//
// "It fits on screen" could not catch that. A popover 95px too high still fits.
// The property that separates right from wrong is that its BOTTOM edge sits
// against the trigger's TOP edge.
test("the calendar flips above its field and stays attached to it", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");

  // Put the field near the bottom of the viewport so there is no room below and
  // the flip branch is the one that runs.
  await page.locator(DATE_TRIGGER).evaluate((el) => el.scrollIntoView({ block: "end" }));
  await page.evaluate(() => window.scrollBy(0, -40));

  await page.locator(DATE_TRIGGER).click();
  await expect(page.locator(POPOVER)).toBeVisible();

  const trigger = await page.locator(DATE_TRIGGER).boundingBox();
  const popover = await page.locator(POPOVER).boundingBox();
  const viewport = page.viewportSize();

  // It really did flip — otherwise this spec is silently re-testing the below
  // branch and proves nothing about the one that was broken.
  expect(
    popover.y,
    "the popover opened BELOW the field — this spec did not exercise the flip branch it exists for"
  ).toBeLessThan(trigger.y);

  // THE ASSERTION THE ESTIMATE FAILED. Bottom edge against the field's top edge.
  expect(
    Math.abs(trigger.y - (popover.y + popover.height)),
    "the flipped calendar is detached from its field — its height was guessed, not measured"
  ).toBeLessThan(12);

  expect(popover.y, "the flip pushed it off the top of the viewport").toBeGreaterThanOrEqual(0);
  expect(popover.y + popover.height).toBeLessThanOrEqual(viewport.height + 1);
});
