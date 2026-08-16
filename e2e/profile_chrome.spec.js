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


// The overlap between the save controls and the card's OWN text, measured on the
// rendered GLYPHS. Range rather than the <p> boxes, because the paragraphs are
// full-width and centred: their rects span the card and would report an overlap
// even when the text itself is nowhere near the controls.
async function textOverlaps(page) {
  return await page.evaluate(() => {
    const card = document.querySelector("[data-studio-identity-full]");
    const controls = document.querySelector('[data-studio-save-controls="card"]');
    const c = controls.getBoundingClientRect();
    const walker = document.createTreeWalker(card, NodeFilter.SHOW_TEXT);
    const hits = [];
    let node;
    while ((node = walker.nextNode())) {
      if (!node.textContent.trim()) continue;
      if (controls.contains(node)) continue;
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const r of range.getClientRects()) {
        const dx = Math.min(c.right, r.right) - Math.max(c.left, r.left);
        const dy = Math.min(c.bottom, r.bottom) - Math.max(c.top, r.top);
        if (dx > 0 && dy > 0) {
          hits.push({ text: node.textContent.trim().slice(0, 44), dx: Math.round(dx) });
        }
      }
    }
    return hits;
  });
}

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

test("the save controls rise on an edit", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");

  await page.locator(FIRST_NAME).fill("Patricia");

  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();
  await expect(page.locator(SAVE_CONTROLS_CARD).getByRole("button", { name: "Save changes" })).toBeVisible();
  await expect(page.locator(SAVE_CONTROLS_CARD).getByRole("button", { name: "Discard" })).toBeVisible();
});

// THE COUNT IS COUNTED, AND NOT SEEN. "1 unsaved change  Discard" became a
// simple "Discard" on the operator's call — but the number stayed in the
// document for assistive tech, because the visual and the audible cue are not
// the same cue: two buttons appearing IS the notification for someone who can
// see them, and this live region is the whole of it for someone who cannot.
//
// `not.toBeVisible()` CANNOT express this. sr-only clips to a 1px box rather
// than removing the element, and Playwright calls a 1px box visible — so the
// assertion has to be about the SIZE. Measuring it is also the only way to catch
// the class being dropped, which would put "1 unsaved change" back on screen.
test("the change count is announced but not shown", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  const controls = page.locator(SAVE_CONTROLS_CARD);
  await expect(controls, "the count left the document — nothing announces it now")
    .toContainText("1 unsaved change");

  const box = await controls.locator("p").boundingBox();
  expect(
    box.width,
    "the change count is taking up real space on screen — it should be screen-reader only"
  ).toBeLessThanOrEqual(2);
});

// SAVE ON TOP OF DISCARD in the card (operator's call, 2026-08-15). A stack puts
// the primary action first the same way a row puts it last, and which one is
// where is a fact about two boxes rather than about the markup — the DOM order
// and the visual order can disagree the moment anything reverses the flex.
test("in the card, Save changes sits above Discard", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  const controls = page.locator(SAVE_CONTROLS_CARD);
  const save = await controls.getByRole("button", { name: "Save changes" }).boundingBox();
  const discard = await controls.getByRole("button", { name: "Discard" }).boundingBox();

  expect(save.y + save.height, "Save changes is not above Discard").toBeLessThanOrEqual(discard.y + 1);

  // STACKED, not merely ordered: a row would also satisfy "Save's bottom is above
  // Discard's top" when both sit on the same line and rounding goes the right way.
  expect(Math.abs(save.x - discard.x), "the two are side by side, not stacked").toBeLessThan(2);
});

