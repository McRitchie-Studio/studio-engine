const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The first-name step's EMPTY-FIELD ERROR, as a user actually receives it.
//
// WHY THIS LANE AND NOT THE VIEW TEST. test/views/onboarding_first_name_test.rb
// asserts the sentence is present in the x-data attribute. That is a claim about
// the response bytes, and this component's characteristic failure leaves the
// response bytes looking perfect: a stray quote inside the double-quoted x-data
// closes it early, Alpine mounts a silent no-op, and every element a string
// assertion looks for is still in the markup. The card renders, the button
// clicks, and nothing happens. Only a browser separates those two pages.
//
// So this file never reads source. It clicks the real submit button on an empty
// field and reads the text the user is left looking at.

// THE MOUNT PROBE, and why the specs are not allowed to skip it. An unmounted
// component shows no error either — which is the same observation as "the copy is
// wrong" if all we did was read the alert. Alpine stamps _x_dataStack on a root it
// has successfully initialised, so this distinguishes "the card is alive and said
// X" from "the card is dead and said nothing".
async function expectCardIsLive(page, card) {
  await page
    .waitForFunction(
      (selector) => {
        const root = document.querySelector(`${selector} [x-data]`);
        return Boolean(root && root._x_dataStack);
      },
      card,
      { timeout: 10_000 }
    )
    .catch(() => {
      throw new Error(
        `${card} never initialised. Alpine did not evaluate its x-data — the usual ` +
          "cause is an unescaped quote in an interpolated local, which closes the " +
          "attribute and mounts the component as a silent no-op."
      );
    });
}

// Submit the card with the field left empty, and hand back the text the user sees.
async function submitEmpty(page, card) {
  const alert = page.locator(`${card} [role="alert"]`);

  // ASSERTED ABSENT FIRST. Without this the specs below cannot tell an error the
  // submit PRODUCED from one that was on the page all along, and a card that
  // rendered its error unconditionally would read as a pass.
  await expect(alert, "the error must not be on screen before the field is submitted").toHaveCount(0);

  await page.locator(`${card} button[type="submit"]`).click();
  await expect(alert).toBeVisible();

  return (await alert.textContent()).trim();
}

test.beforeEach(async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/onboarding_first_name");
  await page.waitForFunction(() => Boolean(window.Alpine), null, { timeout: 10_000 });
});

test("the skippable card answers an empty field with today's sentence", async ({ page }) => {
  // The pin. McRitchie Studio renders this card, in this mode, today — so the
  // gated mode below has to be added without moving a character of it.
  const errors = watchPageErrors(page);
  await expectCardIsLive(page, '[data-test="default-card"]');

  const text = await submitEmpty(page, '[data-test="default-card"]');

  expect(text).toBe("Enter your first name, or skip for now.");
  expect(errors).toEqual([]);
});

test("a gated card's empty-field error offers no skip", async ({ page }) => {
  // THE DEFECT. required renders no skip button and no skip link, and the error
  // went on offering one — pointing the user at a control that is not on the page.
  //
  // Both halves are asserted. The positive one alone would pass on copy that
  // dropped the offer and said something useless; the negative one alone would
  // pass on a card whose error never appeared at all, which is why the mount probe
  // and the visible-alert wait come first.
  const errors = watchPageErrors(page);
  await expectCardIsLive(page, '[data-test="required-card"]');

  const text = await submitEmpty(page, '[data-test="required-card"]');

  expect(text).toBe("Enter your first name to continue.");
  expect(text.toLowerCase()).not.toContain("skip");
  expect(errors).toEqual([]);
});

test("a host's apostrophe reaches the screen instead of killing the card", async ({ page }) => {
  // empty_error is the first host-supplied PROSE to be interpolated into the
  // x-data, and prose carries apostrophes. Dropped escaping does not render a
  // mangled sentence — it renders NO sentence, because the JS string closes early
  // and the whole component dies. That is why this asserts the exact text AND an
  // empty page-error log: the SyntaxError is the sharpest possible signal, and it
  // only exists in a browser.
  const errors = watchPageErrors(page);
  await expectCardIsLive(page, '[data-test="custom-card"]');

  const text = await submitEmpty(page, '[data-test="custom-card"]');

  expect(text).toBe("We'll need your first name before you continue.");
  expect(errors).toEqual([]);
});
