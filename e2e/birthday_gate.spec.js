const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// The lab pages tag controls with data-test, and playwright.config.js does not
// remap testIdAttribute — so getByTestId (which looks for data-testid) finds
// nothing here. Every existing spec in this lane selects by attribute; so does
// this one.

// [e2e] The birthday card's refusal HANDOFF.
//
// WHY THIS IS IN THE BROWSER LANE AND NOT test/views. The server's bytes are the
// same whether any of this works. Both cards render, both carry their CTAs, and
// every String assertion in test/views passes in either world. What the markup
// cannot contain is the PROGRAM: birthdayModal's submit(), which decides that an
// under-age date is a REFUSAL rather than an error, and swaps one card for
// another on the store.
//
// The defect each assertion exists to catch:
//
//   1. The handoff fires.        Before 2026-08-24 an under-age date turned the
//                                card red and DISABLED its own submit button —
//                                the one screen state with nothing to press. A
//                                markup test cannot tell a disabled button from
//                                an enabled one's intent, and cannot see a swap.
//   2. The refusal is not an     The old build showed the verdict in the same
//      error.                    red <p> as an invalid date. If the refusal
//                                regresses into that line, the gate card never
//                                opens and this catches it.
//   3. Both exits work.          A CTA pointing nowhere and a back link that
//                                does not return are both invisible in markup —
//                                the href and the @click render fine either way.
//   4. The round trip closes.    "Update your Birthday" must land back on a
//                                LIVE birthday card, not a blank shell. A swap
//                                to an unregistered id renders nothing, and an
//                                empty modal looks like a styling bug.

test.describe("birthday → age gate handoff", () => {
  test.beforeEach(async ({ page }) => {
    watchPageErrors(page);
    await blockOffsiteRequests(page);
  });

  // Fill the three DOB selects with a date the lab's 21+ bar refuses.
  async function pickDob(page, { month = "6", day = "15", year = "2010" } = {}) {
    await page.selectOption('select[x-model="month"]', month);
    await page.selectOption('select[x-model="day"]', day);
    await page.selectOption('select[x-model="year"]', year);
  }

  test("an under-age date submits and hands off to the age gate", async ({ page }) => {
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-birthday-underage"]').click();

    const confirm = page.getByRole("button", { name: /Confirm & Continue/i });
    await expect(confirm).toBeVisible();

    await pickDob(page);

    // THE ASSERTION THE OLD BUILD WOULD FAIL. It disabled this button on an
    // under-age date; a disabled button never fires submit(), so the handoff
    // below could not happen at all.
    await expect(confirm).toBeEnabled();
    await confirm.click();

    // The refusal card, not a red line on the card we came from.
    await expect(page.getByText(/You must be 21\+ to join/i)).toBeVisible();
    await expect(page.getByRole("link", { name: /Watch the Contest/i })).toBeVisible();
  });

  test("the refusal is a card, not the error line", async ({ page }) => {
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-birthday-underage"]').click();
    await pickDob(page);
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();

    await expect(page.getByText(/You must be 21\+ to join/i)).toBeVisible();

    // The birthday card's red error paragraph must be gone from the DOM, not
    // merely hidden behind it — the two used to be the same element.
    await expect(page.locator("p.text-red-400")).toHaveCount(0);
  });

  test("the watch CTA points somewhere real", async ({ page }) => {
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-age-gate"]').click();

    const cta = page.getByRole("link", { name: /Watch the Contest/i });
    await expect(cta).toBeVisible();
    // A resolved href, read from the live DOM — an empty or "#" target renders
    // identically in markup and is the way this CTA dies quietly.
    const href = await cta.getAttribute("href");
    expect(href).toBeTruthy();
    expect(href).not.toBe("#");
  });

  test("Update your Birthday returns to a LIVE birthday card", async ({ page }) => {
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-age-gate"]').click();
    await expect(page.getByText(/You must be 21\+ to join/i)).toBeVisible();

    await page.getByRole("button", { name: /Update your Birthday/i }).click();

    // Back on the ASK. Asserting on the DOB selects rather than the title,
    // because a swap to an unregistered id leaves a blank card whose title is
    // also absent — the selects prove something actually mounted.
    await expect(page.locator('select[x-model="month"]')).toBeVisible();
    await expect(page.getByRole("button", { name: /Confirm & Continue/i })).toBeVisible();
    // And the refusal is gone, so this is a swap and not a stack.
    await expect(page.getByText(/You must be 21\+ to join/i)).toHaveCount(0);
  });

  test("a passing date does NOT open the gate", async ({ page }) => {
    // The control for every assertion above: if the gate opened on every submit,
    // all four would still pass and the card would be broken for everyone.
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-birthday"]').click();
    await pickDob(page, { year: "1990" });
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();

    await expect(page.getByText(/You must be 21\+ to join/i)).toHaveCount(0);
  });
});
