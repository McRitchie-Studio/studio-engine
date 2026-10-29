const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The Google button on an app with no OAuth client yet opens the setup
// modal (studio/google_sign_in/_button, Studio::GoogleSignIn).
//
// WHY A BROWSER. The integration suite proves the markup: a type=button opener
// whose @click names $store.googleSetupModals.open('google-setup'), and a
// template registering that id. That markup is byte-identical whether or not the
// scoped host's store registers, whether or not an Alpine scope sits above the
// host (without one it opens and renders NOTHING: studio/profiles/show), and
// whether or not the id matches. Only a browser can say the dialog appeared.
//
// The lab boots with no GOOGLE_CLIENT_ID, which is exactly the new-app state.

test("the Google button opens the setup modal while the app has no OAuth client", async ({ page }) => {
  const pageErrors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.goto("/login");

  // Nothing open yet, so what follows is a TRANSITION.
  await expect(page.getByText("Google sign-in is still being set up")).toHaveCount(0);

  await page.getByRole("button", { name: "Sign in with Google" }).click();

  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByText("Google sign-in is still being set up"),
    "the setup modal never opened: the store, the host's Alpine scope or the modal id is wrong"
  ).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Request Google setup" })).toBeVisible();
  await expect(dialog.locator("form[action='/_studio/google_setup_request'][method='post']")).toHaveCount(1);

  expect(pageErrors, `the page threw: ${pageErrors.join(" | ")}`).toEqual([]);
});

test("Use email instead closes the modal and hands focus to the email field", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/login");

  await page.getByRole("button", { name: "Sign in with Google" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();

  await dialog.getByRole("button", { name: "Use email instead" }).click();

  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.locator("input[type=email]")).toBeFocused();
});
