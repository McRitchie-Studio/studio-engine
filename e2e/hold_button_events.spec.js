const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The hold button on its controller (studio/hold_button, registered lazily
// by studio/stimulus): the hold-button:* events a page answers it through, the
// string locals a consumer still passes, and what happens at the edges. The
// button confirms real actions, so each spec pins one way it must fail safe:
// never confirm early, never confirm twice, never lose a hold that was held.
//
// /lab/hold_button_events renders the engine partial by name, 600ms a hold, with
// the Alpine listeners a host writes around it.
//
// CONTROLS, each run against this file:
//   - drop `fire("success")` in studio/hold_button_hooks: the events and owned
//     specs fail.
//   - make Hold#start skip its guard: the disarmed and submitting specs fail.
//   - fire completion at the press: "a release before term" fails.
//   - drop the hold-button entry from LAZY in studio/stimulus: every spec fails.
//   - drop `javascript_import_module_tag "studio/stimulus"` from the head: the
//     failed-boot spec fails.

const BOOT_MODULE = /\/studio\/application(?:-[0-9a-f]+)?\.js(?:\?|$)/;
const CONTROLLER_MODULE = /\/studio\/controllers\/hold_button_controller(?:-[0-9a-f]+)?\.js(?:\?|$)/;

const button = (page, id) => page.locator(`.hold-btn[data-hold-id="${id}"]`);
const log = (page) => page.evaluate(() => Array.from(window.__holdEvents || []));

// The controller is registered once its module has loaded; the nudge ring it
// starts on connect is the page's own sign of that.
async function ready(page, id) {
  await expect(button(page, id).locator(".countdown-num")).not.toHaveText("");
}

async function holdFor(page, id, ms) {
  await button(page, id).hover();
  await page.mouse.down();
  await page.waitForTimeout(ms);
  await page.mouse.up();
}

async function open(page) {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/lab/hold_button_events");
  await ready(page, "events");
}

test("a hold held to term fires its events in order, once each", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page);

  await button(page, "events").hover();
  await page.mouse.down();
  await expect(button(page, "events")).toHaveClass(/\bsuccess\b/, { timeout: 3000 });
  await page.mouse.up();
  await page.waitForTimeout(700);

  expect(await log(page)).toEqual(["start:events", "validate", "early", "success"]);
  expect(errors).toEqual([]);
});

test("a release before term fires start and nothing after it", async ({ page }) => {
  await open(page);

  await holdFor(page, "events", 80);
  await page.waitForTimeout(900);

  expect(await log(page)).toEqual(["start:events"]);
  await expect(button(page, "events")).not.toHaveClass(/\b(success|process)\b/);
});

test("a guard listener that prevents the press refuses the hold", async ({ page }) => {
  await open(page);
  await page.locator('[data-test="armed"]').uncheck();

  await holdFor(page, "events", 900);

  expect(await log(page)).toEqual([]);
  await expect(button(page, "events")).not.toHaveClass(/\b(success|process)\b/);

  // Armed again, the same button confirms.
  await page.locator('[data-test="armed"]').check();
  await holdFor(page, "events", 900);
  expect(await log(page)).toContain("success");
});

test("a validate listener that answers false aborts the hold", async ({ page }) => {
  await open(page);
  await ready(page, "refused");

  await button(page, "refused").hover();
  await page.mouse.down();
  await expect(button(page, "refused")).toHaveClass(/\bprocess\b/);
  await expect(button(page, "refused")).not.toHaveClass(/\bprocess\b/, { timeout: 2000 });
  await page.waitForTimeout(900);
  await page.mouse.up();

  expect(await log(page)).not.toContain("refused-success");
  await expect(button(page, "refused")).not.toHaveClass(/\bsuccess\b/);
});

test("a success listener that prevents the default keeps the button's state for itself", async ({ page }) => {
  await open(page);
  await ready(page, "owned");

  await button(page, "owned").hover();
  await page.mouse.down();
  await expect.poll(() => log(page)).toEqual(["owned-success"]);

  await expect(button(page, "owned")).toHaveClass(/\bprocess\b/);
  await expect(button(page, "owned")).not.toHaveClass(/\bsuccess\b/);
  await page.mouse.up();
});

test("an early listener that prevents the default takes the action over: no success", async ({ page }) => {
  await open(page);
  await ready(page, "taken");

  await button(page, "taken").hover();
  await page.mouse.down();
  await expect.poll(() => log(page)).toEqual(["taken"]);
  await page.waitForTimeout(900);
  await page.mouse.up();

  expect(await log(page)).toEqual(["taken"]);
});

test("the string locals still answer: on_success once after a full hold, guard refuses", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page);
  await ready(page, "string");

  // Released early: on_success must not run, even after its half-second settle.
  await holdFor(page, "string", 150);
  await page.waitForTimeout(1300);
  expect(await log(page)).toEqual([]);

  await button(page, "string").hover();
  await page.mouse.down();
  await expect.poll(() => log(page), { timeout: 4000 }).toEqual(["string-success"]);
  await page.mouse.up();
  await page.waitForTimeout(1300);
  expect(await log(page), "one hold confirms once").toEqual(["string-success"]);

  // The guard string reads the same scope.
  await page.locator('[data-test="armed"]').uncheck();
  await holdFor(page, "string", 900);
  await page.waitForTimeout(700);
  expect(await log(page)).toEqual(["string-success"]);
  expect(errors).toEqual([]);
});

