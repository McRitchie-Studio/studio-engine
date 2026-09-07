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

// THE MOUNT PROBE, and why the specs are not allowed to go without it. A DEAD card
// shows no error either, so "the alert never appeared" is the same observation as
// "the copy is wrong" unless something separates them first.
//
// IT ASSERTS THE EVALUATED DATA, NOT THE PRESENCE OF _x_dataStack, and that
// distinction was measured rather than assumed. Alpine stamps _x_dataStack on the
// root even when the x-data expression THROWS, so the obvious probe passes happily
// over a component that never evaluated — checked by deleting the escaping and
// watching the stack-only version stay green while the card was plainly dead.
// Reading a method OFF the evaluated object is the check that actually separates
// them: a SyntaxError leaves nothing for `save` to be.
async function expectCardIsLive(page, card) {
  await page
    .waitForFunction(
      (selector) => {
        const root = document.querySelector(`${selector} [x-data]`);
        if (!root || !root._x_dataStack) return false;

        const data = root._x_dataStack[0] || {};
        return typeof data.save === "function";
      },
      card,
      { timeout: 10_000 }
    )
    .catch(() => {
      throw new Error(
        `${card} never evaluated its x-data — save() is not on the component. The usual ` +
          "cause is an unescaped quote in an interpolated local, which closes the " +
          "attribute and mounts the card as a silent no-op that still renders markup."
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

// --- THE REST OF THE x-data's LOCALS ----------------------------------------
//
// empty_error above is the local that TAUGHT this file the hazard. It was never the
// only one inside that attribute: submit_path, skip_path and done_event each sit in
// a JS single-quoted literal exactly as it does, and modal_store sits in IDENTIFIER
// position — the same silent brick, a different repair.
//
// EACH SPEC DRIVES ONE LOCAL, and that is the point rather than tidiness. The three
// string locals are three separate interpolations on three separate lines, so a
// repair applied to one is silent about the other two; a single card carrying all
// three hostile values would go green the moment ANY of them was fixed.
//
// AND EACH ONE ASSERTS THE CARD WORKED, not that the markup looks right. The value
// has to arrive at a fetch, or at a dispatched event, or at the named store —
// somewhere on the far side of the JS parser. That is the only assertion a dead
// card cannot pass, and a dead card is what this whole file exists to catch.

// The HOST's half, played by the spec.
//
// A store is not a local, so the lab page may not set one up — its rule is locals
// and nothing else. Installing it here is also what lets these specs assert WHICH
// store the card reached, which is the entire question modal_store asks.
async function installStores(page, names) {
  await page.evaluate((storeNames) => {
    window.__closedStores = [];
    storeNames.forEach((name) => {
      window.Alpine.store(name, {
        current() {
          return { props: { marker: name } };
        },
        close() {
          window.__closedStores.push(name);
        }
      });
    });
  }, names);
}

// Answer the card's POST the way both endpoints are contracted to, and record the
// URL it actually requested.
//
// THAT URL IS THE PROOF. It can only carry the host's path if the JS literal parsed,
// the value round-tripped through the escaping, and the component reached its fetch.
// No source-level assertion reaches that far, and no dead card produces it.
//
// Registered AFTER blockOffsiteRequests (the beforeEach), because Playwright matches
// route handlers in reverse registration order — the `**/*` catch-all would
// otherwise answer these first.
async function capturePosts(page) {
  const requested = [];

  await page.route("**/lab/echo*", async (route) => {
    requested.push(route.request().url());
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ ok: true, next: [] })
    });
  });

  return requested;
}