// The compact bar keeps them in a ROW — it has width rather than height — with
// the primary action last, which is the other half of the same convention.
test("in the compact bar, the two sit side by side", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(FIRST_NAME).fill("Patricia");
  await page.evaluate(() => window.scrollTo(0, 1500));
  await expect(page.locator(MINI)).toHaveClass(/is-visible/);

  const controls = page.locator(SAVE_CONTROLS_COMPACT);
  const save = await controls.getByRole("button", { name: "Save changes" }).boundingBox();
  const discard = await controls.getByRole("button", { name: "Discard" }).boundingBox();

  expect(Math.abs(save.y - discard.y), "the compact bar stacked them — it has no room").toBeLessThan(2);
  expect(discard.x, "Discard is not first in the row").toBeLessThan(save.x);
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

// --- what the lane could not see -----------------------------------------------
//
// Both of these cover regressions this change introduced and every one of the 59
// specs before them missed. They are grouped because the reason they were missed
// is the same in both cases: the lane only ever looked at one width, and never at
// the keyboard.

// THE KEYBOARD REACHES WHAT THE MOUSE CANNOT. The compact bar hides with
// `opacity: 0` and `pointer-events: none`, and NEITHER removes an element from
// the tab order or the accessibility tree. This change is the first to put
// BUTTONS in that bar, so on an unscrolled dirty page the first two tab stops
// became an invisible Discard and Save — and _identity_mini renders BEFORE the
// card, so they came first. Tab, Enter, and the edits were gone with nothing on
// screen to explain it.
//
// This is the same observation the lane already made for the MOUSE — the buttons
// were "visible, focusable, and completely dead to the mouse", fixed with
// `pointer-events: auto`. The keyboard half was left open, because the lane had
// no focus assertions at all.
test("focus cannot reach the compact controls while the bar is hidden", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  // The bar is hidden: it has not scrolled into play.
  await expect(page.locator(MINI)).not.toHaveClass(/is-visible/);

  // Walk the first several tab stops from the top of the document. Not just one:
  // what makes this dangerous is that the invisible controls come FIRST, and a
  // single Tab would only catch that particular ordering.
  await page.evaluate(() => document.body.focus());
  for (let i = 0; i < 8; i += 1) {
    await page.keyboard.press("Tab");
    const inHiddenBar = await page.evaluate(() => {
      const el = document.activeElement;
      const bar = el && el.closest("[data-studio-identity-mini]");
      return Boolean(bar) && !bar.classList.contains("is-visible");
    });
    expect(
      inHiddenBar,
      "focus landed inside the hidden compact bar — pressing Enter there runs Discard " +
        "and destroys the edits, with nothing on screen"
    ).toBe(false);
  }
});

// AND MUST REACH THEM ONCE THE BAR IS SHOWING, or the fix above has simply made
// them permanently unreachable — which would be a worse bug than the one it
// closes, and an `inert` that is never removed looks identical from the outside.
test("focus reaches the compact controls once the bar is showing", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(FIRST_NAME).fill("Patricia");
  await page.evaluate(() => window.scrollTo(0, 1500));
  await expect(page.locator(MINI)).toHaveClass(/is-visible/);

  await page.locator(SAVE_CONTROLS_COMPACT).getByRole("button", { name: "Discard" }).focus();

  const focused = await page.evaluate(() => {
    const el = document.activeElement;
    return {
      text: el && el.textContent.trim(),
      inBar: Boolean(el && el.closest("[data-studio-identity-mini]"))
    };
  });
  expect(focused.inBar, "the controls stayed inert after the bar appeared").toBe(true);
  expect(focused.text).toBe("Discard");
});

// THE PHONE WIDTHS, which this lane had never run. playwright.config.js declares
// no viewport, so all 59 specs before these ran at Chromium's default 1280x720 —
// the one width at which the overlap below measures exactly 0px.
//
// `test.use` inside a describe rather than a new PROJECT, deliberately: a project
// runs every spec again and would double the lane's count, which the contract in
// config/e2e_lane.yml calls out.
test.describe("on a phone", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  // THE CONTROLS MUST NOT PAINT ON THE USER'S OWN NAME AND ADDRESS. Absolute
  // positioning inside a text-center card put them exactly there: at 390px they
  // covered 106px of the name and 64px of the email, and elementFromPoint along
  // the email returned the Discard button.
  //
  // Measured on the GLYPHS via Range, not on the <p> boxes: the paragraphs are
  // full-width and centred, so their rects span the card and would report an
  // overlap even when the text itself is clear.
  // AGAINST THE LONG IDENTITY, like its desktop counterpart. Run against the
  // default fixture this spec passed with 10.77px of margin on the name and
  // ZERO on the email — technically green, and one character from being a spec
  // that reports success on a broken page.
  test("the controls do not cover the name or the email", async ({ page }) => {
    await blockOffsiteRequests(page);
    await page.goto("/lab/profile_edit?identity=long");
    await page.locator(FIRST_NAME).fill("Patricia");
    await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

    const overlaps = await textOverlaps(page);
    expect(
      overlaps,
      `the save controls are painted over the card's own text: ${JSON.stringify(overlaps)}`
    ).toEqual([]);
  });

  // THE COMPACT BAR MUST STILL SAY WHOSE PAGE THIS IS. It is not inside
  // .studio-identity-actions, so the in-flow rule for the card never reached it,
  // and it kept the corner arrangement's assumptions in a strip with no room for
  // them: at 320px, scrolled and dirty, the name had 13px of clientWidth against
  // 71px of content and rendered as "P.", the address as "p..". Telling you whose
  // page you are on is the bar's only job.
  //
  // Measured as clientWidth against scrollWidth, which is what "this text is
  // truncated" actually means — `truncate` clips with an ellipsis, so the element
  // is present and visible at any width and no visibility assertion can see it.
  // AND THE CONTROLS ARE STILL USABLE at this width — the fix moves them, it does
  // not hide them. A rule that pushed them off the card would satisfy the
  // overlap assertion above perfectly.
  test("the controls are still on screen and clickable", async ({ page }) => {
    await blockOffsiteRequests(page);
    await page.goto("/lab/profile_edit");
    await page.locator(FIRST_NAME).fill("Patricia");

    const discard = page.locator(SAVE_CONTROLS_CARD).getByRole("button", { name: "Discard" });
    await expect(discard).toBeVisible();
    await discard.click();

    await expect(page.locator(FIRST_NAME)).toHaveValue("Pat");
  });
});

