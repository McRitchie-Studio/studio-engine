const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] A pointer resting on Log out never signs the browser out
// (docs/DEVICE_SESSIONS.md, "Prefetch"; task engine-logout-never-prefetched).
//
// Turbo 8 prefetches a same-origin link the pointer rests on for 100ms, with
// X-Sec-Purpose: prefetch. Every host's sign-out is GET /logout, so that prefetch ran
// the sign-out and its Set-Cookie dropped the session while the page still drew the
// user (hub task build-funnel-held-message-cause). Two covers stop the browser asking:
//   - the engine's Log out (components/_link_sidebar) carries data-turbo-prefetch="false";
//   - studio/sign_out_prefetch cancels turbo:before-prefetch for any /logout link a
//     host draws without it.
// The server's 204 for a prefetch that still arrives is the integration tier's
// (test/integration/logout_ends_device_session_test.rb).
//
// THE REST. An absent request has no event to wait for, so the first spec rests the
// pointer for REST_MS, five times Turbo's 100ms delay, and first proves on a sibling
// row that the same rest does send a prefetch on this page. The second spec needs no
// rest: Turbo decides at mouseenter, and the cancelled turbo:before-prefetch is the
// decision itself.
//
// CONTROLS, each run against this file:
//   - drop data-turbo-prefetch from the Log out row: the first spec sees a GET
//     /logout with X-Sec-Purpose: prefetch.
//   - drop `import "studio/sign_out_prefetch"` from studio/application: the second
//     spec reads prevented: false and sees the prefetch.

const REST_MS = 500;
const PAGE = "/lab/sidebar_panels_turbo?sidebar=1&signed_in=1";

const panel = (page) => page.locator("#studio-link-sidebar");
const trigger = (page) => page.locator("[data-link-sidebar-trigger]").first();

function recordRequests(page, pathname) {
  const seen = [];
  page.on("request", (request) => {
    if (new URL(request.url()).pathname === pathname) seen.push(request.headers()["x-sec-purpose"] || "visit");
  });
  return seen;
}

// Resolves with the first request to `pathname` inside `ms`, or null when none came.
function requestWithin(page, pathname, ms) {
  return page
    .waitForRequest((request) => new URL(request.url()).pathname === pathname, { timeout: ms })
    .then((request) => request.headers()["x-sec-purpose"] || "visit", () => null);
}

async function visitWithTurbo(page) {
  await blockOffsiteRequests(page);
  await page.goto(PAGE);
  await expect.poll(() => page.evaluate(() => Boolean(window.Turbo)), { message: "Turbo started" }).toBe(true);
}

async function openSidebar(page) {
  await visitWithTurbo(page);
  await trigger(page).click();
  await expect(panel(page)).toBeVisible();
}

test("resting the pointer on the engine's Log out sends no request to /logout", async ({ page }) => {
  const errors = watchPageErrors(page);
  await openSidebar(page);
  const signOuts = recordRequests(page, "/logout");

  // The control: the same rest on a sibling row is a prefetch on this page. The
  // window opens once hover() returns, since hover first waits out the panel's slide.
  const rowAsks = recordRequests(page, "/up");
  await panel(page).locator('a[href="/up"]').first().hover();
  await expect
    .poll(() => rowAsks, { message: "Turbo prefetches a row the pointer rests on", timeout: REST_MS })
    .toContain("prefetch");

  const logOut = panel(page).locator('a[href="/logout"]');
  await expect(logOut).toHaveAttribute("data-turbo-prefetch", "false");
  await logOut.hover();
  expect(await requestWithin(page, "/logout", REST_MS), `a ${REST_MS}ms rest on Log out asks /logout nothing`).toBeNull();
  expect(signOuts).toEqual([]);
  expect(errors).toEqual([]);
});

test("a host's own /logout link without the opt-out is not prefetched either", async ({ page }) => {
  const errors = watchPageErrors(page);
  await visitWithTurbo(page);
  const signOuts = recordRequests(page, "/logout");
  await page.evaluate(() => {
    window.__prefetchAsks = [];
    document.addEventListener("turbo:before-prefetch", (event) => {
      window.__prefetchAsks.push({ href: event.target.getAttribute("href"), prevented: event.defaultPrevented });
    });
    // A host's sign-out, drawn its own way: a plain link, no data-turbo-prefetch.
    const link = document.createElement("a");
    link.href = "/logout";
    link.textContent = "Host log out";
    link.setAttribute("data-test", "host-logout");
    link.style.cssText = "position:fixed;left:8px;bottom:8px;z-index:2147483647;padding:12px;background:#fff;color:#000";
    document.body.appendChild(link);
  });

  await page.locator("[data-test='host-logout']").hover();

  await expect
    .poll(() => page.evaluate(() => window.__prefetchAsks), { message: "Turbo asked, and the engine said no" })
    .toContainEqual({ href: "/logout", prevented: true });
  expect(signOuts, "no request reached /logout").toEqual([]);
  expect(errors).toEqual([]);
});
