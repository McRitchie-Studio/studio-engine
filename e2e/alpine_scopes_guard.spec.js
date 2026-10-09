const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The x-data factories' guard (studio/_alpine_scopes_guard, inline in the
// head).
//
// The profile form, the birthday card and the upload hosts bind an x-data
// factory by name, and all six names come from studio/alpine_scopes and the
// four modules it imports. A browser keeps a failed module request for the
// life of the document, so ONE failure among those five at page load leaves
// every name undefined: the profile page with no Save anywhere and its fields
// blank, the birthday card with nothing that answers a press. The guard marks
// each such element data-studio-scope-failed, puts "This did not load. Reload
// the page." first inside it, shows the profile form's plain Save and puts the
// server's values back in the fields Alpine emptied, so a person can still
// save.
//
// Each failure here is real: the browser's request for one module is aborted,
// or answered 404, as the page loads. /lab/profile_edit and /lab/birthday_gate
// are the pages the profile and birthday specs use.
//
// CONTROLS, each run against this file:
//   - drop `render "studio/alpine_scopes_guard"` from layouts/studio/_head:
//     the twenty failed-module specs fail at the mark.
//   - drop the guard's fallback loop (the `[data-studio-scope-fallback]` each):
//     the ten profile specs fail at the plain Save, which stays hidden.
//   - drop the guard's sweep after an insertion (the observer's
//     `setTimeout(sweep, SETTLE_MS)`): the ten birthday specs fail, the card a
//     modal mounts later never marked.
//   - mark with no grace and no boot (GRACE_MS 0, booted() as the script
//     runs): the slow-boot spec fails, its page marked while its modules load.
//   - drop the guard's restore of a field's server value: the ten profile
//     specs fail, First name blank under a Save that would send the blank.

const MODULES = {
  "studio/alpine_scopes": /\/studio\/alpine_scopes(?:-[0-9a-f]+)?\.js(?:\?|$)/,
  "studio/cropper": /\/studio\/cropper(?:-[0-9a-f]+)?\.js(?:\?|$)/,
  "studio/image_upload": /\/studio\/image_upload(?:-[0-9a-f]+)?\.js(?:\?|$)/,
  "studio/birthday": /\/studio\/birthday(?:-[0-9a-f]+)?\.js(?:\?|$)/,
  "studio/profile_form": /\/studio\/profile_form(?:-[0-9a-f]+)?\.js(?:\?|$)/,
};
const ANY_MODULE = (url) => Object.values(MODULES).some((pattern) => pattern.test(url));
const FACTORIES = ["cropPhotoModal", "imageUploadHost", "avatarCropperHost", "birthdayModal", "studioBirthdayFields", "studioProfileForm"];
const NOTICE = "This did not load. Reload the page.";
const GRACE_MS = 1500;

const abort = (route) => route.abort();
const notFound = (route) => route.fulfill({ status: 404, contentType: "text/plain", body: "Not Found" });

const scope = (page, name) => page.locator(`[x-data^="${name}("]`).first();
const notice = (page, name) => scope(page, name).locator("> .studio-scope-notice");
const plainSave = (page) => page.locator("[data-studio-scope-fallback] button[type='submit']");
const firstName = (page) => page.locator('input[name="profile[first_name]"]');
const cardControls = (page) => page.locator('[data-studio-save-controls="card"]');

// Before any page script: remember every element that was EVER marked, so a
// mark that came and went between two reads still fails a spec that says there
// was none.
async function instrument(page) {
  await page.addInitScript(() => {
    window.__everMarked = [];
    new MutationObserver((records) => {
      for (const record of records) {
        if (record.attributeName !== "data-studio-scope-failed") continue;
        if (record.target.hasAttribute("data-studio-scope-failed")) {
          window.__everMarked.push(record.target.getAttribute("data-studio-scope-failed"));
        }
      }
    }).observe(document, { attributes: true, subtree: true });
  });
}

const missing = (page) => page.evaluate((names) => names.filter((name) => typeof window[name] !== "function"), FACTORIES);

// WCAG contrast of an element's text against the first opaque background
// behind it.
function contrast(locator) {
  return locator.evaluate((element) => {
    const parse = (value) => (value.match(/[\d.]+/g) || []).map(Number);
    const luminance = ([r, g, b]) => {
      const [x, y, z] = [r, g, b].map((channel) => {
        const c = channel / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
      });
      return 0.2126 * x + 0.7152 * y + 0.0722 * z;
    };
    let surface = null;
    for (let node = element; node && !surface; node = node.parentElement) {
      const background = parse(getComputedStyle(node).backgroundColor);
      if (background.length >= 3 && (background.length === 3 || background[3] > 0.99)) surface = background;
    }
    const text = luminance(parse(getComputedStyle(element).color));
    const behind = luminance(surface || [255, 255, 255]);
    return (Math.max(text, behind) + 0.05) / (Math.min(text, behind) + 0.05);
  });
}

