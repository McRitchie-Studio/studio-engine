const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The hold button on its controller (studio/hold_button, imported and
// registered by studio/stimulus): the hold-button:* events a page answers it
// through, the string locals a consumer still passes, and what happens at the
// edges. The button confirms real actions, so each spec pins one way it must
// fail safe: never confirm early, never confirm twice, never lose a hold that
// was held, and never wait on a request made after the page loaded.
//
// /lab/hold_button_events renders the engine partial by name, 600ms a hold, with
// the Alpine listeners a host writes around it.
//
// CONTROLS, each run against this file:
//   - drop `fire("success")` in studio/hold_button_hooks: the events and owned
//     specs fail.
//   - make Hold#start skip its guard: the disarmed and submitting specs fail.
//   - fire completion at the press: "a release before term" fails.
//   - drop `application.register("hold-button", ...)` from studio/stimulus:
//     every spec fails.
//   - register the button lazily again (a dynamic import in LAZY in
//     studio/stimulus, no static import): the "arrive with the page" spec and
//     both "can no longer be fetched" specs fail, the last two at a button
//     whose controller never arrives.
//   - drop `javascript_import_module_tag "studio/stimulus"` from the head: the
//     failed-boot spec fails.

const BOOT_MODULE = /\/studio\/application(?:-[0-9a-f]+)?\.js(?:\?|$)/;
const CONTROLLER_MODULE = /\/studio\/controllers\/hold_button_controller(?:-[0-9a-f]+)?\.js(?:\?|$)/;
// The three modules the button runs on: its controller, the timeline and the hooks.
const HOLD_MODULES = /\/studio\/(?:controllers\/hold_button_controller|hold_button|hold_button_hooks)(?:-[0-9a-f]+)?\.js(?:\?|$)/;

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

// The controller is part of the page's own load now, so the only time a button
// is on screen without it is while the page is still loading: the markup has
// arrived and its modules have not.
test("a press while the page is still loading does nothing and throws nothing", async ({ page }) => {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  await page.route((url) => CONTROLLER_MODULE.test(url.pathname + url.search), async (route) => {
    await held;
    await route.continue();
  });

  // The load event waits on the held module, so the visit returns at commit.
  await page.goto("/lab/hold_button_events", { waitUntil: "commit" });
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

test("the button's modules arrive with the page, so a later button fetches nothing", async ({ page }) => {
  await blockOffsiteRequests(page);
  const fetched = [];
  page.on("request", (request) => { if (HOLD_MODULES.test(request.url())) fetched.push(new URL(request.url()).pathname); });

  // A page with no hold button: the three modules are preloaded with the boot.
  await page.goto("/lab/toast_flash");
  await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
  await page.waitForLoadState("networkidle");
  const preloaded = await page.locator('link[rel="modulepreload"]').evaluateAll((links) => links.map((l) => l.href));
  expect(preloaded.filter((href) => HOLD_MODULES.test(href))).toHaveLength(3);
  expect([...new Set(fetched)]).toHaveLength(3);

  // A Turbo visit onto a page that has one: nothing more is requested.
  const before = fetched.length;
  await page.evaluate(() => window.Turbo.visit("/lab/hold_button_events"));
  await ready(page, "events");
  await holdFor(page, "events", 900);
  expect(await log(page)).toContain("success");
  expect(fetched.length, "the button asked for a module after the page loaded").toBe(before);
});

// THE FAILURE THIS BUTTON MUST NOT HAVE. Registered lazily, the button's first
// render made one more request, and a browser never repeats a failed module
// request in the same document: one dropped connection, or a deploy that
// retired the digested file between the page load and that request, left a
// button that rendered, took a press and did nothing, until a full reload.
//
// Each spec loads a page that has NO hold button, then makes the three modules
// unreachable FOR REAL (the browser's requests are aborted, or answered 404),
// and only then meets its first button: by a Turbo visit, and by an x-if that
// inserts one, as a modal inserts its confirm button. Both confirm, because
// nothing asks for a module after the page loaded. The spec then requests one
// itself, to show the route was live and the failure real.
async function confirmsWithItsModulesGone(page, fail) {
  const errors = watchPageErrors(page);
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto("/lab/toast_flash");
  await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
  await page.waitForLoadState("networkidle");
  await expect(page.locator(".hold-btn")).toHaveCount(0);

  const refused = [];
  await page.route((url) => HOLD_MODULES.test(url.pathname + url.search), (route) => {
    refused.push(route.request().url());
    return fail(route);
  });

  // The document's first hold button, in the same document.
  await page.evaluate(() => { window.__sameDocument = true; });
  await page.evaluate(() => window.Turbo.visit("/lab/hold_button_events"));
  await ready(page, "events");
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
  await button(page, "events").hover();
  await page.mouse.down();
  await expect(button(page, "events")).toHaveClass(/\bsuccess\b/, { timeout: 3000 });
  await page.mouse.up();

  // One the page inserts later.
  await expect(button(page, "late")).toHaveCount(0);
  await page.locator("[data-test='reveal']").click();
  await ready(page, "late");
  await button(page, "late").hover();
  await page.mouse.down();
  await expect(button(page, "late")).toHaveClass(/\bsuccess\b/, { timeout: 3000 });
  await page.mouse.up();
  expect((await log(page)).filter((entry) => entry.startsWith("late"))).toEqual(["late-start", "late-success"]);

  expect(refused, "the button asked for a module after the page loaded").toEqual([]);
  expect(errors).toEqual([]);

  // The modules really are unreachable: a request for one, made now, fails.
  const reached = await page.evaluate(async () => {
    const imports = JSON.parse(document.querySelector("script[type=importmap]").textContent).imports;
    try {
      return (await fetch(imports["studio/controllers/hold_button_controller"], { cache: "reload" })).status;
    } catch (error) {
      return "failed";
    }
  });
  expect(["failed", 404]).toContain(reached);
  expect(refused).toHaveLength(1);
}

// Written out one by one: the lane's static count reads each `test(` in this file.
test("a button rendered after its modules can no longer be fetched still confirms: the connection drops", async ({ page }) => {
  await confirmsWithItsModulesGone(page, (route) => route.abort());
});

test("a button rendered after its modules can no longer be fetched still confirms: a deploy retired the files (404)", async ({ page }) => {
  await confirmsWithItsModulesGone(page, (route) => route.fulfill({ status: 404, contentType: "text/plain", body: "Not Found" }));
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
