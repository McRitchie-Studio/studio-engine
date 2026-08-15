const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] Alpine BOOTS, from OUR origin, at the version we pinned.
//
// WHY A BROWSER TEST AND NOT A VIEW TEST. The unit guard
// (test/lib/vendored_alpine_test.rb) reads source: it proves the head no longer names
// a CDN and that studio/alpine.js is precompiled. Neither fact means the file the
// browser receives is a working Alpine, or that anything still binds. Vendoring a
// library is exactly the change where "the markup looks right" and "the page works"
// come apart — a truncated download, a wrong build, or a missing precompile entry all
// render identical HTML and a dead page. dor-check refused the handoff for this
// reason, and it was right to.
//
// HOW THIS PROVES THE ORIGIN RATHER THAN ASSERTING IT. blockOffsiteRequests fulfils
// every non-localhost request with an EMPTY 200 — so if the head were still loading
// Alpine from jsDelivr, the script would arrive empty, window.Alpine would be
// undefined, and this test fails. Passing with the network blocked is only possible
// if Alpine came from the asset pipeline. That is the difference between checking the
// tag and checking the outcome.
//
// AND THE VERSION IS THE OTHER HALF. A vendored file can drift from the pin recorded
// in the view without anything else noticing; asserting Alpine.version catches a
// re-download at the wrong version, which is the mistake the next upgrader will make.
test("Alpine boots from the asset pipeline at the pinned version, with offsite blocked", async ({ page }) => {
  const offsiteScripts = [];
  page.on("request", (request) => {
    if (request.resourceType() !== "script") return;
    const { hostname } = new URL(request.url());
    if (hostname !== "127.0.0.1" && hostname !== "localhost") offsiteScripts.push(request.url());
  });

  await blockOffsiteRequests(page);
  await page.goto("/lab/at_time");

  // Alpine defers, so wait for it rather than racing the parser.
  await page.waitForFunction(() => Boolean(window.Alpine), null, { timeout: 10_000 });

  expect(await page.evaluate(() => window.Alpine.version)).toBe("3.16.1");

  // No script may come from anywhere but us. This is the assertion that would have
  // failed before the change, and it fails loudly rather than silently degrading.
  expect(offsiteScripts, `offsite script requests: ${offsiteScripts.join(", ")}`).toEqual([]);
});

// Booting is not the same as WORKING. Alpine can be present and still bind nothing if
// it initialises before the DOM it should walk, so this drives a real directive and
// watches the DOM change — the property every chip, drawer and board filter relies on.
test("a vendored Alpine actually binds and reacts to a directive", async ({ page }) => {
  await blockOffsiteRequests(page);
  await page.goto("/lab/at_time");
  await page.waitForFunction(() => Boolean(window.Alpine), null, { timeout: 10_000 });

  const reacted = await page.evaluate(async () => {
    const host = document.createElement("div");
    host.setAttribute("x-data", "{ open: false }");
    host.innerHTML = '<span x-show="open" data-probe>shown</span>';
    document.body.appendChild(host);
    window.Alpine.initTree(host);

    const probe = host.querySelector("[data-probe]");
    const hiddenFirst = probe.style.display === "none";
    // Flip the state through Alpine's own reactive proxy, then let the effect flush.
    window.Alpine.$data(host).open = true;
    await new Promise((resolve) => setTimeout(resolve, 50));

    return { hiddenFirst, shownAfter: probe.style.display !== "none" };
  });

  expect(reacted.hiddenFirst, "x-show must hide on the first evaluation").toBe(true);
  expect(reacted.shownAfter, "flipping the state must reveal it — this is the binding working").toBe(true);
});
