const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// The site identity manager (/admin/link_preview), driven in a browser through
// /lab/site_identity, which renders the engine's own template by name.
//
// WHY THIS FILE EXISTS. The page's response bytes are identical whether its
// program works: the card always renders the SAVED title and description, and
// the Upload button always renders. What the operator relies on is behaviour —
// the card repainting as they type, falling back to what a blank field would
// really send, and the button opening the crop modal — and no String assertion
// can see any of it.

const PAGE = "[data-link-preview-page]";
const CARD_TITLE = "[data-link-preview-card-title]";
const CARD_DESCRIPTION = "[data-link-preview-card-description]";

test.beforeEach(async ({ page }) => {
  await blockOffsiteRequests(page);
});

test("typing a title repaints the card, and a blank one shows the drafted default", async ({ page }) => {
  const pageErrors = watchPageErrors(page);
  await page.goto("/lab/site_identity");

  const title = page.locator(CARD_TITLE);
  await expect(title).toHaveText("Saved title");

  await page.fill('[data-link-preview-input="title"]', "A title typed just now");
  await expect(title).toHaveText("A title typed just now");

  // Blank means "use the draft", so the card must say what a blank save would
  // send — the page's own fallback, not an empty line.
  const fallback = await page.locator(PAGE).getAttribute("data-fallback-title");
  expect(fallback, "the page names its fallback title").toBeTruthy();
  await page.fill('[data-link-preview-input="title"]', "");
  await expect(title).toHaveText(fallback);

  expect(pageErrors).toEqual([]);
});

// THE RACE. The card's controller is registered lazily: its module is one more
// request after the page has loaded, so an operator (or Playwright's fill) can
// type before connect() adds the input listener. That input event is gone, and
// the card kept the saved title while the field held the typed one (CI run
// 42568726367). connect() must paint from the fields as they stand. This holds
// the controller's module back until the title is typed, so the order is fixed.
test("a title typed before the card's controller connects still repaints the card", async ({ page }) => {
  const pageErrors = watchPageErrors(page);
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let asked = false;
  await page.route(/\/studio\/controllers\/link_preview_card_controller(?:-[0-9a-f]+)?\.js(?:\?|$)/, async (route) => {
    asked = true;
    await held;
    await route.continue();
  });

  await page.goto("/lab/site_identity");
  const title = page.locator(CARD_TITLE);
  await expect.poll(() => asked, { message: "the page asks for the card's controller" }).toBe(true);
  await page.fill('[data-link-preview-input="title"]', "Typed before the controller");
  await expect(title, "nothing listens yet, so the card still shows the saved title").toHaveText("Saved title");

  release();
  await expect(page.locator(PAGE)).not.toHaveAttribute("data-studio-controller-failed", /.*/);
  await expect(title).toHaveText("Typed before the controller");

  expect(pageErrors).toEqual([]);
});

// Unfurls show about two lines of description; the card clamps the same way,
// which only a layout engine can measure.
test("a long description repaints the card and is clamped to two lines", async ({ page }) => {
  await page.goto("/lab/site_identity");

  // Under the field's 500-character maxlength, well over two lines of card.
  const long = "Skill-based pick'em contests with transparent payouts. ".repeat(6);
  await page.fill('[data-link-preview-input="description"]', long);

  const description = page.locator(CARD_DESCRIPTION);
  await expect(description).toHaveText(long.trim());

  const lines = await description.evaluate((el) => {
    const lineHeight = parseFloat(getComputedStyle(el).lineHeight);
    return el.getBoundingClientRect().height / lineHeight;
  });
  expect(lines, "the card's description must stop at two lines").toBeLessThanOrEqual(2.05);
});

// THE WIRING. The button's handler lives in imageUploadHost, and the crop modal
// mounts on the page-scoped `linkPreviewModals` store. A page whose modal host
// sits outside an Alpine scope gets a store that opens and a dialog that never
// appears, so this asserts both halves.
test("the upload button opens the crop modal on the page's own store", async ({ page }) => {
  await page.goto("/lab/site_identity");

  await page.locator("[data-link-preview-upload]").click();

  await expect
    .poll(() => page.evaluate(() => window.Alpine.store("linkPreviewModals").current()?.id))
    .toBe("crop-photo");
  await expect(page.locator('[role="dialog"]').first()).toBeVisible();
});

// The card is drawn at the unfurl's own shape, and the page fits a phone.
test("at phone width the card keeps the 1200 by 630 picture and nothing overflows", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 900 });
  await page.goto("/lab/site_identity");

  const ratio = await page.locator("[data-link-preview-card] .lp-card-image").evaluate((el) => {
    const box = el.getBoundingClientRect();
    return box.width / box.height;
  });
  expect(ratio).toBeCloseTo(1200 / 630, 1);

  const [scrollWidth, clientWidth] = await page.evaluate(() => [
    document.documentElement.scrollWidth,
    document.documentElement.clientWidth
  ]);
  expect(scrollWidth, "the page must not scroll sideways on a phone").toBeLessThanOrEqual(clientWidth);
});
