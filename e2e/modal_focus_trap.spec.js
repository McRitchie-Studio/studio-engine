const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The modal host's FOCUS CONTRACT.
//
// WHY THIS CANNOT BE A MARKUP TEST. Every assertion here is about
// document.activeElement — where the browser's focus actually IS — and the
// server's bytes are identical whether focus works or not. A test/views
// assertion can confirm tabindex="-1" and an aria-label are present in the HTML
// and still be green while a keyboard user sits focused behind the overlay.
//
// The measured defect: before this change, document.activeElement after opening
// a modal was still the BACKGROUND page's control. On a dismissible card that is
// merely wrong; on a NON-dismissible one it is a trap, because escape and
// click-outside are deliberately gated off there, so there is no exit at all.
test.describe("modal host focus contract", () => {
  test.beforeEach(async ({ page }) => {
    watchPageErrors(page);
    await blockOffsiteRequests(page);
    await page.goto("/lab/birthday_gate");
  });

  const dialog = (page) => page.locator('[role="dialog"]');

  test("opening a modal moves focus off the background page and into the dialog", async ({ page }) => {
    const opener = page.locator('[data-test="open-birthday-underage"]');
    await opener.focus();

    await expect
      .poll(() => page.evaluate(() => document.activeElement?.getAttribute("data-test")))
      .toBe("open-birthday-underage");

    await opener.click();
    await expect(dialog(page)).toBeVisible();

    // The question is not "is something focused" but "is focus INSIDE the dialog".
    // A background control still holding focus is exactly the bug.
    await expect
      .poll(() => page.evaluate(() => {
        const d = document.querySelector('[role="dialog"]');
        return !!(d && d.contains(document.activeElement));
      }))
      .toBe(true);
  });

  test("the dialog announces a name, not a bare 'dialog'", async ({ page }) => {
    await page.locator('[data-test="open-birthday-underage"]').click();
    await expect(dialog(page)).toBeVisible();

    const name = await dialog(page).getAttribute("aria-label");
    expect(name, "an unnamed dialog announces as just 'dialog' to a screen reader").toBeTruthy();
    expect(name.trim().length).toBeGreaterThan(0);
  });

  test("Tab cycles WITHIN the dialog and never escapes to the page behind", async ({ page }) => {
    await page.locator('[data-test="open-birthday-underage"]').click();
    await expect(dialog(page)).toBeVisible();

    // Ten presses is more than any card's control count, so a leak shows up as
    // focus landing outside rather than as a wrap that happens to look right.
    for (let i = 0; i < 10; i++) {
      await page.keyboard.press("Tab");
      const inside = await page.evaluate(() => {
        const d = document.querySelector('[role="dialog"]');
        return !!(d && d.contains(document.activeElement));
      });
      expect(inside, `focus left the dialog on Tab #${i + 1}`).toBe(true);
    }
  });

  test("a tall card scrolls instead of clipping its own actions away", async ({ page }) => {
    await page.setViewportSize({ width: 420, height: 380 });
    await page.locator('[data-test="open-birthday-underage"]').click();
    await expect(dialog(page)).toBeVisible();

    // The CARD, not the backdrop: the card is what grows with content.
    const card = dialog(page).locator("> div").first();
    const fits = await card.evaluate((el) => {
      const style = getComputedStyle(el);
      return {
        scrollable: style.overflowY === "auto" || style.overflowY === "scroll",
        withinViewport: el.getBoundingClientRect().height <= window.innerHeight
      };
    });

    expect(fits.scrollable, "a card taller than the viewport must scroll").toBe(true);
    expect(fits.withinViewport, "and must not exceed the viewport, or its actions are unreachable").toBe(true);
  });
});
