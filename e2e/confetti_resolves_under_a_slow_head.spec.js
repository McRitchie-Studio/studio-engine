const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests, watchPageErrors } = require("./helpers");

// [e2e] studio/studio_confetti resolves its bare import ("canvas-confetti") however
// slowly the head parses.
//
// THE REGRESSION (studio-engine 0.115.1.rc1, task confetti-resolves-on-hub). The head
// loaded the module by URL, javascript_include_tag "studio/studio_confetti",
// type: "module". Rails answers every such tag with a `Link: <url>; rel=modulepreload`
// RESPONSE HEADER (config.action_view.preload_links_header, on by default), and the
// browser acts on a header before it parses a byte of the body. So it fetched
// studio_confetti and resolved its `import "canvas-confetti"` against the import map
// as it stood at that moment: none yet, when the parser had not reached
// <script type="importmap">. The resolution failure is cached with the module, and the
// tag below the map later rethrows it: `TypeError: Failed to resolve module specifier
// "canvas-confetti"`. It was a race between that fetch and the parse of everything
// above the map, so a light page (the lab) almost always won it and a heavy one (the
// hub's boards and /dreams, 11 hub specs in CI) lost it.
//
// This spec makes the race lose every time: it holds back the one parser-blocking
// classic script above the map (the session store) so the header's preload finishes
// first. Under the old head it failed on every load; with the module imported by an
// inline module tag below the map (no Link header), the specifier resolves.
test("confetti resolves when the parse of the head is slower than the module's preload", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.route(/\/studio\/session[^/]*\.js(\?|$)/, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 700));
    await route.continue();
  });
  const errors = watchPageErrors(page);

  const response = await page.goto("/lab/session_drift?fp=fp-alice&issued=1000&state=authenticated");
  await page.waitForFunction(() => Boolean(window.Alpine), null, { timeout: 10_000 });
  await page.waitForTimeout(200);

  expect(errors).toEqual([]);
  expect(await page.evaluate(() => typeof window.studioConfetti)).toBe("object");
  expect(await page.evaluate(() => typeof window.confetti)).toBe("function");

  // The mechanism, named: no module the head loads arrives by a Link header preload.
  const link = (await response.allHeaders())["link"] || "";
  expect(link, "a Link header modulepreload is fetched before the import map exists").not.toContain("studio_confetti");
});
