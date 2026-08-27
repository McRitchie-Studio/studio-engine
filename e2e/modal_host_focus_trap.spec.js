const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The GLOBAL modal host's focus contract — the half that had no browser at all.
//
// WHY A SECOND FILE. e2e/modal_focus_trap.spec.js drives /lab/birthday_gate, which
// renders `studio/modals/scoped_host` — a PER-PAGE store. The GLOBAL host
// (`studio/modals/_host`, the `$store.modals` singleton every consumer app mounts
// once in its layout) is a separate ~800-line partial with its OWN copy of the focus
// trap, its own open/close/closeAllDismissible, and its own animation machinery.
// Nothing in this lane ever loaded it. Both files were fixed together and both were
// wrong in the same way — but "we fixed both" is a claim, and a claim about focus is
// exactly what a browser is for. Two files that merely LOOK alike is how the
// three-dialect problem starts.
//
// WHY EVERY SEAM TEST PRESSES SHIFT+TAB. Chrome parks the sequential-focus-navigation
// starting point where the removed node was, so FORWARD Tab lands back inside by
// accident and is green against a released trap. That is precisely why the original
// forward-only Tab spec stayed green through the swap defect. Backward walks the other
// way and leaves.
test.describe("global modal host focus contract", () => {
  test.beforeEach(async ({ page }) => {
    watchPageErrors(page);
    await blockOffsiteRequests(page);
    await page.goto("/lab/modal_host");
  });

  const dialog = (page) => page.locator('[role="dialog"]');

  // Assert focus is inside the dialog, then walk BACKWARD and assert it stays. The
  // failure message names what it landed on, because "a background button" and "the
  // body" are different bugs.
  const staysTrapped = async (page, presses, label) => {
    await expect
      .poll(() => page.evaluate(() => {
        const d = document.querySelector('[role="dialog"]');
        return !!(d && d.contains(document.activeElement));
      }), { message: `focus fell out of the dialog after ${label} — the trap released` })
      .toBe(true);

    for (let i = 0; i < presses; i++) {
      await page.keyboard.press("Shift+Tab");
      const where = await page.evaluate(() => {
        const d = document.querySelector('[role="dialog"]');
        return {
          inside: !!(d && d.contains(document.activeElement)),
          landedOn: document.activeElement?.getAttribute("data-test") || document.activeElement?.tagName
        };
      });
      expect(
        where.inside,
        `focus escaped the dialog on Shift+Tab #${i + 1} after ${label} — landed on ${where.landedOn}`
      ).toBe(true);
    }
  };

  test("opening the first modal moves focus off the background page", async ({ page }) => {
    const opener = page.locator('[data-test="open-first"]');
    await opener.focus();
    await opener.click();
    await expect(dialog(page)).toBeVisible();

    await staysTrapped(page, 3, "the first open");
  });

  test("the trap survives a PLAIN STACKED PUSH onto a non-empty stack", async ({ page }) => {
    await page.locator('[data-test="open-first"]').click();
    await expect(dialog(page)).toBeVisible();
    // Tab onto a control INSIDE the card the push is about to unmount. Landing the
    // push on the backdrop itself does not reproduce it.
    await page.keyboard.press("Tab");

    // Via the store, not the button: the backdrop is `fixed inset-0`, so with a
    // dialog already open the background button is covered and Playwright's
    // actionability check refuses the click. The push is what is under test, not
    // the button.
    await page.evaluate(() => window.Alpine.store("modals").open("lab-second", { title: "Second card" }));
    await expect(dialog(page)).toBeVisible();
    await expect
      .poll(() => page.evaluate(() => window.Alpine.store("modals").stack.length))
      .toBe(2);

    await staysTrapped(page, 3, "a stacked push");
  });

  test("the trap survives close() DOWN TO a modal underneath", async ({ page }) => {
    await page.locator('[data-test="open-first"]').click();
    await expect(dialog(page)).toBeVisible();
    // Via the store, not the button: the backdrop is `fixed inset-0`, so with a
    // dialog already open the background button is covered and Playwright's
    // actionability check refuses the click. The push is what is under test, not
    // the button.
    await page.evaluate(() => window.Alpine.store("modals").open("lab-second", { title: "Second card" }));
    await expect(dialog(page)).toBeVisible();
    // Tab onto a control INSIDE the card being closed. Without this the focused node
    // is the BACKDROP, which close() does not unmount (the outer template survives a
    // pop down to a non-empty stack) — so focus stays inside by accident and the test
    // passes against a released trap. Verified by mutation: dropping the refocus in
    // close() left this green until the Tab was added.
    await page.keyboard.press("Tab");

    await page.evaluate(() => window.Alpine.store("modals").close());
    // The card underneath must still be up: with an empty stack there is no trap to
    // assert and this test would pass on nothing.
    await expect
      .poll(() => page.evaluate(() => window.Alpine.store("modals").stack.length))
      .toBe(1);
    await expect(dialog(page)).toBeVisible();

    await staysTrapped(page, 3, "closing down to the modal underneath");
  });

  test("the trap survives closeAllDismissible() over a non-dismissible card", async ({ page }) => {
    // The non-dismissible card goes on FIRST so it is the survivor: the filter keeps
    // dismissible: false entries and drops everything above.
    await page.evaluate(() =>
      window.Alpine.store("modals").open("lab-first", { title: "First card", dismissible: false }));
    await expect(dialog(page)).toBeVisible();
    // Via the store, not the button: the backdrop is `fixed inset-0`, so with a
    // dialog already open the background button is covered and Playwright's
    // actionability check refuses the click. The push is what is under test, not
    // the button.
    await page.evaluate(() => window.Alpine.store("modals").open("lab-second", { title: "Second card" }));
    await expect(dialog(page)).toBeVisible();
    await page.keyboard.press("Tab");

    await page.evaluate(() => window.Alpine.store("modals").closeAllDismissible());
    await expect
      .poll(() => page.evaluate(() => window.Alpine.store("modals").stack.length))
      .toBe(1);
    await expect(dialog(page)).toBeVisible();

    await staysTrapped(page, 3, "closeAllDismissible over a non-dismissible card");
  });

  test("the trap survives a swap, on this host too", async ({ page }) => {
    await page.locator('[data-test="open-first"]').click();
    await expect(dialog(page)).toBeVisible();

    await page.evaluate(() => window.Alpine.store("modals").swap("lab-second", { title: "Second card" }));
    await expect(dialog(page)).toBeVisible();

    await staysTrapped(page, 3, "a swap");
  });

  // A whitespace-only title is a truthy string, so it used to pass through
  // dialogLabel's fallback chain and the accessible-name computation then trimmed it
  // to empty — announcing a bare "dialog", the exact outcome that chain exists to
  // prevent. This is the browser's own verdict on the computed name.
  test("a whitespace-only title still announces a real name", async ({ page }) => {
    await page.evaluate(() => window.Alpine.store("modals").open("lab-first", { title: "   " }));
    await expect(dialog(page)).toBeVisible();

    const name = await dialog(page).getAttribute("aria-label");
    expect(name, "a whitespace-only title must fall through to the id").toBeTruthy();
    expect(name.trim().length, `aria-label was ${JSON.stringify(name)}`).toBeGreaterThan(0);
  });
});
