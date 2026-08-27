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
    // 300, not the 380 this test used to run at. MEASURED on the lab card: at 420x380
    // its max-height resolves to 323px and its content is 288px, so the card FITS and
    // never scrolls — the two original assertions (overflow-y is auto, height is under
    // the viewport) are exactly what a SHORT card looks like, so this test was green
    // against the case it exists to exclude. At 420x300 the max-height resolves to
    // 255px against the same 288px of content: scrollHeight 288 > clientHeight 253, a
    // 35px overflow, which is the condition being asserted. The third assertion below
    // is what makes that reproduction mandatory rather than incidental.
    await page.setViewportSize({ width: 420, height: 300 });
    await page.locator('[data-test="open-birthday-underage"]').click();
    await expect(dialog(page)).toBeVisible();

    // The CARD, not the backdrop: the card is what grows with content.
    const card = dialog(page).locator("> div").first();
    const fits = await card.evaluate((el) => {
      const style = getComputedStyle(el);
      return {
        scrollable: style.overflowY === "auto" || style.overflowY === "scroll",
        withinViewport: el.getBoundingClientRect().height <= window.innerHeight,
        actuallyOverflows: el.scrollHeight > el.clientHeight
      };
    });

    expect(fits.scrollable, "a card taller than the viewport must scroll").toBe(true);
    expect(fits.withinViewport, "and must not exceed the viewport, or its actions are unreachable").toBe(true);
    // WITHOUT THIS the test is green on a card that never scrolls at all. `overflow-y:
    // auto` plus a height under the viewport is exactly what a SHORT card looks like,
    // so the two assertions above are satisfied by the case they were written to
    // exclude. scrollHeight > clientHeight is the only one of the three that says the
    // content is genuinely taller than the box holding it — i.e. that the clipping
    // this test is about was actually reproduced at this viewport.
    expect(
      fits.actuallyOverflows,
      "the card did not overflow at 420x300, so the two assertions above proved nothing " +
        "about clipping — shrink the viewport or lengthen the card"
    ).toBe(true);
  });

  // THE REPRODUCING TIER, and the reason this file needed a fourth test.
  //
  // The trap held on OPEN and released on SWAP. captureFocus runs from x-init on
  // the backdrop, and a swap keeps current() truthy, so the outer template never
  // re-mounts and x-init never re-runs. The INNER content template does re-mount
  // and unmounts whatever was focused; activeElement falls back to <body>, which
  // is not inside the backdrop, so the tab handler bound there stops firing and
  // native tabbing resumes.
  //
  // WHY THE EXISTING TAB TEST STAYED GREEN THROUGH IT — worth stating, because it
  // passed for the wrong reason rather than by luck. It presses Tab FORWARD only,
  // and Chrome parks the sequential-focus-navigation starting point where the
  // removed node was, so forward Tab happens to land back inside. SHIFT+Tab walks
  // the other way and leaves. The reproducing shape is: open -> swap -> Shift+Tab.
  test("the trap SURVIVES a swap — Shift+Tab after swapping stays in the dialog", async ({ page }) => {
    await page.locator('[data-test="open-birthday-underage"]').click();
    await expect(dialog(page)).toBeVisible();

    // Tab onto a control INSIDE the card the swap is about to unmount. Without this
    // the focused node is the BACKDROP, which a swap does NOT unmount, so focus stays
    // inside by accident and every assertion below passes against a released trap.
    await page.keyboard.press("Tab");

    // Swap the top entry the way the app does. current() stays truthy across
    // this, which is precisely why x-init does not re-run.
    await page.evaluate(() => window.Alpine.store("labModals").swap("age-gate"));
    await expect(dialog(page)).toBeVisible();

    // The focused node must be back inside the dialog before any key is pressed.
    // If this is <body>, the handler below is not bound to anything reachable and
    // every assertion after it is meaningless.
    await expect
      .poll(() => page.evaluate(() => {
        const d = document.querySelector('[role="dialog"]');
        return !!(d && d.contains(document.activeElement));
      }), { message: "focus fell out of the dialog on swap — the trap released" })
      .toBe(true);

    // BACKWARD, three presses. Measured on the broken build, this walked
    // navlink -> opener -> the background page composer.
    for (let i = 0; i < 3; i++) {
      await page.keyboard.press("Shift+Tab");
      const inside = await page.evaluate(() => {
        const d = document.querySelector('[role="dialog"]');
        return !!(d && d.contains(document.activeElement));
      });
      expect(inside, `focus escaped the dialog on Shift+Tab #${i + 1} after a swap`).toBe(true);
    }
  });
  // THE THREE SEAMS A SWAP DOES NOT COVER.
  //
  // The swap test above closed the seam it was written for, and its own reasoning
  // named the mechanism exactly: the trap holds only while the OUTER template
  // re-mounts, because that is what re-runs x-init -> captureFocus. A swap keeps
  // current() truthy, so it needed an explicit refocus(). So does EVERY other way
  // the top entry can change without the outer template re-mounting — and there
  // are three, all measured in Chromium:
  //
  //   1. a PLAIN STACKED PUSH   — open() with no replace onto a NON-EMPTY stack
  //   2. close() DOWN TO a modal underneath
  //   3. closeAllDismissible() with a NON-DISMISSIBLE card underneath
  //
  // The host's own comment claimed the first was safe ("a fresh push takes
  // current() falsy -> truthy, so the outer template mounts"). True only when the
  // stack was EMPTY, and silently false for a stacked push.
  //
  // EVERY ONE OF THESE USES Shift+Tab, and that is not a stylistic choice. Chrome
  // parks the sequential-focus-navigation starting point where the removed node
  // was, so FORWARD Tab lands back inside by accident and passes against a
  // released trap. Backward walks the other way and leaves. A forward-only version
  // of these tests would be green on the broken build.

  // Assert focus is inside the dialog, then walk BACKWARD and assert it stays.
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

  test("the trap survives a PLAIN STACKED PUSH onto a non-empty stack", async ({ page }) => {
    await page.locator('[data-test="open-birthday-underage"]').click();
    await expect(dialog(page)).toBeVisible();
    // Tab once first, so focus is on a control INSIDE the card that the push will
    // unmount. Landing the push on the backdrop itself would not reproduce it.
    await page.keyboard.press("Tab");

    // A second card pushed on top — no replace. Measured on the broken build:
    // activeElement BODY, then Shift+Tab x3 walked onto three background buttons
    // behind a still-open dialog.
    await page.evaluate(() => window.Alpine.store("labModals").open("age-gate", {
      minAge: 21, state: "CA", dobYear: new Date().getFullYear() - 16, dobMonth: 6, dobDay: 15
    }));
    await expect(dialog(page)).toBeVisible();

    await staysTrapped(page, 3, "a stacked push");
  });

  test("the trap survives close() DOWN TO a modal underneath", async ({ page }) => {
    await page.locator('[data-test="open-birthday-underage"]').click();
    await expect(dialog(page)).toBeVisible();
    await page.evaluate(() => window.Alpine.store("labModals").open("age-gate", {
      minAge: 21, state: "CA", dobYear: new Date().getFullYear() - 16, dobMonth: 6, dobDay: 15
    }));
    await expect(dialog(page)).toBeVisible();
    // Tab onto a control INSIDE the card being closed. Without this the focused node
    // is the BACKDROP, which close() does not unmount (the outer template survives a
    // pop down to a non-empty stack) — so focus stays inside by accident and the test
    // passes against a released trap. Verified by mutation on the sibling spec.
    await page.keyboard.press("Tab");

    // Close the TOP one. releaseFocus() is correctly gated on an empty stack, but
    // nothing called refocus() for the entry left underneath, so focus sat on
    // <body> with that dialog still open.
    await page.evaluate(() => window.Alpine.store("labModals").close());
    await expect(dialog(page)).toBeVisible();
    // The card underneath must still be up — if the stack emptied, this test would
    // be asserting the trap on a dialog that is not there.
    await expect
      .poll(() => page.evaluate(() => window.Alpine.store("labModals").stack.length))
      .toBe(1);

    await staysTrapped(page, 3, "closing down to the modal underneath");
  });

  test("the trap survives closeAllDismissible() over a non-dismissible card", async ({ page }) => {
    // The non-dismissible card goes on FIRST so it is the survivor: the filter keeps
    // dismissible: false entries and drops everything above it.
    await page.evaluate(() => window.Alpine.store("labModals").open("age-gate", {
      dismissible: false,
      minAge: 21, state: "CA", dobYear: new Date().getFullYear() - 16, dobMonth: 6, dobDay: 15
    }));
    await expect(dialog(page)).toBeVisible();
    await page.evaluate(() => window.Alpine.store("labModals").open("birthday-underage", {}));
    await expect(dialog(page)).toBeVisible();
    await page.keyboard.press("Tab");

    await page.evaluate(() => window.Alpine.store("labModals").closeAllDismissible());
    // Exactly the non-dismissible one survives. This is the precondition the whole
    // test rests on: with an empty stack there is no trap to assert.
    await expect
      .poll(() => page.evaluate(() => window.Alpine.store("labModals").stack.length))
      .toBe(1);
    await expect(dialog(page)).toBeVisible();

    await staysTrapped(page, 3, "closeAllDismissible over a non-dismissible card");
  });

  // The whitespace-only title. `title: '   '` is a truthy string, so it passed
  // through dialogLabel's fallback chain and the accessible-name computation then
  // trimmed it to empty — announcing a bare "dialog", the outcome that chain
  // exists to prevent. The empty-string rungs are covered at the unit tier
  // (test/lib/modal_dialog_label_test.rb); this is the browser's own verdict on
  // the computed name.
  test("a whitespace-only title still announces a real name", async ({ page }) => {
    await page.evaluate(() => window.Alpine.store("labModals").open("birthday-underage", { title: "   " }));
    await expect(dialog(page)).toBeVisible();

    const name = await dialog(page).getAttribute("aria-label");
    expect(name, "a whitespace-only title must fall through to the id").toBeTruthy();
    expect(name.trim().length, `aria-label was ${JSON.stringify(name)}`).toBeGreaterThan(0);
  });
});