test("a scope that is submitting refuses a second hold", async ({ page }) => {
  await open(page);
  await ready(page, "submitting");

  await button(page, "submitting").hover();
  await page.mouse.down();
  await page.waitForTimeout(300);

  await expect(button(page, "submitting")).not.toHaveClass(/\bprocess\b/);
  await page.waitForTimeout(600);
  await expect(button(page, "submitting")).not.toHaveClass(/\bsuccess\b/);
  await page.mouse.up();
});

test("a touch starts the hold and is not handed on to the browser", async ({ page }) => {
  await open(page);

  const prevented = await button(page, "events").evaluate((el) => {
    const touch = new Event("touchstart", { bubbles: true, cancelable: true });
    el.dispatchEvent(touch);
    return touch.defaultPrevented;
  });

  expect(prevented).toBe(true);
  await expect(button(page, "events")).toHaveClass(/\bprocess\b/);
  await button(page, "events").dispatchEvent("touchend");
  await expect(button(page, "events")).not.toHaveClass(/\bprocess\b/);
});

test("a press before the controller has loaded does nothing and throws nothing", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  await page.route((url) => CONTROLLER_MODULE.test(url.pathname + url.search), async (route) => {
    await held;
    await route.continue();
  });

  await page.goto("/lab/hold_button_events");
  await expect(button(page, "events")).toBeVisible();

  await holdFor(page, "events", 900);
  expect(await log(page), "no controller, no hold").toEqual([]);
  await expect(button(page, "events")).not.toHaveClass(/\b(success|process)\b/);

  release();
  await ready(page, "events");
  await holdFor(page, "events", 900);
  expect(await log(page)).toContain("success");
  expect(errors).toEqual([]);
});

test("the controller is fetched only by a page that renders the button", async ({ page }) => {
  await blockOffsiteRequests(page);
  const fetched = [];
  page.on("request", (request) => { if (CONTROLLER_MODULE.test(request.url())) fetched.push(request.url()); });

  await page.goto("/lab/toast_flash");
  await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
  await page.waitForLoadState("networkidle");
  expect(fetched, "no hold button, no controller").toEqual([]);
  const preloaded = await page.locator('link[rel="modulepreload"]').evaluateAll((links) => links.map((l) => l.href));
  expect(preloaded.filter((href) => /hold_button/.test(href))).toEqual([]);

  // A Turbo visit onto a page that has one: the controller arrives then.
  await page.evaluate(() => window.Turbo.visit("/lab/hold_button_events"));
  await ready(page, "events");
  expect(fetched.length).toBe(1);
  await holdFor(page, "events", 900);
  expect(await log(page)).toContain("success");
});

test("after a Turbo visit and Back the button still confirms, with one portal box", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page);
  const boxes = page.locator('body > .hold-fizz-portal[data-fizz-portal-for="portaled"]');
  await expect(boxes).toHaveCount(1);

  await page.evaluate(() => { window.__sameDocument = true; });
  await page.locator("[data-survey-lab-away]").click();
  await expect(page).toHaveURL(/site_footer\/terms/);
  await expect(page.locator("body > .hold-fizz-portal")).toHaveCount(0);

  await page.goBack();
  await ready(page, "events");
  expect(await page.evaluate(() => window.__sameDocument), "Back restored from Turbo's cache").toBe(true);
  await expect(boxes).toHaveCount(1);
  await expect(page.locator('.hold-stack[data-fizz-portal] > .hold-fizz-portal')).toHaveCount(0);

  await page.evaluate(() => { window.__holdEvents = []; });
  await button(page, "events").hover();
  await page.mouse.down();
  await expect(button(page, "events")).toHaveClass(/\bsuccess\b/, { timeout: 3000 });
  await page.mouse.up();
  expect((await log(page)).filter((name) => name === "success")).toHaveLength(1);
  expect(errors).toEqual([]);
});

test("the button confirms when the boot fails to load", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  const aborted = [];
  await page.route((url) => BOOT_MODULE.test(url.pathname + url.search), (route) => {
    aborted.push(route.request().url());
    return route.abort();
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    if (BOOT_MODULE.test(message.location().url || "")) return;
    errors.push(`console.error: ${message.text()}`);
  });

  await page.goto("/lab/hold_button_events");
  await ready(page, "events");
  expect(aborted.length, "studio/application was never requested, so nothing failed").toBeGreaterThan(0);
  expect(await page.evaluate(() => typeof window.navCollapse), "the boot did fail").toBe("undefined");

  await button(page, "events").hover();
  await page.mouse.down();
  await expect(button(page, "events")).toHaveClass(/\bsuccess\b/, { timeout: 3000 });
  await page.mouse.up();

  expect(await log(page)).toEqual(["start:events", "validate", "early", "success"]);
  expect(errors).toEqual([]);
});
