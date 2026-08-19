const { test, expect } = require("@playwright/test");
const { blockOffsiteRequests } = require("./helpers");

// [e2e] Montserrat arrives from OUR origin, and CANNOT re-measure text after paint.
//
// WHY A BROWSER TEST AND NOT ONLY A VIEW TEST. The unit guard
// (test/lib/vendored_montserrat_test.rb) reads source: it proves the head names no
// Google host, declares two same-origin faces at font-display: optional, and that the
// woff2 files in the gem are variable fonts. None of that means the browser RECEIVES a
// usable font, and — the part no source assertion can reach — none of it means the page
// stops re-laying-out when the font lands. That second property is the entire reason
// this task exists, and it is a fact about two measurements taken at different moments.
//
// THE DEFECT, for whoever reads this next. The head used to link Montserrat from
// fonts.googleapis.com with display=swap. The stylesheet blocks the load event; the
// font FILES do not. So the page went interactive in the fallback font, then every
// glyph was re-measured when Montserrat arrived. In close-board-filter-flake that
// swallowed a synthesized click three times in one CI day: pointerdown and pointerup
// landed on different elements and the browser fired click on their common ancestor.
// The measurements from that root-cause were chip found at 45ms, clicked at 68ms.
//
// WHY THESE SPECS ARE NOT FLAKY, which is the fair question to ask of a timing test.
// Nothing here waits for the font to be fast. The third spec DELAYS the font on purpose,
// far past the point where any swap would happen, and then asserts the layout did not
// move. Under font-display: optional that is true by construction — there is no swap
// period, so a late font is abandoned for that navigation rather than applied. Under
// swap it is deterministically FALSE. The old code could only be caught by luck (five
// local reproductions came back green because the font was already cached); this
// version cannot pass by luck, because the delay removes the race instead of racing it.

const FONT_GLOB = "**/montserrat-*.woff2";

// Hold the font back long enough that it cannot land inside the ~100ms block period.
// Registered AFTER blockOffsiteRequests so this handler wins for the font URL: Playwright
// consults route handlers newest-first.
async function delayFont(page, ms) {
  await page.route(FONT_GLOB, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, ms));
    await route.continue();
  });
}

// The rendered width of a text run, not of its container. This is the quantity the
// defect actually moved: a chip is sized by its glyphs, so a box that happens to be
// constrained by its parent would hide the very thing being measured. A Range over the
// text nodes reports the glyph advance regardless of the element's box model.
const READ_TEXT_WIDTH = () => {
  const node = document.querySelector("[data-e2e-text]") || document.querySelector("p");
  const range = document.createRange();
  range.selectNodeContents(node);
  return range.getBoundingClientRect().width;
};

test("Montserrat loads from the asset pipeline, with offsite blocked", async ({ page }) => {
  const offsiteFonts = [];
  const originFonts = [];
  page.on("response", (response) => {
    if (!/\.woff2?(\?|$)/.test(response.url())) return;
    const { hostname } = new URL(response.url());
    (hostname === "127.0.0.1" || hostname === "localhost" ? originFonts : offsiteFonts).push(response.url());
  });

  await blockOffsiteRequests(page);
  await page.goto("/lab/at_time");
  await page.evaluate(() => document.fonts.ready);

  // HOW THIS PROVES THE ORIGIN RATHER THAN ASSERTING IT, exactly as the vendored-Alpine
  // spec does: blockOffsiteRequests answers every non-localhost request with an EMPTY
  // 200, so a head still pointing at fonts.gstatic.com would receive zero bytes and no
  // face could reach "loaded". Passing with the network blocked is only possible if the
  // file came from the asset pipeline.
  const state = await page.evaluate(async () => {
    await document.fonts.load("700 16px Montserrat");
    return {
      resolves: document.fonts.check("700 16px Montserrat"),
      applied: getComputedStyle(document.body).fontFamily,
      faces: [...document.fonts]
        .filter((face) => face.family === "Montserrat")
        .map((face) => ({ weight: face.weight, display: face.display })),
    };
  });

  expect(state.resolves, "the declared face never resolved to usable font data").toBe(true);
  expect(state.applied, "the page does not actually render in the family we ship").toContain("Montserrat");
  expect(originFonts.length, "no font was served by us").toBeGreaterThan(0);
  expect(offsiteFonts, `offsite font requests: ${offsiteFonts.join(", ")}`).toEqual([]);

  // The whole axis, from one variable file. Six static instances would report six
  // single-value weights here, and the head's `font-weight: 100 900` would be a claim
  // the browser was quietly working around by synthesizing.
  expect(state.faces.length).toBeGreaterThan(0);
  for (const face of state.faces) {
    expect(face.weight, "a face pins one weight — the vendored file is variable").toBe("100 900");
    expect(face.display, "font-display must be optional, or a late font can still swap").toBe("optional");
  }
});

