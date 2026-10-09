const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The hold button's guard (studio/_hold_button_guard, inline in the head).
//
// The button runs on five modules. A browser keeps a failed module request for
// the life of the document, so ONE failure among them at page load leaves the
// button rendered, enabled and deaf: a full hold sends nothing and says
// nothing, until a reload. The guard marks such a button
// data-studio-controller-failed="hold-button", which engine-motion.css shows as
// an unavailable button over "This button could not load. Reload the page.",
// and a press says the notice again.
//
// Each failure here is real: the browser's request for one module is aborted,
// or answered 404, as the page loads. /lab/hold_button_events is the page the
// hold button's own specs use: 600ms a hold, one button on the page and one an
// x-if inserts.
//
// CONTROLS, each run against this file:
//   - drop `render "studio/hold_button_guard"` from layouts/studio/_head: the
//     ten failed-module specs and the late-connect spec fail at the mark.
//   - drop `this.element.setAttribute(CONNECTED, "")` from the hold-button
//     controller: the healthy, slow-boot and x-if specs fail, their working
//     buttons marked.
//   - drop the guard's `clear` call from the controller's connect: the
//     late-connect spec fails, its button working under a notice.
//   - drop the guard's sweep after an insertion (the MutationObserver's
//     `setTimeout(sweep, SETTLE_MS)`): each failed-module spec fails at its
//     late button, the one an x-if inserts on a page whose module failed. The
//     Turbo visit spec still passes, on the turbo:load sweep.

const MODULES = {
  "studio/stimulus": /\/studio\/stimulus(?:-[0-9a-f]+)?\.js(?:\?|$)/,
  "studio/lazy_controllers": /\/studio\/lazy_controllers(?:-[0-9a-f]+)?\.js(?:\?|$)/,
  "studio/controllers/hold_button_controller": /\/studio\/controllers\/hold_button_controller(?:-[0-9a-f]+)?\.js(?:\?|$)/,
  "studio/hold_button": /\/studio\/hold_button(?:-[0-9a-f]+)?\.js(?:\?|$)/,
  "studio/hold_button_hooks": /\/studio\/hold_button_hooks(?:-[0-9a-f]+)?\.js(?:\?|$)/,
};
const ANY_MODULE = (url) => Object.values(MODULES).some((pattern) => pattern.test(url));
const NOTICE = "This button could not load. Reload the page.";
const GRACE_MS = 1500;
const HOLD_EVENTS = ["guard", "start", "validate", "early", "success"];

const abort = (route) => route.abort();
const notFound = (route) => route.fulfill({ status: 404, contentType: "text/plain", body: "Not Found" });

const stack = (page, id) => page.locator(`.hold-stack:has(> .hold-btn[data-hold-id="${id}"])`);
const button = (page, id) => page.locator(`.hold-btn[data-hold-id="${id}"]`);
const notice = (page, id) => stack(page, id).locator("> .hold-notice");
const log = (page) => page.evaluate(() => Array.from(window.__holdEvents || []));

// Before any page script: count every hold-button:* event the document sees,
// and remember every stack that was EVER marked, so a mark that came and went
// between two reads still fails a spec that says there was none.
async function instrument(page) {
  await page.addInitScript((names) => {
    window.__dispatched = [];
    window.__everMarked = [];
    for (const name of names) {
      document.addEventListener(`hold-button:${name}`, () => window.__dispatched.push(name), true);
    }
    new MutationObserver((records) => {
      for (const record of records) {
        if (record.attributeName !== "data-studio-controller-failed") continue;
        if (record.target.hasAttribute("data-studio-controller-failed")) {
          window.__everMarked.push(record.target.querySelector(".hold-btn")?.dataset.holdId || "?");
        }
      }
    }).observe(document, { attributes: true, subtree: true });
  }, HOLD_EVENTS);
}

// The notices a reader can see or a screen reader can hear: any with text, or
// with a box bigger than the one pixel an empty one is clipped to.
function shownNotices(page) {
  return page.evaluate(() => Array.from(document.querySelectorAll(".hold-notice")).filter((element) => {
    const box = element.getBoundingClientRect();
    return element.textContent !== "" || box.width > 1 || box.height > 1;
  }).map((element) => element.parentElement.querySelector(".hold-btn")?.dataset.holdId || "?"));
}

async function holdFor(page, id, ms) {
  await button(page, id).hover();
  await page.mouse.down();
  await page.waitForTimeout(ms);
  await page.mouse.up();
}

async function connected(page, id) {
  await expect(stack(page, id)).toHaveAttribute("data-hold-button-connected", "");
}

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

async function expectUnavailable(page, id) {
  await expect(stack(page, id)).toHaveAttribute("data-studio-controller-failed", "hold-button", { timeout: GRACE_MS + 4000 });
  await expect(notice(page, id)).toBeVisible();
  await expect(notice(page, id)).toHaveText(NOTICE);
  await expect(notice(page, id)).toHaveAttribute("role", "status");
  await expect(button(page, id)).toHaveAttribute("aria-disabled", "true");
  expect(await button(page, id).getAttribute("aria-describedby")).toBe(await notice(page, id).getAttribute("id"));
  expect(Number(await button(page, id).evaluate((element) => getComputedStyle(element).opacity))).toBeLessThan(0.6);
}

