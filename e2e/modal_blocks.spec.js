const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The modal blocks' consumer locals, on the global host
// (/lab/modal_blocks; engine-modal-blocks-carry-consumer).
//
// WHY IN THE BROWSER. The markup is the same whether any of this works: the
// countdown line renders, the close buttons carry their @click, the newsletter
// cards carry their x-data. What the markup cannot contain is the PROGRAM:
// studioModalCountdown ticking and closing its store at zero, a close action
// actually closing, and studioNewsletterModal posting JSON, dispatching its
// event, calling the opener's hook and stepping to the next card. A factory that
// failed to publish leaves every card dead with every markup test green.
test.describe("modal blocks consumer locals", () => {
  test.beforeEach(async ({ page }) => {
    watchPageErrors(page);
    await blockOffsiteRequests(page);
    await page.goto("/lab/modal_blocks");
  });

  const dialog = (page) => page.locator('[role="dialog"]');

  test("the Retry-After countdown counts and auto-closes the modal at zero", async ({ page }) => {
    await page.locator('[data-test="open-rate-limit"]').click();
    const card = page.locator('[data-test="card-rate-limit"]');
    await expect(card).toBeVisible();
    await expect(card).toContainText("You are going a bit fast.");
    await expect(card).toContainText(/Try again in [12]s\./);

    // Two seconds, then the store closes itself: no press.
    await expect(card).toBeHidden({ timeout: 5000 });
    await expect(dialog(page)).toBeHidden();
  });

  test("a long wait reads in minutes, and the close action closes the modal", async ({ page }) => {
    await page.locator('[data-test="open-rate-limit-long"]').click();
    const card = page.locator('[data-test="card-rate-limit"]');
    await expect(card).toContainText("Try again in 10 min.");

    await card.getByRole("button", { name: "Dismiss" }).click();
    await expect(card).toBeHidden();
    await expect(dialog(page)).toBeHidden();
  });

  test("the success card shows the rich message and its CTA closes the modal", async ({ page }) => {
    await page.locator('[data-test="open-email-pending"]').click();
    const card = page.locator('[data-test="card-email-pending"]');
    await expect(card.locator('[data-test="current-email"]')).toHaveText("old@example.com");
    await expect(card.locator('[data-test="new-email"]')).toHaveText("new@example.com");

    await card.getByRole("button", { name: "Got it" }).click();
    await expect(card).toBeHidden();
    await expect(dialog(page)).toBeHidden();
  });

  test("the locked username card's Dismiss closes the modal", async ({ page }) => {
    await page.locator('[data-test="open-username-locked"]').click();
    const card = page.locator('[data-test="card-username-locked"]');
    await expect(card).toContainText("Enter Contest First");
    await card.getByRole("button", { name: "Dismiss" }).click();
    await expect(card).toBeHidden();
  });

  test("the birthday card mounts with its progress pill", async ({ page }) => {
    await page.locator('[data-test="open-birthday-pill"]').click();
    const card = page.locator('[data-test="card-birthday-pill"]');
    await expect(card.locator(".rounded-full.bg-primary")).toHaveCount(2);
    await expect(card.getByRole("button", { name: /Confirm & Continue/ })).toBeVisible();
  });

  test("JSON subscribe posts the address, fires the event and the success hook, and steps to Subscribed!", async ({ page }) => {
    const opener = page.locator('[data-test="open-newsletter-subscribe"]');
    await opener.click();
    await expect(page.getByRole("heading", { name: "Join the newsletter" })).toBeVisible();

    const subscribe = page.getByRole("button", { name: "Subscribe", exact: true });
    // The consent box gates the button.
    await page.getByLabel("Subscribe to the lab newsletter").uncheck();
    await expect(subscribe).toBeDisabled();
    await page.getByLabel("Subscribe to the lab newsletter").check();

    // An address that cannot be one stays on the card, announced.
    await page.locator('input[type="email"][x-model="email"]').fill("pat");
    await subscribe.click();
    await expect(page.getByRole("alert").filter({ hasText: "Enter a valid email address." })).toBeVisible();

    const posted = page.waitForRequest((r) => r.url().endsWith("/lab/modal_blocks/newsletter") && r.method() === "POST");
    await page.locator('input[type="email"][x-model="email"]').fill("pat@example.com");
    await subscribe.click();
    const request = await posted;
    expect(request.headers()["content-type"]).toBe("application/json");
    expect(JSON.parse(request.postData())).toEqual({ email: "pat@example.com" });

    await expect(page.getByRole("heading", { name: "Subscribed!" })).toBeVisible();
    await expect(opener).toHaveAttribute("data-hooked", "25");
    await expect(page.locator("main")).toHaveAttribute("data-changed", "true:pat@example.com");

    // No reload: the page under the modal is the same document.
    await page.getByRole("button", { name: "Close", exact: true }).click();
    await expect(dialog(page)).toBeHidden();
  });

  test("an opener's onSubmit takes the address and nothing is posted", async ({ page }) => {
    let posts = 0;
    page.on("request", (r) => { if (r.url().includes("/lab/modal_blocks/newsletter")) posts += 1; });

    const opener = page.locator('[data-test="open-newsletter-email"]');
    await opener.click();
    await page.locator('input[type="email"][x-model="email"]').fill("wallet@example.com");
    await page.getByRole("button", { name: "Subscribe", exact: true }).click();

    await expect(opener).toHaveAttribute("data-handed", "wallet@example.com");
    await expect(dialog(page)).toBeHidden();
    expect(posts).toBe(0);
  });

  test("JSON unsubscribe confirms without a reload and steps to the goodbye beat", async ({ page }) => {
    await page.evaluate(() => { window.__labDocument = true; });
    await page.locator('[data-test="open-newsletter-unsubscribe"]').click();

    const posted = page.waitForRequest((r) => r.url().endsWith("/lab/modal_blocks/newsletter/leave") && r.method() === "POST");
    await page.getByRole("button", { name: "Unsubscribe", exact: true }).click();
    await posted;

    await expect(page.getByRole("heading", { name: "See you later" })).toBeVisible();
    await expect(page.locator("main")).toHaveAttribute("data-changed", "false:");
    expect(await page.evaluate(() => window.__labDocument)).toBe(true);

    await page.getByRole("button", { name: "Close", exact: true }).click();
    await expect(dialog(page)).toBeHidden();
  });
});