test("a hostile submit_path reaches the server as the host wrote it", async ({ page }) => {
  const errors = watchPageErrors(page);
  const card = '[data-test="hostile-submit-card"]';

  await installStores(page, ["modals"]);
  const requested = await capturePosts(page);
  await expectCardIsLive(page, card);

  await page.locator(`${card} input[type="text"]`).fill("Sam");
  await page.locator(`${card} button[type="submit"]`).click();

  await expect.poll(() => requested.length).toBe(1);
  expect(decodeURIComponent(requested[0])).toContain(`first=it's a "quote"`);

  // AND IT FINISHED. The save's whole far side — the ok response, finish(), the
  // dispatch, the close — runs only if the component evaluated.
  await expect.poll(() => page.evaluate(() => window.__closedStores)).toEqual(["modals"]);
  expect(errors).toEqual([]);
});

test("a hostile skip_path reaches the server as the host wrote it", async ({ page }) => {
  const errors = watchPageErrors(page);
  const card = '[data-test="hostile-skip-card"]';

  await installStores(page, ["modals"]);
  const requested = await capturePosts(page);
  await expectCardIsLive(page, card);

  await page.locator(`${card} button:has-text("Skip for now")`).click();

  await expect.poll(() => requested.length).toBe(1);
  expect(decodeURIComponent(requested[0])).toContain(`skip=it's a "quote"`);
  await expect.poll(() => page.evaluate(() => window.__closedStores)).toEqual(["modals"]);
  expect(errors).toEqual([]);
});

test("a hostile done_event is the event the host actually receives", async ({ page }) => {
  const errors = watchPageErrors(page);
  const card = '[data-test="hostile-event-card"]';
  const eventName = `it's a "done"\\event`;

  await installStores(page, ["modals"]);
  await capturePosts(page);
  await expectCardIsLive(page, card);

  // Listen for the name the HOST passed. A card that lost a character of it — or
  // that never mounted — dispatches something else, or nothing, and this stays null.
  await page.evaluate((name) => {
    window.__doneDetail = null;
    window.addEventListener(name, (event) => {
      window.__doneDetail = event.detail;
    });
  }, eventName);

  await page.locator(`${card} button:has-text("Skip for now")`).click();

  await expect.poll(() => page.evaluate(() => window.__doneDetail)).toEqual({ next: [], saved: false });
  expect(errors).toEqual([]);
});

test("a host's own store name is reached at BOTH of the x-data's splices", async ({ page }) => {
  // modal_store is spliced in as a bare NAME, so a hostile value never reaches a
  // browser — the partial refuses it at render, and the view test owns that half.
  // What only a browser can show is this half: that a host's identifier arrives
  // VERBATIM and the card really talks to THAT store. Escaping it would have made
  // both assertions below fail on a card that still rendered perfectly.
  const errors = watchPageErrors(page);
  const card = '[data-test="custom-store-card"]';

  await installStores(page, ["labModals"]);
  await capturePosts(page);
  await expectCardIsLive(page, card);

  // Site one: the props getter, `$store.<name>.current()`.
  const props = await page.evaluate((selector) => {
    const root = document.querySelector(`${selector} [x-data]`);
    return root._x_dataStack[0].props;
  }, card);
  expect(props).toEqual({ marker: "labModals" });

  // Site two: finish()'s `$store.<name>.close()`.
  await page.locator(`${card} button:has-text("Skip for now")`).click();
  await expect.poll(() => page.evaluate(() => window.__closedStores)).toEqual(["labModals"]);

  expect(errors).toEqual([]);
});

test("the required card's × closes the host's store, through the third splice", async ({ page }) => {
  // THE SITE THAT IS EASY TO MISS. dismiss_action is assembled in RUBY —
  // "$store.#{modal_store}.close()" — and emitted into @click, which evaluates JS
  // like x-data does. It is a third splice of the same local, in a second attribute,
  // and it is covered because the guard validates the SOURCE rather than each splice.
  const errors = watchPageErrors(page);
  const card = '[data-test="custom-store-required-card"]';

  await installStores(page, ["labModals"]);
  await expectCardIsLive(page, card);

  await page.locator(`${card} button[aria-label="Close"]`).click();

  await expect.poll(() => page.evaluate(() => window.__closedStores)).toEqual(["labModals"]);
  expect(errors).toEqual([]);
});