async function expectSaysSo(page, name) {
  await expect(scope(page, name)).toHaveAttribute("data-studio-scope-failed", name, { timeout: GRACE_MS + 4000 });
  await expect(notice(page, name)).toBeVisible();
  await expect(notice(page, name)).toHaveText(NOTICE);
  await expect(notice(page, name)).toHaveAttribute("role", "status");

  // Legible in both themes. The lab is dark; light needs the class taken off.
  for (const theme of ["dark", "light"]) {
    await page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), theme === "dark");
    expect(await contrast(notice(page, name)), `${theme} notice contrast`).toBeGreaterThanOrEqual(4.5);
    expect((await notice(page, name).boundingBox()).height, theme).toBeGreaterThan(12);
  }
  await page.evaluate(() => document.documentElement.classList.add("dark"));
}

async function failOne(page, name, fail) {
  await blockOffsiteRequests(page);
  await instrument(page);
  const refused = [];
  await page.route((url) => MODULES[name].test(url.pathname + url.search), (route) => {
    refused.push(route.request().url());
    return fail(route);
  });
  const reports = [];
  page.on("console", (message) => {
    if (message.type() === "error" && message.text().includes("x-data factories failed to load")) reports.push(message.text());
  });
  return { refused, reports };
}

async function healAndReload(page) {
  await page.unrouteAll({ behavior: "wait" });
  await blockOffsiteRequests(page);
  await page.reload();
  await page.waitForFunction(() => !!(window.Alpine && window.Alpine.version));
  expect(await missing(page)).toEqual([]);
}

// One module fails at page load on the profile edit page. Every scope on it
// says so, the plain Save is there and sends what the server rendered, and a
// reload recovers.
async function profileSaysSoAndStillSaves(page, name, fail) {
  const { refused, reports } = await failOne(page, name, fail);

  await page.goto("/lab/profile_edit");
  expect(refused.length, `${name} was never requested, so nothing failed`).toBeGreaterThan(0);
  expect(await missing(page), "one failed module takes every factory with it").toEqual(FACTORIES);

  await expectSaysSo(page, "studioProfileForm");
  await expectSaysSo(page, "imageUploadHost");
  await expectSaysSo(page, "studioBirthdayFields");
  expect(reports, "one report for the page").toHaveLength(1);

  // The form can still be saved: the save controls never rose, so the plain
  // Save shows, and the field Alpine emptied carries the server's value again.
  await expect(cardControls(page)).toBeHidden();
  await expect(plainSave(page)).toBeVisible();
  await expect(plainSave(page)).toBeEnabled();
  await expect(firstName(page)).toHaveValue("Pat");
  await expect(page.locator('input[name="profile[last_name]"]')).toHaveValue("Studio");

  await firstName(page).fill("Patricia");
  await Promise.all([
    page.waitForURL((url) => url.searchParams.get("profile[first_name]") === "Patricia"),
    plainSave(page).click(),
  ]);
  const sent = new URL(page.url()).searchParams;
  expect(sent.get("profile[last_name]"), "the save sent a blank where the server had a value").toBe("Studio");

  // A reload fetches the module again, and the page is itself.
  await healAndReload(page);
  await page.waitForTimeout(GRACE_MS + 600);
  await expect(page.locator("[data-studio-scope-failed]")).toHaveCount(0);
  await expect(page.locator(".studio-scope-notice")).toHaveCount(0);
  await expect(plainSave(page)).toBeHidden();
  await firstName(page).fill("Someone Else");
  await expect(cardControls(page)).toBeVisible();
}

// One module fails at page load on the birthday gate's page. The card a modal
// mounts later says so the moment it arrives, and a reload recovers.
async function birthdayCardSaysSo(page, name, fail) {
  const { refused } = await failOne(page, name, fail);

  await page.goto("/lab/birthday_gate");
  expect(refused.length, `${name} was never requested, so nothing failed`).toBeGreaterThan(0);
  expect(await missing(page)).toEqual(FACTORIES);
  // Past the grace: nothing on the page binds a factory yet, so nothing is marked.
  await page.waitForTimeout(GRACE_MS + 300);
  await expect(page.locator("[data-studio-scope-failed]")).toHaveCount(0);

  await page.locator('[data-test="open-birthday"]').click();
  await expectSaysSo(page, "birthdayModal");
  await expect(page.locator('[role="dialog"] .studio-scope-notice')).toBeVisible();

  await healAndReload(page);
  await page.waitForTimeout(GRACE_MS + 300);
  await page.locator('[data-test="open-birthday"]').click();
  await expect(page.getByRole("button", { name: /Confirm & Continue/i })).toBeVisible();
  await page.waitForTimeout(600);
  await expect(page.locator("[data-studio-scope-failed]")).toHaveCount(0);
  await expect(page.locator(".studio-scope-notice")).toHaveCount(0);
}