// THE latin-ext DECISION, ASSERTED. Shipping a second 68KB subset is only free because
// unicode-range keeps a page from downloading a subset it renders no glyph from. That is
// the reasoning the head's comment gives for keeping latin-ext, and it stops being true
// the moment someone drops the unicode-range lines — at which point every page in the
// fleet quietly pays 68KB extra. Measured here rather than argued.
test("a page renders only latin, so only the latin subset is fetched", async ({ page }) => {
  const fetched = [];
  page.on("request", (request) => {
    if (/\.woff2?(\?|$)/.test(request.url())) fetched.push(request.url().split("/").pop());
  });

  await blockOffsiteRequests(page);
  await page.goto("/lab/at_time");
  await page.evaluate(() => document.fonts.ready);

  expect(fetched, "the latin subset should be fetched for a page of latin text").toContain(
    "montserrat-latin.woff2"
  );
  expect(fetched, "latin-ext was downloaded for a page with no latin-ext glyph on it").not.toContain(
    "montserrat-latin-ext.woff2"
  );
});

// THE PROPERTY THE WHOLE TASK EXISTS FOR.
//
// A late font must not change what is already on screen. The font is held back 800ms —
// an eternity next to the 68ms in which CI's synthesized click was swallowed — and the
// text is measured continuously across its arrival.
//
// NON-VACUITY IS ASSERTED, not hoped for. A spec of this shape passes for free in three
// different ways, so each is closed: the font must actually ARRIVE during the window (or
// nothing could have swapped), the measured run must be non-empty (or every sample is 0),
// and the page must actually be asking for Montserrat (or the family is irrelevant to it).
test("text is not re-measured when the font arrives after the page is interactive", async ({ page }) => {
  await blockOffsiteRequests(page);
  await delayFont(page, 800);

  const fontArrived = page.waitForResponse((response) => /montserrat-latin\.woff2/.test(response.url()));

  // domcontentloaded, not load: a preload counts toward the load event, so waiting for
  // load would wait out the very delay this spec depends on and take the first sample
  // AFTER the moment of interest.
  await page.goto("/lab/at_time", { waitUntil: "domcontentloaded" });

  const samples = await page.evaluate(
    async ({ readSrc, windowMs }) => {
      const read = new Function(`return (${readSrc})()`);
      const taken = [];
      const start = performance.now();
      while (performance.now() - start < windowMs) {
        await new Promise((resolve) => requestAnimationFrame(resolve));
        taken.push(read());
      }
      return {
        widths: taken,
        family: getComputedStyle(document.body).fontFamily,
      };
    },
    { readSrc: READ_TEXT_WIDTH.toString(), windowMs: 1600 }
  );

  await fontArrived;

  expect(samples.family, "the page never asked for Montserrat, so this spec proves nothing").toContain(
    "Montserrat"
  );
  expect(samples.widths.length, "no frames were sampled").toBeGreaterThan(10);
  expect(samples.widths[0], "the measured text run is empty, so every sample would match trivially").toBeGreaterThan(0);

  const distinct = [...new Set(samples.widths.map((w) => w.toFixed(2)))];
  expect(
    distinct,
    `the text run changed width while the page was interactive: ${distinct.join(" -> ")}. ` +
      "That is the reflow this task removed — a chip re-measured under a reader's finger. " +
      "font-display: optional must abandon a late font rather than swap it in."
  ).toHaveLength(1);
});
