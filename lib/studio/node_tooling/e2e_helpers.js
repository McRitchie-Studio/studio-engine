// studio-engine's shared browser-lane helpers. Requires only node: builtins, so it
// loads from the gem's directory (see README.md).

const fs = require("node:fs");

const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost"]);

function isOffOrigin(url) {
  if (!url || !/^https?:/.test(url)) return false;
  return !LOCAL_HOSTS.has(new URL(url).hostname);
}

// Collect everything the page THREW or logged as an error.
//
// `pageerror` is the cheapest detector there is for a script that never ran: the
// phantom-element defect threw a SyntaxError on every load while the response
// bytes were valid and the server-side guard passed.
//
// It hears every frame on the page, a third party's included: Playwright delivers a
// cross-origin frame's console to the page's `console` event. `ownOriginOnly: true`
// scopes that out BY ORIGIN, never by message text. A console error is dropped only
// when the script that logged it was served from another host, and a thrown error
// only when every frame of its stack was. An error with no location or no stack is
// kept, because it cannot be shown to be someone else's. The default counts
// everything.
function watchPageErrors(page, { ownOriginOnly = false } = {}) {
  const errors = [];
  page.on("pageerror", (error) => {
    if (ownOriginOnly) {
      const sources = (error.stack || "").match(/https?:\/\/[^\s)]+/g) || [];
      if (sources.length > 0 && sources.every(isOffOrigin)) return;
    }
    errors.push(`pageerror: ${error.message}`);
  });
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    if (ownOriginOnly && isOffOrigin(message.location().url)) return;
    errors.push(`console.error: ${message.text()}`);
  });
  return errors;
}

// Answer every request that leaves this origin, so the lane cannot depend on the
// public internet.
//
// ANSWERED, NOT ABORTED. route.abort() makes Chromium log `Failed to load resource:
// net::ERR_FAILED`, which watchPageErrors counts. An empty 200 logs nothing, and
// the page falls back as it would offline.
//
// `pinned` maps an off-origin URL to `{ file, contentType }`: a file loaded with
// Subresource Integrity cannot be answered empty (the digest fails and Chromium
// logs it), so it is answered with a byte-exact local copy. The response carries
// `access-control-allow-origin: *`, because a `crossorigin` tag refuses a CORS
// response without it before checking the digest.
async function blockOffsiteRequests(page, { pinned = {} } = {}) {
  await page.route("**/*", (route) => {
    const url = new URL(route.request().url());
    if (LOCAL_HOSTS.has(url.hostname)) return route.continue();

    const copy = pinned[url.href];
    if (copy) {
      return route.fulfill({
        status: 200,
        contentType: copy.contentType,
        headers: { "access-control-allow-origin": "*" },
        body: fs.readFileSync(copy.file),
      });
    }

    return route.fulfill({ status: 200, body: "" });
  });
}

module.exports = { isOffOrigin, watchPageErrors, blockOffsiteRequests };
