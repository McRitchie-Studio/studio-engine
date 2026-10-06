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

test("the engine's pins are not preloaded: the page fetches nothing until it imports", async ({ page }) => {
  await blockOffsiteRequests(page);
  const moduleRequests = [];
  page.on("request", (request) => {
    if (request.url().includes("/e2e/modules/")) moduleRequests.push(request.url());
  });

  await page.goto("/lab/engine_modules");
  await page.waitForLoadState("networkidle");

  expect(await page.locator("link[rel=modulepreload]").count()).toBe(0);
  expect(moduleRequests).toEqual([]);

  const imports = await page.evaluate(() => JSON.parse(document.querySelector("script[type=importmap]").textContent).imports);
  expect(Object.keys(imports)).toContain("studio/local_path");
});