// Written out one by one: the lane's static count reads each `test(` in this file.
test("studio/alpine_scopes aborted at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/alpine_scopes", abort);
});

test("studio/alpine_scopes answered 404 at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/alpine_scopes", notFound);
});

test("studio/cropper aborted at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/cropper", abort);
});

test("studio/cropper answered 404 at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/cropper", notFound);
});

test("studio/image_upload aborted at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/image_upload", abort);
});

test("studio/image_upload answered 404 at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/image_upload", notFound);
});

test("studio/birthday aborted at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/birthday", abort);
});

test("studio/birthday answered 404 at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/birthday", notFound);
});

test("studio/profile_form aborted at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/profile_form", abort);
});

test("studio/profile_form answered 404 at page load: the profile form says so and still saves", async ({ page }) => {
  await profileSaysSoAndStillSaves(page, "studio/profile_form", notFound);
});

test("studio/alpine_scopes aborted at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/alpine_scopes", abort);
});

test("studio/alpine_scopes answered 404 at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/alpine_scopes", notFound);
});

test("studio/cropper aborted at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/cropper", abort);
});

test("studio/cropper answered 404 at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/cropper", notFound);
});

test("studio/image_upload aborted at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/image_upload", abort);
});

test("studio/image_upload answered 404 at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/image_upload", notFound);
});

test("studio/birthday aborted at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/birthday", abort);
});

test("studio/birthday answered 404 at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/birthday", notFound);
});

test("studio/profile_form aborted at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/profile_form", abort);
});

test("studio/profile_form answered 404 at page load: the birthday card says so", async ({ page }) => {
  await birthdayCardSaysSo(page, "studio/profile_form", notFound);
});

test("a healthy profile page never shows the notice, and its plain Save stays hidden", async ({ page }) => {
  await blockOffsiteRequests(page);
  await instrument(page);
  await page.goto("/lab/profile_edit");
  await page.waitForFunction(() => !!(window.Alpine && window.Alpine.version));
  expect(await page.evaluate(() => typeof window.studioScopesGuard.verdict), "the guard is not on the page").toBe("function");
  expect(await missing(page)).toEqual([]);
  await page.waitForTimeout(GRACE_MS + 800);

  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
  await expect(page.locator("[data-studio-scope-failed]")).toHaveCount(0);
  await expect(page.locator(".studio-scope-notice")).toHaveCount(0);
  await expect(plainSave(page)).toBeHidden();
  await expect(page.locator("[data-studio-scope-fallback]")).not.toHaveAttribute("data-studio-scope-fallback", "shown");

  await firstName(page).fill("Someone Else");
  await expect(cardControls(page)).toBeVisible();
  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
});

test("a healthy birthday card, mounted after the grace, never shows the notice", async ({ page }) => {
  await blockOffsiteRequests(page);
  await instrument(page);
  await page.goto("/lab/birthday_gate");
  await page.waitForTimeout(GRACE_MS + 400);

  await page.locator('[data-test="open-birthday"]').click();
  await expect(page.getByRole("button", { name: /Confirm & Continue/i })).toBeVisible();
  await page.waitForTimeout(800);

  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
  await expect(page.locator(".studio-scope-notice")).toHaveCount(0);
  await expect(page.locator('[role="dialog"] select')).toHaveCount(3);
});

test("a boot whose modules arrive two seconds late never shows the notice, and the form then works", async ({ page }) => {
  await blockOffsiteRequests(page);
  await instrument(page);
  const delayed = [];
  await page.route((url) => ANY_MODULE(url.pathname + url.search), async (route) => {
    delayed.push(route.request().url());
    await new Promise((resolve) => setTimeout(resolve, 2000));
    await route.continue();
  });

  const started = Date.now();
  await page.goto("/lab/profile_edit", { waitUntil: "commit" });
  await expect(firstName(page)).toBeVisible();

  // On screen with no factory for the whole delay: no mark, no notice.
  await page.waitForTimeout(1300);
  expect(await missing(page), "the modules were not held back").toEqual(FACTORIES);
  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
  await expect(page.locator(".studio-scope-notice")).toHaveCount(0);

  await page.waitForFunction(() => !!(window.Alpine && window.Alpine.version));
  expect(Date.now() - started, "the modules were not delayed").toBeGreaterThanOrEqual(2000);
  expect(new Set(delayed.map((url) => new URL(url).pathname)).size).toBe(5);
  expect(await missing(page)).toEqual([]);
  await page.waitForTimeout(GRACE_MS + 800);
  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
  await expect(page.locator(".studio-scope-notice")).toHaveCount(0);
  await expect(plainSave(page)).toBeHidden();

  await firstName(page).fill("Someone Else");
  await expect(cardControls(page)).toBeVisible();
});
