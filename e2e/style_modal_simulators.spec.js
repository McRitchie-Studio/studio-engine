const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The style guide's two modal SIMULATOR sections — the half of them that
// only exists after a browser has run the page.
//
// WHY THESE NEED A BROWSER AND A STRING TIER CANNOT SUBSTITUTE.
// Both sections were ported out of turf-monster's /admin/modals, and both are
// built by script rather than rendered:
//
//   · the enter/leave controls are GENERATED at load from window.ModalAnimations,
//     so the containers ship EMPTY on purpose. Every server-side assertion about
//     this section is an assertion about four empty <div>s, and they are exactly
//     as empty on a page where the script threw. `test/views/style_guide_modal_
//     simulator_test.rb` asserts the emptiness DELIBERATELY — it is proving the
//     controls are not hard-coded — which means the Ruby tier is structurally
//     incapable of noticing that none ever appeared.
//
//   · the stack demos drive $store.dsModals through timers and advance(). Whether
//     Escape is suppressed on a non-dismissible card, whether holdAtLeast floors
//     a fast operation, and whether close() pops back to the card underneath are
//     all post-interaction DOM states. The markup is identical either way.
//
// THE SHARPEST ONE IS THE THIRD SPEC. The guide's page-scoped store used to carry
// its own hard-coded copy of the animation table while the controls came from the
// registry, so a newly registered key grew a button that resolved back to 'pop' —
// the control said one thing, the card did another, and nothing could report it.
// A String assertion cannot see which keyframe class landed on the card, because
// the class is written by the store at open() time and never appears in the
// response bytes.
test.describe("style guide modal simulators", () => {
  test.beforeEach(async ({ page }) => {
    watchPageErrors(page);
    await blockOffsiteRequests(page);
    await page.goto("/lab/style_modals");
  });

  // The live registry, read from the page rather than assumed. Every count below
  // is derived from this, so adding an animation to the engine moves the expected
  // numbers automatically instead of dating this file.
  const registry = (page) =>
    page.evaluate(() => {
      const r = window.ModalAnimations;
      return r ? { enter: Object.keys(r.enter || {}), exit: Object.keys(r.exit || {}) } : null;
    });

  const stack = (page) =>
    page.evaluate(() => {
      const s = window.Alpine && Alpine.store("dsModals");
      return s ? s.stack.map((e) => ({ id: e.id, state: e.props.state })) : null;
    });

  const cardClass = (page) =>
    page.evaluate(() => {
      const card = document.querySelector('[role="dialog"] > div');
      return card ? card.className : null;
    });

  // THE PROPERTY THE SECTION EXISTS FOR, asserted against the registry the page
  // actually holds. `> 0` is not decoration: the registry is published by
  // studio/modals/_host at LAYOUT level, and if the lab ever stopped mounting it
  // every count here would collapse to a vacuously equal 0 === 0.
  test("the enter/leave controls are generated from the live registry", async ({ page }) => {
    const reg = await registry(page);
    expect(reg, "window.ModalAnimations is not published on this page — the shared host did not render").not.toBeNull();
    expect(reg.enter.length, "the registry declares no enter animations, so every count below would be vacuous").toBeGreaterThan(0);
    expect(reg.exit.length, "the registry declares no exit animations").toBeGreaterThan(0);

    await expect(page.locator("#modal-anim-enter-buttons button")).toHaveCount(reg.enter.length);
    await expect(page.locator("#modal-anim-exit-buttons button")).toHaveCount(reg.exit.length);
    await expect(page.locator("#modal-anim-enter-select option")).toHaveCount(reg.enter.length);
    await expect(page.locator("#modal-anim-exit-select option")).toHaveCount(reg.exit.length);

    // The labels come from the registry KEYS, so a build that invented its own
    // controls would not spell them this way.
    const labels = await page.locator("#modal-anim-enter-buttons button").allInnerTexts();
    for (const key of reg.enter) {
      expect(
        labels.some((l) => l.toLowerCase().startsWith(key.toLowerCase())),
        `no generated control is labelled for the registered enter key "${key}" — got ${JSON.stringify(labels)}`
      ).toBe(true);
    }
  });

  test("a generated control opens the demo card", async ({ page }) => {
    expect(await stack(page), "a modal was already open before the click").toEqual([]);

    await page.locator("#modal-anim-enter-buttons button").first().click();

    await expect
      .poll(() => stack(page), { message: "clicking a generated control opened nothing" })
      .toEqual([{ id: "email-change-pending", state: undefined }]);
    await expect(page.locator('[role="dialog"]')).toBeVisible();
  });

  // THE LATE-BINDING PROPERTY. Registering a key the way a consumer app does must
  // do BOTH things: surface a control, and actually play. Asserting only the first
  // is what let the store's stale copy hide — the button appeared either way.
  //
  // The class name is invented here on purpose. It exists in no stylesheet and no
  // template, so the ONLY way it can reach the card's class list is the store
  // having read this registry entry at open() time.
  test("a newly registered animation both surfaces a control and plays", async ({ page }) => {
    const before = await page.locator("#modal-anim-enter-buttons button").count();

    await page.evaluate(() => {
      window.ModalAnimations.enter.labzoom = { cls: "lab-zoom-in", ms: 500 };
      document.dispatchEvent(new Event("turbo:load"));
    });

    await expect(
      page.locator("#modal-anim-enter-buttons button"),
      "registering an animation did not grow a control — the build is not reading the registry"
    ).toHaveCount(before + 1);

    await page.evaluate(() =>
      Alpine.store("dsModals").open("email-change-pending", {
        currentEmail: "a@b.c",
        newEmail: "d@e.f",
        enterAnim: "labzoom",
      })
    );

    await expect
      .poll(() => cardClass(page), {
        message:
          "the card did not receive the newly registered keyframe class. The store resolved the " +
          "key against a stale local table and fell back to 'pop', so the generated control lies.",
      })
      .toContain("lab-zoom-in");
  });

  // DISMISSIBILITY, WITH ITS OWN CONTROL. The locked half alone would be a
  // negative asserted about a state the page is already in — it would pass on a
  // page where Escape does nothing at all, including a page where Alpine never
  // started. Pressing Escape on a DISMISSIBLE card first proves the key is heard.
  test("Escape closes a dismissible card and is suppressed on a locked one", async ({ page }) => {
    await page.evaluate(() => window.dsModalDemos.dismissible());
    await expect.poll(() => stack(page)).toHaveLength(1);

    await page.keyboard.press("Escape");
    await expect
      .poll(() => stack(page), { message: "Escape did not close a dismissible card — the key is not being heard at all, so the locked case below would be vacuous" })
      .toEqual([]);

    await page.evaluate(() => window.dsModalDemos.processing());
    await expect.poll(() => stack(page)).toHaveLength(1);
    expect(
      await page.evaluate(() => Alpine.store("dsModals").current().props.dismissible),
      "the processing demo did not pass dismissible: false, so this spec proves nothing"
    ).toBe(false);

    await page.keyboard.press("Escape");
    await page.waitForTimeout(600);
    expect(
      await stack(page),
      "Escape closed a dismissible:false card — a pending transaction can be dismissed out from under the user"
    ).toHaveLength(1);
  });

  // holdAtLeast floors the spinner. Asserted as a TRANSITION that has not happened
  // yet and then does, rather than as a state sampled once.
  test("holdAtLeast keeps a fast operation on the spinner, then advances", async ({ page }) => {
    await page.evaluate(() => window.dsModalDemos.fastWithHold());

    await expect.poll(() => stack(page)).toEqual([{ id: "onchain-tx", state: "processing" }]);

    // Still processing well after the underlying "work" finished — the floor.
    await page.waitForTimeout(600);
    expect(
      await page.evaluate(() => Alpine.store("dsModals").current().props.state),
      "the card left the spinner before the hold elapsed — holdAtLeast is not flooring it"
    ).toBe("processing");

    await expect
      .poll(() => page.evaluate(() => Alpine.store("dsModals").current()?.props.state), {
        timeout: 8000,
        message: "the held card never advanced to success",
      })
      .toBe("success");
  });

  test("the stack is LIFO — a second card pushes, close pops back", async ({ page }) => {
    await page.evaluate(() => window.dsModalDemos.stackTwo());

    await expect
      .poll(() => stack(page), { timeout: 8000, message: "the second card never pushed onto the stack" })
      .toHaveLength(2);
    expect(
      await page.evaluate(() => Alpine.store("dsModals").current().id),
      "the newer card is not on top"
    ).toBe("email-change-pending");

    await page.evaluate(() => Alpine.store("dsModals").close());

    await expect
      .poll(() => page.evaluate(() => Alpine.store("dsModals").current()?.id), {
        message: "close() did not pop back to the card underneath",
      })
      .toBe("onchain-tx");
  });

  // The timed demo drives a live card through advance(), which patches props
  // WITHOUT replacing the stack entry, so the specimen's x-data scope survives the
  // transition. A swap() would produce the IDENTICAL visible state by a different
  // mechanism, remounting the card and losing that scope.
  //
  // SO THE ENTRY IS TAGGED, not just observed. A marker written onto the live stack
  // entry survives a props patch and cannot survive a replacement — which is the
  // only way from outside to tell the two apart. Asserting the state alone would
  // pass on either, and "in place" would be an unpinned word in the test's name.
  test("the timed demo advances a live card in place", async ({ page }) => {
    await page.evaluate(() => window.dsModalDemos.processThenError());
    await expect.poll(() => stack(page)).toEqual([{ id: "onchain-tx", state: "processing" }]);

    await page.evaluate(() => {
      Alpine.store("dsModals").current().__labEntryMarker = "same-entry";
    });

    await expect
      .poll(() => stack(page), { timeout: 9000, message: "the processing card never reached the error state" })
      .toEqual([{ id: "onchain-tx", state: "error" }]);

    expect(
      await page.evaluate(() => Alpine.store("dsModals").current().__labEntryMarker),
      "the stack entry was REPLACED rather than patched — the specimen remounted and its x-data scope was lost"
    ).toBe("same-entry");
  });
});