// One module fails at page load. The button says so, a full hold sends and
// dispatches nothing, a button the page inserts later says so too, and a
// reload recovers.
async function saysItCannotWork(page, name, fail) {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await instrument(page);
  const refused = [];
  await page.route((url) => MODULES[name].test(url.pathname + url.search), (route) => {
    refused.push(route.request().url());
    return fail(route);
  });
  const reports = [];
  page.on("console", (message) => {
    if (message.type() === "error" && message.text().includes("the hold-button controller failed to load")) reports.push(message.text());
  });

  await page.goto("/lab/hold_button_events");
  expect(refused.length, `${name} was never requested, so nothing failed`).toBeGreaterThan(0);
  await expectUnavailable(page, "events");
  await expect(stack(page, "events")).not.toHaveAttribute("data-hold-button-connected", /.*/);

  // Legible in both themes. The lab is dark; light needs the class taken off.
  for (const theme of ["dark", "light"]) {
    await page.evaluate((dark) => document.documentElement.classList.toggle("dark", dark), theme === "dark");
    expect(await contrast(notice(page, "events")), `${theme} notice contrast`).toBeGreaterThanOrEqual(4.5);
    expect((await notice(page, "events").boundingBox()).height, theme).toBeGreaterThan(12);
  }
  await page.evaluate(() => document.documentElement.classList.add("dark"));

  // A full hold: nothing leaves the page and nothing is dispatched.
  const sent = [];
  const record = (request) => sent.push(`${request.method()} ${new URL(request.url()).pathname}`);
  page.on("request", record);
  await holdFor(page, "events", 900);
  await page.waitForTimeout(700);
  page.off("request", record);
  expect(sent, "a dead button made a request").toEqual([]);
  expect(await page.evaluate(() => window.__dispatched), "a dead button dispatched an event").toEqual([]);
  expect(await log(page)).toEqual([]);
  await expect(button(page, "events")).not.toHaveClass(/\b(success|process|loading)\b/);

  // The press is answered: the notice again.
  await expect(stack(page, "events")).toHaveAttribute("data-hold-notice-pressed", "");
  expect((await notice(page, "events").textContent()).trim()).toBe(NOTICE);
  await expect(notice(page, "events")).toBeVisible();

  // A button the page inserts later, as a modal inserts its confirm button.
  await expect(button(page, "late")).toHaveCount(0);
  await page.locator("[data-test='reveal']").click();
  await expectUnavailable(page, "late");
  await holdFor(page, "late", 900);
  expect(await page.evaluate(() => window.__dispatched)).toEqual([]);
  expect(reports, "one report for the page").toHaveLength(1);

  // A reload fetches the module again, and the button works.
  await page.unroute((url) => MODULES[name].test(url.pathname + url.search));
  await page.unrouteAll({ behavior: "wait" });
  await blockOffsiteRequests(page);
  await page.reload();
  await connected(page, "events");
  await page.waitForTimeout(GRACE_MS + 600);
  expect(await page.evaluate(() => window.__everMarked), "marked after the reload").toEqual([]);
  await expect(notice(page, "events")).toHaveText("");
  await holdFor(page, "events", 900);
  expect(await log(page)).toContain("success");
}

// Written out one by one: the lane's static count reads each `test(` in this file.
test("studio/stimulus aborted at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/stimulus", abort);
});

test("studio/stimulus answered 404 at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/stimulus", notFound);
});

test("studio/lazy_controllers aborted at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/lazy_controllers", abort);
});

test("studio/lazy_controllers answered 404 at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/lazy_controllers", notFound);
});

test("studio/controllers/hold_button_controller aborted at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/controllers/hold_button_controller", abort);
});

test("studio/controllers/hold_button_controller answered 404 at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/controllers/hold_button_controller", notFound);
});

test("studio/hold_button aborted at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/hold_button", abort);
});

test("studio/hold_button answered 404 at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/hold_button", notFound);
});

test("studio/hold_button_hooks aborted at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/hold_button_hooks", abort);
});

test("studio/hold_button_hooks answered 404 at page load: the button says it cannot work", async ({ page }) => {
  await saysItCannotWork(page, "studio/hold_button_hooks", notFound);
});