// THE GAP BETWEEN THE BUTTONS IS STILL CARD SURFACE. Both buttons stop their own
// clicks, which is what the earlier spec covers — but the 8px gap between them
// belongs to the card, so a click landing there bubbled to the card's handler and
// opened the file picker. Found in review by clicking the gap midpoint.
test("clicking between the two buttons does not open the picker", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  await page.evaluate(() => {
    window.__picks = 0;
    const picker = document.querySelector('input[type="file"]:not([name])');
    picker.addEventListener("click", (e) => { window.__picks += 1; e.preventDefault(); });
  });

  const controls = page.locator(SAVE_CONTROLS_CARD);
  const save = await controls.getByRole("button", { name: "Save changes" }).boundingBox();
  const discard = await controls.getByRole("button", { name: "Discard" }).boundingBox();

  // The midpoint of the vertical gap between them — card surface, not a button.
  const gapY = (save.y + save.height + discard.y) / 2;
  await page.mouse.click(save.x + save.width / 2, gapY);

  expect(
    await page.evaluate(() => window.__picks),
    "a click in the gap between the buttons bubbled to the card and opened the photo picker"
  ).toBe(0);
});

// --- the overlap PROPERTY, not one instance of it ------------------------------
//
// THIS SHIPPED TWICE. The first version put the controls in the card's corner and
// they painted over the user's name and email; the fix was a 639px media query,
// written against review's phone-width measurements. It closed those widths and
// left the property open, because the property was never about the viewport — it
// is about whether the CENTRED TEXT is long enough to reach the corner.
//
// Measured at 1280px with that media query in place: a 30-character name lost
// 27px, a 33-character name 51px, a 64-character email 19px, and elementFromPoint
// over the email returned the Discard button. All 64 specs stayed green, because
// the lab fixture is "Pat Studio" — short enough to measure exactly 0px at every
// width there is.
//
// So these run against ?identity=long, and they are the specs that would have
// caught it the first time.

test("long text does not reach the controls at desktop width", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit?identity=long");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  const overlaps = await textOverlaps(page);
  expect(
    overlaps,
    `the save controls are painted over the card's own text: ${JSON.stringify(overlaps)}`
  ).toEqual([]);
});

// THE GUTTER MUST STAY WIDER THAN THE CONTROLS. The fix is arithmetic — the text
// is padded by more than the controls occupy — and arithmetic quietly stops
// holding when one of its terms changes. A longer button label ("Save all
// changes") would widen the controls past a fixed gutter and reopen the overlap
// with no spec noticing, which is precisely how this reached review twice.
test("the text gutter stays wider than the controls it makes room for", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/profile_edit?identity=long");
  await page.locator(FIRST_NAME).fill("Patricia");
  await expect(page.locator(SAVE_CONTROLS_CARD)).toBeVisible();

  const { gutter, controls } = await page.evaluate(() => {
    const card = document.querySelector("[data-studio-identity-full]");
    const value = getComputedStyle(card).getPropertyValue("--studio-actions-gutter");
    const probe = document.createElement("div");
    probe.style.width = value;
    card.appendChild(probe);
    const px = probe.getBoundingClientRect().width;
    probe.remove();
    return {
      gutter: px,
      controls: document.querySelector('[data-studio-save-controls="card"]').getBoundingClientRect().width
    };
  });

  expect(
    gutter,
    `the gutter is ${Math.round(gutter)}px but the controls are ${Math.round(controls)}px — ` +
      "the text can reach them again"
  ).toBeGreaterThan(controls);
});

// A NARROWER PHONE STILL. Its own describe rather than a `test.use` inside the
// 390px block, because test.use applies to the WHOLE describe wherever it sits —
// dropping one in mid-block silently re-ran the overlap specs at 320px too.
test.describe("on the narrowest phone", () => {
  test.use({ viewport: { width: 320, height: 800 } });

  test("the compact bar's name is still readable", async ({ page }) => {
    await blockOffsiteRequests(page);
    await page.goto("/lab/profile_edit?identity=long");
    await page.locator(FIRST_NAME).fill("Patricia");
    await page.evaluate(() => window.scrollTo(0, 1500));
    await expect(page.locator(MINI)).toHaveClass(/is-visible/);

    const name = await page.evaluate(() => {
      const el = document.querySelector("[data-studio-identity-mini] p");
      return { shown: el.clientWidth, needed: el.scrollWidth, text: el.textContent.trim() };
    });

    expect(
      name.shown,
      `the name is clipped to ${name.shown}px of ${name.needed}px — nothing legible is left of ` +
        `"${name.text}"`
    ).toBeGreaterThan(60);
  });
});
