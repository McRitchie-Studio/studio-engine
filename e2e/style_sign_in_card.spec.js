const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The style guide's Auth > Sign in specimen: the engine's standard sign-in
// card (studio/auth/_sign_in_modal) in demo mode, in a browser.
//
// WHAT ONLY A BROWSER CAN SHOW. The String tier (test/views/sign_in_card_test.rb)
// proves the demo markup carries no action and no endpoint. It cannot prove that
// pressing Google and Send sends NOTHING, because send() is JavaScript; nor that
// the link-sent step and the resend cooldown actually play. This file presses
// every button and records every request the page makes.
//
// CONTROL, run against this file: set demo: false on the style guide's
// ds-sign-in template. The demo spec then fails (measured: at the demo note,
// because Google renders as a live form to /auth/google_oauth2).

const AUTH_REQUEST = /\/auth\/|\/magic_link/;

async function openSignIn(page) {
  await page.goto("/lab/style_modals");
  await page.locator("#modals-auth article[role='button']", { hasText: "Sign in" }).click();
  const modal = page.locator("[data-sign-in-modal]");
  await expect(modal).toBeVisible();
  return modal;
}

test("the Sign in specimen opens the standard card: Google, or, email", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  const modal = await openSignIn(page);

  await expect(modal.getByRole("button", { name: "Continue with Google" })).toBeVisible();
  await expect(modal.getByText("or", { exact: true })).toBeVisible();
  await expect(modal.getByLabel("Email")).toBeVisible();
  await expect(modal.getByRole("button", { name: /Email me a sign-in link/ })).toBeDisabled();
  await expect(page.locator("#modals-auth article[role='button']")).toHaveCount(1);
  expect(errors).toEqual([]);
});

test("demo mode: Google and Send post nothing, and the link-sent step plays", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  const modal = await openSignIn(page);

  const authRequests = [];
  page.on("request", (request) => {
    if (AUTH_REQUEST.test(new URL(request.url()).pathname)) authRequests.push(`${request.method()} ${request.url()}`);
  });

  // Google is inert: it says so and goes nowhere.
  await modal.getByRole("button", { name: "Continue with Google" }).click();
  await expect(modal.locator("[data-sign-in-demo-note]")).toContainText("Demo only");
  await expect(page).toHaveURL(/\/lab\/style_modals/);

  // Send flips to the link-sent step with the shared resend footer.
  await modal.getByLabel("Email").fill("pat@example.com");
  await modal.getByRole("button", { name: /Email me a sign-in link/ }).click();
  const sent = modal.locator("[data-sign-in-step='sent']");
  await expect(sent).toBeVisible();
  await expect(sent.getByRole("heading", { name: "Check your email" })).toBeFocused();
  await expect(sent).toContainText("pat@example.com");
  await expect(sent.getByRole("button", { name: /Resend available in \d+s/ })).toBeDisabled();
  await expect(sent.getByRole("button", { name: "Close" })).toBeVisible();

  // The demo cooldown is 5s; once it ends, Resend plays and counts down again.
  await expect(sent.getByRole("button", { name: "Resend link" })).toBeEnabled({ timeout: 8000 });
  await sent.getByRole("button", { name: "Resend link" }).click();
  await expect(sent.getByRole("button", { name: /Resend available in \d+s/ })).toBeVisible({ timeout: 3000 });

  // Back to the email step.
  await sent.getByRole("button", { name: "Use a different email" }).click();
  await expect(modal.locator("[data-sign-in-step='email']")).toBeVisible();
  await expect(modal.getByLabel("Email")).toBeFocused();

  expect(authRequests, "no request may reach /auth or the magic-link endpoint in demo mode").toEqual([]);
  expect(errors).toEqual([]);
});

test("the resend footer's Close closes the guide's modal", async ({ page }) => {
  await blockOffsiteRequests(page);
  const modal = await openSignIn(page);
  await modal.getByLabel("Email").fill("pat@example.com");
  await modal.getByRole("button", { name: /Email me a sign-in link/ }).click();
  await modal.locator("[data-sign-in-step='sent']").getByRole("button", { name: "Close" }).click();
  await expect.poll(() => page.evaluate(() => Alpine.store("dsModals").stack.length)).toBe(0);
});

// ---- Real mode, on a page (/lab/sign_in_card) ----
//
// The spec answers POST /magic_link itself, so it reads exactly what the card
// sends (no link is minted, no mail is sent) and can play the server's 503.

async function answerMagicLink(page, { status, body }) {
  const posts = [];
  await page.route("**/magic_link", (route) => {
    const request = route.request();
    posts.push({ method: request.method(), body: request.postData(), headers: request.headers() });
    return route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });
  });
  return posts;
}

test("real mode posts the email and return_to to /magic_link as JSON, then shows the link-sent step", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  const posts = await answerMagicLink(page, { status: 200, body: { success: true } });
  await page.goto("/lab/sign_in_card");

  const card = page.locator("[data-sign-in-card-page]");
  await expect(card.locator("form[data-sign-in-email-form='live']")).toHaveAttribute("action", "/magic_link");
  await card.getByLabel("Email").fill("pat@example.com");
  await card.getByRole("button", { name: /Email me a sign-in link/ }).click();

  await expect(card.locator("[data-sign-in-step='sent']")).toBeVisible();
  await expect(card.locator("[data-sign-in-step='sent']")).toContainText("pat@example.com");
  // A page card has no modal: the footer's Close is dropped.
  await expect(card.locator("[data-sign-in-step='sent']").getByRole("button", { name: "Close" })).toHaveCount(0);
  await expect(card.getByRole("button", { name: /Resend available in (5\d|60)s/ })).toBeVisible();

  expect(posts).toHaveLength(1);
  expect(posts[0].method).toBe("POST");
  expect(new URLSearchParams(posts[0].body).get("email")).toBe("pat@example.com");
  expect(new URLSearchParams(posts[0].body).get("return_to")).toBe("/lab/after-sign-in");
  expect(posts[0].headers.accept).toBe("application/json");
  expect(posts[0].headers).toHaveProperty("x-csrf-token");
  await expect(page).toHaveURL(/\/lab\/sign_in_card$/);
  expect(errors).toEqual([]);
});

test("real mode shows the server's delivery_failed answer and stays on the email step", async ({ page }) => {
  await blockOffsiteRequests(page);
  await answerMagicLink(page, { status: 503, body: { success: false, error: "delivery_failed", message: "ignored" } });
  await page.goto("/lab/sign_in_card");

  const card = page.locator("[data-sign-in-card-page]");
  await card.getByLabel("Email").fill("pat@example.com");
  await card.getByRole("button", { name: /Email me a sign-in link/ }).click();

  await expect(card.getByRole("alert").filter({ hasText: "We could not send your sign-in email just now" })).toBeVisible();
  await expect(card.locator("[data-sign-in-step='email']")).toBeVisible();
  await expect(card.locator("[data-sign-in-step='sent']")).toBeHidden();
});
