// The newsletter cards' fetcher: local, in a browser (engine-adoption-loose-ends).
//
// The markup carries `fetcher: 'labFetch'` in each sending card's x-data, and a
// markup test reads that. What only a run produces is the PROGRAM: on the press,
// studio/newsletter_modal dynamically imports the importmap module
// studio/host_fetchers, finds the named export, and sends through it; a null
// answer means the host handled it; a missing export fails the press on the
// card's own error line and never falls back to plain fetch.
//
// THE HOST'S PIN. A host pins studio/host_fetchers to a file of its own. The dummy
// host may not pin anything (engine_importmap_pins_test holds that it writes no
// config/importmap.rb), so these specs stand in the pin at the network: the
// browser resolves the name through the engine's own pin, exactly as a host page
// would, and page.route answers that module URL with the host's module. The last
// test routes nothing, so the engine's real empty seam is what loads.
const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

const SEAM = (url) => /\/studio\/host_fetchers(-[0-9a-f]+)?\.js$/.test(new URL(url).pathname);

// The host's module: two named fetchers, each leaving a flag a spec can read.
const HOST_MODULE = `
export async function labFetch(url, init) {
  window.__labFetcher = { calls: (window.__labFetcher ? window.__labFetcher.calls : 0) + 1, url: url, method: init.method }
  return fetch(url, init)
}
export async function labAnswered(url, init) {
  window.__labAnswered = (window.__labAnswered || 0) + 1
  return null
}
`;

async function pinHostFetchers(page) {
  const served = [];
  await page.route((url) => SEAM(url.toString()), (route) => {
    served.push(route.request().url());
    return route.fulfill({ status: 200, contentType: "text/javascript", body: HOST_MODULE });
  });
  return served;
}

function countPosts(page) {
  const posts = [];
  page.on("request", (r) => {
    if (r.method() === "POST" && r.url().includes("/lab/modal_blocks/newsletter/leave")) posts.push(r.url());
  });
  return posts;
}

const card = (page) => page.locator('[role="dialog"]');
const unsubscribe = (page) => page.getByRole("button", { name: "Unsubscribe", exact: true });

test("a named host fetcher carries the press, and the card steps on when it answers", async ({ page }) => {
  await blockOffsiteRequests(page);
  const served = await pinHostFetchers(page);
  const posts = countPosts(page);
  await page.goto("/lab/newsletter_fetcher");

  await page.locator('[data-test="open-newsletter-unsubscribe"]').click();
  await unsubscribe(page).click();

  await expect(page.getByRole("heading", { name: "See you later" })).toBeVisible();
  const flag = await page.evaluate(() => window.__labFetcher);
  expect(flag).toEqual({ calls: 1, url: "/lab/modal_blocks/newsletter/leave", method: "POST" });
  expect(served.length, "the seam module was imported, on the press").toBe(1);
  expect(posts.length, "one request, sent by the host's fetcher").toBe(1);
  await expect(page.locator("main")).toHaveAttribute("data-changed", "false");
});

test("a host fetcher that answers itself (null) stops the spinner and shows no error", async ({ page }) => {
  await blockOffsiteRequests(page);
  await pinHostFetchers(page);
  const posts = countPosts(page);
  await page.goto("/lab/newsletter_fetcher?fetcher=labAnswered");

  await page.locator('[data-test="open-newsletter-unsubscribe"]').click();
  await unsubscribe(page).click();

  await expect.poll(() => page.evaluate(() => window.__labAnswered)).toBe(1);
  await expect(card(page).getByText("Unsubscribing…")).toBeHidden();
  await expect(unsubscribe(page)).toBeEnabled();
  await expect(card(page).getByRole("alert")).toBeHidden();
  await expect(page.getByRole("heading", { name: "Unsubscribe?" })).toBeVisible();
  expect(posts.length, "the host's fetcher sent nothing").toBe(0);
});

test("a fetcher the engine's empty seam does not export fails the press on the card's line", async ({ page }) => {
  await blockOffsiteRequests(page);
  const posts = countPosts(page);
  const consoleErrors = [];
  page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text()); });
  const seamLoads = [];
  page.on("response", (r) => { if (SEAM(r.url())) seamLoads.push(r.status()); });
  await page.goto("/lab/newsletter_fetcher?fetcher=labFetch");

  await page.locator('[data-test="open-newsletter-unsubscribe"]').click();
  await unsubscribe(page).click();

  await expect(card(page).getByRole("alert")).toHaveText("Could not unsubscribe.");
  await expect(card(page).getByText("Unsubscribing…")).toBeHidden();
  await expect(unsubscribe(page)).toBeEnabled();
  expect(seamLoads, "the engine's own pin served the real seam").toEqual([200]);
  expect(posts.length, "no fallback to plain fetch").toBe(0);
  expect(consoleErrors.some((t) => t.includes("exports no function named labFetch"))).toBe(true);
  expect(await page.evaluate(() => window.__labFetcher)).toBeUndefined();
});
