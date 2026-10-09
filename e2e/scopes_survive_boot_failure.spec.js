const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The x-data factories a page binds survive a boot that fails to load.
//
// cropPhotoModal, imageUploadHost, avatarCropperHost, birthdayModal,
// studioBirthdayFields, studioProfileForm and submitFormWithProgress are
// studio/alpine_scopes, which layouts/studio/_head imports by its OWN nonced
// module tag as well as through the boot's graph. Its imports are the modules
// that own the factories, and those import nothing. So when studio/application
// fails to load (a missing digest after a deploy, a network drop, a throw
// elsewhere in its graph) the profile form still saves, the birthday gate still
// submits and the upload host still opens the cropper.
//
// The failure is real: the browser's request for studio/application is
// aborted, both the modulepreload and the import. The CONTROL: delete the
// `javascript_import_module_tag "studio/alpine_scopes"` line from the head and
// every spec here fails, each factory undefined and its page dead.

const BOOT_MODULE = /\/studio\/application(?:-[0-9a-f]+)?\.js(?:\?|$)/;
const FACTORIES = [
  "cropPhotoModal", "imageUploadHost", "avatarCropperHost", "birthdayModal",
  "studioBirthdayFields", "studioProfileForm", "submitFormWithProgress"
];

async function breakTheBoot(page) {
  const aborted = [];
  await page.route((url) => BOOT_MODULE.test(url.pathname + url.search), (route) => {
    aborted.push(route.request().url());
    return route.abort();
  });
  return aborted;
}

async function gotoWithBrokenBoot(page, path) {
  await blockOffsiteRequests(page);
  const aborted = await breakTheBoot(page);
  await page.addInitScript(() => {
    document.addEventListener("alpine:initialized", () => { window.__alpineReady = true; });
  });
  await page.goto(path);
  await page.waitForFunction(() => window.__alpineReady === true);

  // The failure happened: the boot was requested and refused, and none of what
  // only the boot installs is on the page.
  expect(aborted.length, "studio/application was never requested, so nothing failed").toBeGreaterThan(0);
  expect(await page.evaluate(() => typeof window.navCollapse)).toBe("undefined");
}

test("every factory is on the page when studio/application fails to load", async ({ page }) => {
  await gotoWithBrokenBoot(page, "/lab/profile_edit");

  const missing = await page.evaluate(
    (names) => names.filter((name) => typeof window[name] !== "function"), FACTORIES
  );
  expect(missing).toEqual([]);
});

test("the profile form still raises its save controls and discards", async ({ page }) => {
  await gotoWithBrokenBoot(page, "/lab/profile_edit");

  const controls = page.locator('[data-studio-save-controls="card"]');
  await expect(controls).toBeHidden();

  await page.locator('input[name="profile[first_name]"]').fill("Someone Else");
  await expect(controls).toBeVisible();
  await expect(controls.getByRole("button", { name: /Save/ })).toBeEnabled();

  await controls.getByRole("button", { name: /Discard/ }).click();
  await expect(controls).toBeHidden();
  await expect(page.locator('input[name="profile[first_name]"]')).not.toHaveValue("Someone Else");
});

test("the profile's birthday row still renders its three selects and raises the save controls", async ({ page }) => {
  await gotoWithBrokenBoot(page, "/lab/profile_edit");

  const section = page.locator('[data-profile-section="birthday"]');
  await expect(section.locator("select")).toHaveCount(3);
  await expect(page.locator('[data-studio-save-controls="card"]')).toBeHidden();

  await section.locator('select[x-model="month"]').selectOption("4");
  await expect(section.locator('select[x-model="day"] option')).toHaveCount(31);
  await expect(page.locator('[data-studio-save-controls="card"]')).toBeVisible();
});

test("the birthday gate still opens, takes a date and hands a refusal to the age gate", async ({ page }) => {
  await gotoWithBrokenBoot(page, "/lab/birthday_gate");

  await page.locator('[data-test="open-birthday-underage"]').click();
  const confirm = page.getByRole("button", { name: /Confirm & Continue/i });
  await expect(confirm).toBeVisible();

  await page.selectOption('select[x-model="month"]', "6");
  await page.selectOption('select[x-model="day"]', "15");
  await page.selectOption('select[x-model="year"]', "2010");
  await expect(confirm).toBeEnabled();
  await confirm.click();

  await expect(page.getByText(/Easy, Young.un/i)).toBeVisible();
});
