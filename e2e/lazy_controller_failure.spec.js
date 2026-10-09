const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] What the lazy registry (studio/lazy_controllers) does when a lazy
// controller's module fails to load, measured in a real browser.
//
// A BROWSER NEVER FETCHES A FAILED MODULE AGAIN in the same document: the
// failure stays in the document's module map, and every later import() of that
// module rejects without a request. So a registry that "retries" re-rejects
// forever, and a control waiting on it is dead until a full reload. The
// registry therefore imports once, reports once, and marks every element that
// names the failed controller with data-studio-controller-failed, so a failed
// load is a state the page can show and never a control that silently ignores
// its user.
//
// /lab/lazy_controller runs the engine's registry on the engine's Stimulus
// application with one loader, a dynamic import of /e2e/js/lab_lazy_controller.js
// (studio/stimulus's own LAZY list is empty). The failure is real: the browser's
// request for that module is aborted, or answered 404.
//
// CONTROLS, each run against this file:
//   - re-queue a failed controller in the registry's catch (`pending.add(name)`
//     in place of `failed.set(name, error)` and `mark()`): both failure specs
//     fail, with no mark and one console error per change.
//   - drop `failed.size > 0` from the observer's condition: both failure specs
//     fail at the element inserted after the failure.

const LAZY_MODULE = /\/e2e\/js\/lab_lazy_controller\.js(?:\?|$)/;
const REPORT = "[studio] the lab-lazy controller failed to load";

const first = (page) => page.locator("[data-test='first']");

function watch(page) {
  const requests = [];
  const reports = [];
  const thrown = [];
  page.on("request", (request) => { if (LAZY_MODULE.test(request.url())) requests.push(request.url()); });
  page.on("console", (message) => { if (message.type() === "error" && message.text().includes(REPORT)) reports.push(message.text()); });
  page.on("pageerror", (error) => thrown.push(error.message));
  return { requests, reports, thrown };
}

// The registry has finished with its controller, one way or the other.
async function settled(page) {
  await page.waitForFunction(() => {
    const element = document.querySelector("[data-test='first']");
    return element.dataset.labLazy === "connected" || element.hasAttribute("data-studio-controller-failed");
  });
}

async function addElement(page, name) {
  await page.evaluate((test) => {
    const element = document.createElement("div");
    element.dataset.test = test;
    element.setAttribute("data-studio-controller", "lab-lazy");
    document.querySelector("[data-test='lazy-lab']").appendChild(element);
  }, name);
}

test("a lazy controller that loads registers, connects, and leaves no mark", async ({ page }) => {
  await blockOffsiteRequests(page);
  const { requests, reports, thrown } = watch(page);

  await page.goto("/lab/lazy_controller");
  await settled(page);

  await expect(first(page)).toHaveAttribute("data-lab-lazy", "connected");
  await expect(first(page)).not.toHaveAttribute("data-studio-controller-failed", /.*/);
  await addElement(page, "later");
  await expect(page.locator("[data-test='later']")).toHaveAttribute("data-lab-lazy", "connected");

  expect(requests).toHaveLength(1);
  expect(await page.evaluate(() => [...window.__labLazy.failed.keys()])).toEqual([]);
  expect(reports).toEqual([]);
  expect(thrown).toEqual([]);
});

for (const [name, fail] of [
  ["the request is aborted", (route) => route.abort()],
  ["the file is gone (404)", (route) => route.fulfill({ status: 404, contentType: "text/plain", body: "Not Found" })],
]) {
  test(`a lazy controller that fails to load is marked, reported once and never imported again: ${name}`, async ({ page }) => {
    await blockOffsiteRequests(page);
    const { requests, reports, thrown } = watch(page);
    const failing = (url) => LAZY_MODULE.test(url.pathname + url.search);
    await page.route(failing, fail);

    await page.goto("/lab/lazy_controller");
    await settled(page);

    // The state is on the element, where a page can style or announce it.
    await expect(first(page)).toHaveAttribute("data-studio-controller-failed", "lab-lazy");
    await expect(first(page)).not.toHaveAttribute("data-lab-lazy", /.*/);
    expect(await page.evaluate(() => [...window.__labLazy.failed.keys()])).toEqual(["lab-lazy"]);

    // The page changes, as a page does: each new element is marked, and
    // nothing is imported or reported again.
    for (const later of ["second", "third", "fourth"]) {
      await addElement(page, later);
      await expect(page.locator(`[data-test='${later}']`)).toHaveAttribute("data-studio-controller-failed", "lab-lazy");
    }
    expect(requests, "the registry imported a failed module again").toHaveLength(1);
    expect(reports, "one report for the document, not one per change").toHaveLength(1);
    expect(reports[0]).toContain("until the page is reloaded");
    expect(thrown).toEqual([]);

    // WHY the registry does not retry: the browser would not. The route is
    // lifted, so the module is reachable again, and the document still rejects
    // an import of it without asking the network.
    await page.unroute(failing);
    const again = await page.evaluate(() => import("/e2e/js/lab_lazy_controller.js").then(() => "loaded", () => "rejected"));
    expect(again).toBe("rejected");
    expect(requests, "the browser fetched a failed module again").toHaveLength(1);

    // A full page load is the recovery.
    await page.reload();
    await settled(page);
    await expect(first(page)).toHaveAttribute("data-lab-lazy", "connected");
    await expect(first(page)).not.toHaveAttribute("data-studio-controller-failed", /.*/);
    expect(requests).toHaveLength(2);
    expect(reports).toHaveLength(1);
  });
}