test("a healthy cold load never shows the notice, and the notice takes no room", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await instrument(page);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Network.enable");
  await cdp.send("Network.setCacheDisabled", { cacheDisabled: true });

  await page.goto("/lab/hold_button_events");
  await connected(page, "events");
  expect(await page.evaluate(() => typeof window.studioHoldButtonGuard.verdict), "the guard is not on the page").toBe("function");
  await page.waitForTimeout(GRACE_MS + 800);

  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
  await expect(page.locator("[data-studio-controller-failed]")).toHaveCount(0);
  expect(await shownNotices(page)).toEqual([]);
  await expect(notice(page, "events")).toHaveText("");
  await expect(button(page, "events")).not.toHaveAttribute("aria-disabled", /.*/);

  // The empty live region is out of the layout: the stack is as tall as its button.
  const stackBox = await stack(page, "events").boundingBox();
  const buttonBox = await button(page, "events").boundingBox();
  expect(Math.abs(stackBox.height - buttonBox.height)).toBeLessThanOrEqual(1);
  expect(Number(await button(page, "events").evaluate((element) => getComputedStyle(element).opacity))).toBe(1);

  await holdFor(page, "events", 900);
  expect(await log(page)).toEqual(["start:events", "validate", "early", "success"]);
  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
});

test("a boot whose modules arrive two seconds late never shows the notice, and the button then works", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await instrument(page);
  const delayed = [];
  await page.route((url) => ANY_MODULE(url.pathname + url.search), async (route) => {
    delayed.push(route.request().url());
    await new Promise((resolve) => setTimeout(resolve, 2000));
    await route.continue();
  });

  const started = Date.now();
  await page.goto("/lab/hold_button_events", { waitUntil: "commit" });
  await expect(button(page, "events")).toBeVisible();

  // On screen without its controller for the whole delay, and pressed: no mark.
  await holdFor(page, "events", 700);
  await page.waitForTimeout(600);
  await expect(stack(page, "events")).not.toHaveAttribute("data-hold-button-connected", /.*/);
  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);

  await connected(page, "events");
  expect(Date.now() - started, "the modules were not delayed").toBeGreaterThanOrEqual(2000);
  expect(new Set(delayed.map((url) => new URL(url).pathname)).size).toBe(5);
  await page.waitForTimeout(GRACE_MS + 800);
  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
  expect(await shownNotices(page)).toEqual([]);

  await page.evaluate(() => { window.__holdEvents = []; window.__dispatched = []; });
  await holdFor(page, "events", 900);
  expect(await page.evaluate(() => window.__dispatched.filter((name) => name === "success"))).toEqual(["success"]);
});

test("a button inserted later on a healthy page works on its first press, with no notice", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await instrument(page);
  await page.goto("/lab/hold_button_events");
  await connected(page, "events");
  // Past the grace, so a late stack is judged the moment the guard sweeps.
  await page.waitForTimeout(GRACE_MS + 400);

  await page.locator("[data-test='reveal']").click();
  await button(page, "late").hover();
  await page.mouse.down();
  await expect(button(page, "late")).toHaveClass(/\bsuccess\b/, { timeout: 3000 });
  await page.mouse.up();
  await page.waitForTimeout(600);

  expect((await log(page)).filter((entry) => entry.startsWith("late"))).toEqual(["late-start", "late-success"]);
  expect(await page.evaluate(() => window.__everMarked)).toEqual([]);
  expect(await shownNotices(page)).toEqual([]);
});

// A controller that connects after the grace takes the mark back. The page
// loads with studio/stimulus aborted and its buttons are marked; then a second
// copy of the module is imported by a new URL, which the document's module map
// has no failure for, and it starts a Stimulus application that connects them.
test("a controller that connects after the grace clears the mark, and the button works", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await instrument(page);
  await page.route((url) => MODULES["studio/stimulus"].test(url.pathname + url.search) && !url.search.includes("late"), abort);

  await page.goto("/lab/hold_button_events");
  await expectUnavailable(page, "events");

  await page.evaluate(async () => {
    const imports = JSON.parse(document.querySelector("script[type=importmap]").textContent).imports;
    await import(`${imports["studio/stimulus"]}?late=1`);
  });

  await connected(page, "events");
  await expect(stack(page, "events")).not.toHaveAttribute("data-studio-controller-failed", /.*/);
  await expect(notice(page, "events")).toHaveText("");
  expect(await shownNotices(page)).toEqual([]);
  await expect(button(page, "events")).not.toHaveAttribute("aria-disabled", /.*/);
  await expect(button(page, "events")).not.toHaveAttribute("aria-describedby", /.*/);
  expect(Number(await button(page, "events").evaluate((element) => getComputedStyle(element).opacity))).toBe(1);

  await holdFor(page, "events", 900);
  expect(await page.evaluate(() => window.__dispatched.filter((name) => name === "success"))).toEqual(["success"]);
});

test("a Turbo visit onto a page with a button, after a module failed, marks that button", async ({ page }) => {
  await blockOffsiteRequests(page);
  await instrument(page);
  await page.route((url) => MODULES["studio/hold_button"].test(url.pathname + url.search), abort);

  // The failure happens on a page that has no hold button.
  await page.goto("/lab/toast_flash");
  await expect(page.locator("[data-test='toast-flash-page']")).toBeVisible();
  await expect(page.locator(".hold-btn")).toHaveCount(0);
  await page.waitForTimeout(GRACE_MS + 300);

  await page.evaluate(() => { window.__sameDocument = true; });
  await page.evaluate(() => window.Turbo.visit("/lab/hold_button_events"));
  await expectUnavailable(page, "events");
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
});
