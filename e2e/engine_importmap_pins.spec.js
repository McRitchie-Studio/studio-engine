const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] The engine's importmap pins RESOLVE in a browser, and the module runs.
//
// The integration suite (test/integration/engine_importmap_pins_test.rb) proves the
// pin is in the host's map as a string. Only a browser proves the map is valid JSON
// the parser accepts, that "studio/local_path" resolves through it to a file this
// origin serves, and that the file is an ES module that evaluates and exports the
// rule. The dummy host has no config/importmap.rb, so the map is the engine's alone.

test("studio/local_path imports through the host's import map and answers like the server", async ({ page }) => {
  await blockOffsiteRequests(page);
  const moduleResponses = [];
  page.on("response", (response) => {
    if (response.url().includes("/studio/local_path")) moduleResponses.push(response.status());
  });

  await page.goto("/lab/engine_modules");

  const answers = await page.evaluate(async () => {
    const { isLocalPath } = await import("studio/local_path");
    return ["/ok", "//evil.example", "/\\evil.example", "/\tx", "https://x"].map((path) => isLocalPath(path));
  });

  expect(answers).toEqual([true, false, false, false, false]);
  expect(moduleResponses).toEqual([200]);
});

// Every page runs the engine's boot (studio/application), so its graph is
// preloaded. Any other pin stays unfetched until something imports it.
test("a pin outside the boot graph is not preloaded: the page fetches it only when it imports", async ({ page }) => {
  await blockOffsiteRequests(page);
  const localPathRequests = [];
  page.on("request", (request) => {
    if (request.url().includes("/studio/local_path")) localPathRequests.push(request.url());
  });

  await page.goto("/lab/engine_modules");
  await page.waitForLoadState("networkidle");

  const preloads = await page.locator("link[rel=modulepreload]").evaluateAll((links) => links.map((link) => link.getAttribute("href")));
  expect(preloads.some((href) => href.includes("/studio/application"))).toBe(true);
  expect(preloads.some((href) => href.includes("/studio/local_path"))).toBe(false);
  expect(localPathRequests).toEqual([]);

  const imports = await page.evaluate(() => JSON.parse(document.querySelector("script[type=importmap]").textContent).imports);
  expect(Object.keys(imports)).toContain("studio/local_path");
});
