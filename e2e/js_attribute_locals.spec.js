const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] Host-supplied locals spliced into a JS string literal inside a
// JS-evaluating attribute — as a user experiences them.
//
// WHY THIS LANE AND NOT THE RENDER TEST. test/views/js_attribute_locals_test.rb
// asserts these attributes are structurally whole in the response bytes, which is
// a real claim and still not the one that matters. This component's characteristic
// failure leaves the bytes looking fine: a stray quote closes the JS literal, the
// expression becomes a SyntaxError, and Alpine mounts a silent no-op that still
// renders every element a markup assertion looks for. The card renders, the button
// clicks, and nothing happens.
//
// So this file never reads source. It clicks the real button and listens for what
// the HOST receives.

// THE MOUNT PROBE, and why it does not check _x_dataStack alone.
//
// Alpine stamps _x_dataStack on the root EVEN WHEN the x-data expression throws —
// measured on the first-name card, which reported a two-deep stack while plainly
// dead. So the obvious probe passes happily over a component that never evaluated.
// Reading a real MEMBER off the evaluated object is what separates them: a
// SyntaxError leaves nothing for `startCountdown` to be.
//
// _error_card has no x-data of its own (its handlers ride the page's scope), so the
// probe is only meaningful for the cards that declare one. For the others, the
// dispatch assertion IS the mount proof — a dead handler dispatches nothing.
async function expectSuccessCardIsLive(page, card) {
  await page
    .waitForFunction(
      (selector) => {
        const root = document.querySelector(`${selector} [x-data]`);
        if (!root || !root._x_dataStack) return false;

        const data = root._x_dataStack[0] || {};
        return typeof data.startCountdown === "function";
      },
      card,
      { timeout: 10_000 }
    )
    .catch(() => {
      throw new Error(
        `${card} never evaluated its x-data — startCountdown() is not on the component. ` +
          "The usual cause is an unescaped quote in an interpolated local, which closes " +
          "the attribute and mounts the card as a silent no-op that still renders markup."
      );
    });
}

// Listen for the name the HOST passed. A component that lost a character of it —
// or that never mounted — dispatches something else, or nothing, and this stays null.
async function listenFor(page, eventName) {
  await page.evaluate((name) => {
    window.__heard = null;
    window.addEventListener(name, () => {
      window.__heard = name;
    });
  }, eventName);
}

test.beforeEach(async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/js_attribute_locals");
  await page.waitForFunction(() => Boolean(window.Alpine), null, { timeout: 10_000 });
});

test("a hostile cta_event is the event the host actually receives", async ({ page }) => {
  const errors = watchPageErrors(page);
  const card = '[data-test="success-cta"]';
  const eventName = `it's a "cta"\\event`;

  await expectSuccessCardIsLive(page, card);
  await listenFor(page, eventName);

  await page.locator(`${card} button:has-text("Continue")`).click();

  // THE ASSERTION THAT A DEAD CARD CANNOT PASS. The name only arrives if the JS
  // literal parsed, the value round-tripped through both escapers, and the handler
  // reached $dispatch. No source-level check reaches that far.
  await expect.poll(() => page.evaluate(() => window.__heard)).toBe(eventName);
  expect(errors).toEqual([]);
});

test("a hostile secondary_event is the event the host actually receives", async ({ page }) => {
  // DRIVEN SEPARATELY FROM cta_event. They are two interpolations on two lines, so
  // a repair applied to one is silent about the other.
  const errors = watchPageErrors(page);
  const card = '[data-test="success-secondary"]';
  const eventName = `it's a "secondary"\\event`;

  await expectSuccessCardIsLive(page, card);
  await listenFor(page, eventName);

  await page.locator(`${card} button:has-text("Maybe later")`).click();

  await expect.poll(() => page.evaluate(() => window.__heard)).toBe(eventName);
  expect(errors).toEqual([]);
});

test("the error card's hostile cta_event survives to the host", async ({ page }) => {
  const errors = watchPageErrors(page);
  const card = '[data-test="error-cta"]';
  const eventName = `it's an "error"\\event`;

  await listenFor(page, eventName);
  await page.locator(`${card} button:has-text("Retry")`).click();

  await expect.poll(() => page.evaluate(() => window.__heard)).toBe(eventName);
  expect(errors).toEqual([]);
});

test("the error card's hostile secondary_event survives to the host", async ({ page }) => {
  const errors = watchPageErrors(page);
  const card = '[data-test="error-secondary"]';
  const eventName = `it's an "error secondary"\\event`;

  await listenFor(page, eventName);
  await page.locator(`${card} button:has-text("Close")`).click();

  await expect.poll(() => page.evaluate(() => window.__heard)).toBe(eventName);
  expect(errors).toEqual([]);
});

test("a hostile cluster_param reaches the explorer URL intact", async ({ page }) => {
  // NOT AN EVENT NAME — this local is a literal suffix concatenated inside a :href
  // binding, so what proves it survived is the RESOLVED href. Alpine resolves that
  // binding only if the whole expression parsed, which is the same brick reached a
  // different way: unescaped, the link renders with no href at all.
  const errors = watchPageErrors(page);
  const link = page.locator('[data-test="tx-link"] a');

  await expect(link).toHaveAttribute(
    "href",
    `https://explorer.solana.com/tx/5xSigNature?cluster=it's a "devnet"`
  );
  expect(errors).toEqual([]);
});

test("an ordinary cta_event still fires, so the hostile specs have a control", async ({ page }) => {
  // THE CONTROL. Without it, every spec above would also pass on a page where
  // nothing dispatches anything for some unrelated reason — a broken Alpine build,
  // a lab page that failed to render its buttons. This one fails first, and loudly.
  const errors = watchPageErrors(page);
  const card = '[data-test="ordinary-cta"]';

  await expectSuccessCardIsLive(page, card);
  await listenFor(page, "lab-ordinary-cta");

  await page.locator(`${card} button:has-text("Continue")`).click();

  await expect.poll(() => page.evaluate(() => window.__heard)).toBe("lab-ordinary-cta");
  expect(errors).toEqual([]);
});
