const { test, expect } = require("@playwright/test");
const { watchPageErrors, blockOffsiteRequests } = require("./helpers");

// [e2e] The Phantom mobile deep link, and the picker gate that depends on it.
//
// WHY THIS CANNOT BE A MARKUP TEST, in two parts.
//
// 1. THE SCRIPT HAS TO PARSE. This partial carries an INLINED base58 encoder,
//    moved in because turf-monster's copy reached it through a second global
//    that no other consumer has. A syntax or scoping error anywhere in that
//    IIFE is completely invisible to a String assertion — the bytes are
//    identical either way — and the failure would land at the moment a user
//    taps Connect on a phone. `window.startPhantomDeepLink = …` is the LAST
//    statement in the IIFE, so its presence in a real browser is proof the
//    whole program parsed and ran.
//
// 2. THE GATE IS A DIFFERENCE, not a string. `canDeepLink` must be false when
//    the deep link is absent and true when it is present. Both states emit the
//    same picker markup; only a browser can tell them apart. Getting this wrong
//    is what the gate exists to prevent: an app without a deep link painting a
//    single Phantom row whose tap does nothing.
test.describe("phantom deep link", () => {
  test("the inlined program parses and defines the entry point", async ({ page }) => {
    const errors = watchPageErrors(page);
    await blockOffsiteRequests(page);
    await page.goto("/lab/phantom_deeplink?deeplink=1");

    await expect
      .poll(() => page.evaluate(() => typeof window.startPhantomDeepLink))
      .toBe("function");

    expect(errors).toEqual([]);
  });

  test("CALLING it reaches the Phantom universal link", async ({ page }) => {
    // THE TEST THAT WOULD HAVE CAUGHT BOTH SHIPPED BLOCKERS, and the reason the
    // previous version did not: it asserted `typeof startPhantomDeepLink` and
    // never INVOKED it. A free variable resolves at CALL time, so an encoder
    // referencing an undefined constant parses perfectly and defines the entry
    // point — 11 view tests and a `typeof` check all green on a deep link that
    // throws the moment a user taps Connect. Parse-time mutations cannot reach
    // this class either. Only calling it can.
    const errors = watchPageErrors(page);
    await blockOffsiteRequests(page);

    // nacl is the one dependency the lane cannot load (blockOffsiteRequests
    // empties the CDN), so stub the two members the flow touches. Everything
    // else — the base58 encoder, the SIWS assembly, the localStorage handoff —
    // is the real shipped program.
    await page.addInitScript(() => {
      window.nacl = { box: { keyPair: () => ({ publicKey: new Uint8Array(32).fill(7), secretKey: new Uint8Array(64).fill(9) }) } };
    });
    await page.route("**/auth/solana/nonce", (route) =>
      route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ nonce: "abc123" }) }));

    await page.goto("/lab/phantom_deeplink?deeplink=1");

    // Capture the NAVIGATION rather than stubbing window.location — Chromium
    // refuses to redefine location.href, and watching the request is closer to
    // what actually happens anyway.
    const navigation = page.waitForRequest(
      (r) => r.url().startsWith("https://phantom.app/ul/v1/signIn"),
      { timeout: 15000 },
    );
    await page.evaluate(() => window.startPhantomDeepLink(false, null));
    const target = (await navigation).url();

    expect(target).toContain("https://phantom.app/ul/v1/signIn");
    // base58 of the stubbed 32-byte key — proves the INLINED encoder ran and
    // produced output, which is exactly what the missing constant prevented.
    expect(target).toMatch(/dapp_encryption_public_key=[1-9A-HJ-NP-Za-km-z]{20,}/);
    expect(errors).toEqual([]);
  });

  test("a page without the partial defines nothing", async ({ page }) => {
    await blockOffsiteRequests(page);
    await page.goto("/lab/phantom_deeplink");

    expect(await page.evaluate(() => typeof window.startPhantomDeepLink)).toBe("undefined");
  });

  // NOT COVERED HERE, and stated rather than left as a gap: the picker's
  // canDeepLink gate is asserted at the source level in
  // test/views/wallet_connect_picker_test.rb (mutation-verified — removing the
  // gate fails two tests), but NOT in a browser. Driving it needs the picker
  // mounted in a scoped host, and in this lab the host's outer x-if did not
  // clone its content even with the store populated, so the dialog never
  // appeared. That is a lab-harness problem, not a picker problem, and chasing
  // it further was worth less than the two proofs above — which cover the risk
  // this change actually introduced (an inlined base58 encoder that no String
  // assertion can see run). Worth doing when the next task touches this lab.
});
