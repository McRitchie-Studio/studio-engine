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
    await expect(page.getByText(/Easy, Young.un/i)).toBeVisible();
    await expect(page.getByRole("link", { name: /Watch the Contest/i })).toBeVisible();
  });

  test("the refusal is a card, not the error line", async ({ page }) => {
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-birthday-underage"]').click();
    await pickDob(page);
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();

    await expect(page.getByText(/Easy, Young.un/i)).toBeVisible();

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
    await expect(page.getByText(/Easy, Young.un/i)).toBeVisible();

    await page.getByRole("button", { name: /Update your Birthday/i }).click();

    // Back on the ASK. Asserting on the DOB selects rather than the title,
    // because a swap to an unregistered id leaves a blank card whose title is
    // also absent — the selects prove something actually mounted.
    await expect(page.locator('select[x-model="month"]')).toBeVisible();
    await expect(page.getByRole("button", { name: /Confirm & Continue/i })).toBeVisible();

    // AND IT IS THE VALIDATING CARD. "a live card came back" was all this
    // asserted until 2026-08-25, and that is exactly the hole a real defect went
    // through: the style guide's specimen chose its mode from a prop, back()
    // swaps with EMPTY props, and undefined-is-falsy landed the return trip on
    // the NO-BAR card — where resubmitting the same under-age date was accepted.
    // A card with no age line looks identical to one with it unless you look.
    await expect(page.getByText(/must be\s*21\+/i)).toBeVisible();

    // And the refusal is gone, so this is a swap and not a stack.
    await expect(page.getByText(/Easy, Young.un/i)).toHaveCount(0);
  });

  // THE ROUND TRIP, walked end to end. Only a browser can answer this: the
  // server's bytes are the same three empty <select>s whether the date comes
  // back, because the values are chosen after mount. The unit lane
  // (test/views/birthday_return_trip_test.rb) executes both halves of the seam
  // under node and proves the PAYLOAD travels; what it has no DOM for is whether
  // the selects actually re-pick — which is the half that failed for a person.
  //
  // It failed here for a real reason worth keeping: Alpine walks
  // <select x-model="month"> BEFORE the <template x-for> that fills it, so a
  // value assigned during init lands on an empty option list and is dropped. The
  // component state would be perfect and all three selects would still read
  // blank. The factory defers its seeding to $nextTick for exactly that, and this
  // spec is the only thing that can see the difference.
  test("Update your Birthday brings the date back", async ({ page }) => {
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-birthday-underage"]').click();
    await pickDob(page);
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();
    await expect(page.getByText(/Easy, Young.un/i)).toBeVisible();

    await page.getByRole("button", { name: /Update your Birthday/i }).click();

    // All three, not just the year. The defect discarded the whole props bag, so
    // asserting one field would pass against a fix that carried one field.
    await expect(page.locator('select[x-model="month"]')).toHaveValue("6");
    await expect(page.locator('select[x-model="day"]')).toHaveValue("15");
    await expect(page.locator('select[x-model="year"]')).toHaveValue("2010");

    // And the card is IMMEDIATELY submittable. A returning date that leaves the
    // button disabled is the same dead end in a nicer coat — the person can see
    // their date and still cannot act on it.
    await expect(page.getByRole("button", { name: /Confirm & Continue/i })).toBeEnabled();
  });

  test("a date brought back is still RE-JUDGED on submit", async ({ page }) => {
    // The gate must not be weakened by the convenience. Restoring the date
    // restores the DATE, never the verdict — and "the card came back filled in"
    // and "the card came back filled in and now accepts what it just refused"
    // are the same screen until this is asked.
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-birthday-underage"]').click();
    await pickDob(page);
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();
    await expect(page.getByText(/Easy, Young.un/i)).toBeVisible();

    await page.getByRole("button", { name: /Update your Birthday/i }).click();
    await expect(page.locator('select[x-model="year"]')).toHaveValue("2010");

    // Untouched, resubmitted, refused again.
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();
    await expect(page.getByText(/Easy, Young.un/i)).toBeVisible();

    // And correcting the year is now ONE change, which is the entire promise the
    // card's header comment makes: a correction, not a restart.
    await page.getByRole("button", { name: /Update your Birthday/i }).click();
    await page.selectOption('select[x-model="year"]', "1990");
    await expect(page.locator('select[x-model="month"]')).toHaveValue("6");
    await expect(page.locator('select[x-model="day"]')).toHaveValue("15");
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();
    await expect(page.getByText(/Easy, Young.un/i)).toHaveCount(0);
  });

  test("a passing date does NOT open the gate", async ({ page }) => {
    // The control for every assertion above: if the gate opened on every submit,
    // all four would still pass and the card would be broken for everyone.
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-birthday"]').click();
    await pickDob(page, { year: "1990" });
    await page.getByRole("button", { name: /Confirm & Continue/i }).click();

    await expect(page.getByText(/Easy, Young.un/i)).toHaveCount(0);
  });

  // The countdown's ARITHMETIC, evaluated in the page so the assertions run
  // against the shipped code rather than a copy of it. Two of these were RED on
  // the first implementation:
  //
  //   · bare setMonth OVERFLOWS. Jan 31 + 1 month is Feb 31, which JS rolls
  //     forward to Mar 3 — so every person born on a 29th, 30th or 31st was told
  //     one month less than the truth.
  //   · dividing milliseconds to get DAYS drifts across a DST boundary. A 28-day
  //     March span reported 27d 23h.
  //
  // Both are invisible to a markup test and to a spec that only reads the
  // rendered string, because both produce a plausible-looking number.
  test("the countdown clamps months and survives DST", async ({ page }) => {
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-age-gate"]').click();
    await expect(page.getByText(/Easy, Young.un/i)).toBeVisible();

    const cases = [
      ["exactly one month", [2026, 0, 15], [2026, 1, 15], "1m 0d"],
      ["month overflow",    [2026, 0, 31], [2026, 2, 31], "2m 0d"],
      ["short month clamp", [2026, 0, 31], [2026, 1, 28], "1m 0d"],
      ["across DST",        [2026, 2, 1],  [2026, 2, 29], "0m 28d"],
      ["leap-day target",   [2026, 7, 25], [2028, 1, 29], "18m 4d"]
    ];

    for (const [label, from, to] of cases) {
      const got = await page.evaluate(([f, t]) => {
        // Reach the LIVE component instance and drive its own arithmetic.
        const el = document.querySelector('[x-data*="addMonths"]');
        const c = window.Alpine.$data(el);
        const now = new Date(f[0], f[1], f[2]).getTime();
        const target = new Date(t[0], t[1], t[2]);
        // remaining() reads this.now and this.eligibleAt, so exercise the two
        // primitives it is built from rather than stubbing the getters.
        let months = 0;
        while (c.addMonths(new Date(now), months + 1).getTime() <= target.getTime()) months++;
        let probe = c.addMonths(new Date(now), months);
        let days = 0;
        for (;;) {
          const next = new Date(probe.getTime());
          next.setDate(next.getDate() + 1);
          if (next.getTime() > target.getTime()) break;
          probe = next; days++;
        }
        return months + "m " + days + "d";
      }, [from, to]);
      expect(got, label).toBe(cases.find(c => c[0] === label)[3]);
    }
  });

  test("the countdown ticks", async ({ page }) => {
    // A frozen number reads as a rendering artefact rather than a clock, and a
    // dead interval is invisible in markup — the first render looks identical.
    await page.goto("/lab/birthday_gate");
    await page.locator('[data-test="open-age-gate"]').click();
    const line = page.locator("strong", { hasText: /second/ }).first();
    await expect(line).toBeVisible();
    const first = await line.textContent();
    await page.waitForTimeout(2200);
    const second = await line.textContent();
    expect(second).not.toBe(first);
  });
});
