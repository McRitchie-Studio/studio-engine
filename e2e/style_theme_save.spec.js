const { test, expect } = require("@playwright/test");

// [e2e] The style guide's Theme section saves in place, against the real
// /admin/theme and the real admin gate.
//
// The Save toast is the only word the operator gets, and the page looks the
// same whether the theme was written or the request was turned away. Each spec
// reads the toast, counts the PATCHes, and then reads the theme back from the
// server.
//
// CONTROLS, each run against this file:
//   - saved() accepting an opaque redirect again: the third spec fails,
//     toasting "Theme saved" over a theme that was never written.
//   - formRequest() dropping the Accept header: all three fail, the admin's
//     own save answered 302 and toasted as a failure.

const LAB = "/lab/style_theme";
const primary = (page) => page.locator('input[name="theme_setting[primary]"]');
const toastTitles = (page) => page.locator("#toast-container [x-text='toast.title']").allTextContents();

const isSave = (request) => request.method() === "PATCH" && new URL(request.url()).pathname === "/admin/theme";

// Every PATCH to /admin/theme the page sends, and the statuses the browser
// reports for them. An unfollowed redirect is sent and reports no status.
function watchSaves(page) {
  const saves = { sent: 0, statuses: [] };
  page.on("request", (request) => { if (isSave(request)) saves.sent += 1; });
  page.on("response", (response) => { if (isSave(response.request())) saves.statuses.push(response.status()); });
  return saves;
}

async function signIn(page) {
  await page.goto(`/survey_lab/sign_in?to=${LAB}`);
  await expect(primary(page)).toBeVisible();
}

async function saveColor(page, color) {
  await primary(page).fill(color);
  await page.getByRole("button", { name: "Save theme" }).click();
}

// The colour the server holds, read from a fresh render as the admin.
async function storedPrimary(page) {
  await signIn(page);
  return primary(page).inputValue();
}

test("an admin's save is answered 204, toasts Theme saved, and is written", async ({ page }) => {
  await signIn(page);
  const saves = watchSaves(page);

  await saveColor(page, "#123456");

  await expect.poll(() => toastTitles(page)).toEqual(["Theme saved"]);
  expect(saves).toEqual({ sent: 1, statuses: [204] });
  expect(await storedPrimary(page)).toBe("#123456");
});

test("a save after the session ended toasts a failure and writes nothing", async ({ page }) => {
  await signIn(page);
  await saveColor(page, "#222222");
  await expect.poll(() => toastTitles(page)).toEqual(["Theme saved"]);

  await page.reload();
  const saves = watchSaves(page);
  await page.context().clearCookies();
  await saveColor(page, "#abcdef");

  await expect.poll(() => toastTitles(page)).toEqual(["Save failed"]);
  expect(saves).toEqual({ sent: 1, statuses: [401] });
  expect(await storedPrimary(page)).toBe("#222222");
});

// The sign-in bounce as a redirect: the request a fetch sends when it names no
// format. The browser reports the 302 as an opaque redirect and follows nothing.
test("a save bounced to sign-in by a redirect toasts a failure and sends one PATCH", async ({ page }) => {
  await signIn(page);
  await saveColor(page, "#333333");
  await expect.poll(() => toastTitles(page)).toEqual(["Theme saved"]);

  await page.reload();
  const saves = watchSaves(page);
  const visits = [];
  page.on("request", (request) => visits.push(new URL(request.url()).pathname));
  await page.route("**/admin/theme", (route) =>
    route.continue({ headers: { ...route.request().headers(), accept: "*/*" } })
  );
  await page.context().clearCookies();
  await saveColor(page, "#fedcba");

  await expect.poll(() => toastTitles(page)).toEqual(["Save failed"]);
  expect(saves.sent).toBe(1);
  expect(visits).not.toContain("/login");
  await page.unroute("**/admin/theme");

  // What the server answered that request: the redirect to sign in.
  const bounce = await page.request.patch("/admin/theme", { headers: { accept: "*/*" }, maxRedirects: 0 });
  expect(bounce.status()).toBe(302);
  expect(bounce.headers().location).toMatch(/\/login$/);
  expect(await storedPrimary(page)).toBe("#333333");
});
