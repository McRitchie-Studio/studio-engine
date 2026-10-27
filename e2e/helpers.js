// Shared helpers for the engine's browser lane.

const path = require("path");

// watchPageErrors, and the answered-not-aborted offsite block below, come from the
// engine's Node tooling package (lib/studio/node_tooling/e2e_helpers.js), the one
// every host links. Their WHY lives there.
//
// IT HEARS EVERY FRAME ON THE PAGE, a third party's included. The measured instance
// here is Google's booking frame, which logs `requestStorageAccess: Permission
// denied` from calendar.google.com on its own; specs on the booking lab pass
// `ownOriginOnly: true`.
const shared = require("../lib/studio/node_tooling/e2e_helpers.js");
const { watchPageErrors } = shared;

// Assert the lane is actually looking at a STYLED page before it measures anything
// about layout.
//
// THIS IS THE LANE'S OWN FAILURE MODE, AND IT IS THE ONE THAT WOULD BE INVISIBLE.
// Tailwind emits only the utilities it can see used. If e2e/tailwind_input.css ever
// stops scanning app/views — a moved directory, a renamed @source, a build that
// silently wrote an empty file — then `sticky` and `top-0` stop existing, every
// header lays out as ordinary static flow, and a spec asserting "the pinned header
// never moves" passes triumphantly over a page that has no pinned header at all.
// Green, meaningless, and indistinguishable from working.
//
// So every spec that measures geometry calls this FIRST. It asserts the computed
// style the CSS is supposed to produce, which is a claim about the real page rather
// than about the build.
async function expectStickyChromeIsLive(page, expect) {
  const chrome = await page.evaluate(() => {
    const header = document.querySelector("header");
    if (!header) return null;
    const style = window.getComputedStyle(header);
    return { position: style.position, top: style.top };
  });

  expect(chrome, "the lab page rendered no <header> — layouts/_navbar did not render").not.toBeNull();
  expect(
    chrome.position,
    `the header is not pinned (position: ${chrome.position}). The Tailwind build did not ` +
      "emit `sticky`, so this page cannot exhibit a paint-time offset defect and every " +
      "measurement below would be vacuously green. Check e2e/tailwind_input.css @source globs."
  ).toBe("sticky");

  return chrome;
}

// Sample a value once per animation frame, `frames` times.
//
// WHY FRAMES AND NOT A SINGLE READ. A single post-load read sees only the SETTLED
// value, and the defect this lane exists for is a value that settles CORRECTLY after
// being wrong for one or more painted frames. The hub's existing navbar spec
// (e2e/navbar_layout.spec.js) takes exactly one sample, and it would have been green
// on the broken build — it measures containment, not motion.
//
// The perturbation runs INSIDE the same evaluate as the sampling loop, so the first
// sample lands on the frame immediately after the mutation. Doing it from Node
// across two round-trips leaves an unbounded gap in which a ResizeObserver can fire
// and settle unobserved, which would hide the defect.
async function sampleAcrossFrames(page, { perturb, read, frames = 30 }) {
  return await page.evaluate(
    async ({ perturbSrc, readSrc, frames }) => {
      const perturbFn = eval(`(${perturbSrc})`);
      const readFn = eval(`(${readSrc})`);
      const samples = [];

      perturbFn();

      for (let i = 0; i < frames; i++) {
        await new Promise((resolve) => requestAnimationFrame(resolve));
        samples.push(readFn());
      }

      return samples;
    },
    { perturbSrc: perturb.toString(), readSrc: read.toString(), frames }
  );
}

// Refuse every request that leaves this origin, so the lane cannot depend on the
// public internet.
//
// WHY THIS IS NEEDED AND NOT PARANOIA. It was written for a real, measured flake:
// layouts/studio/_head — the engine's real head partial, which the lab renders on
// purpose — used to link Montserrat from fonts.gstatic.com, and a slow or refused
// fetch there surfaces to the page as `console.error: Failed to load resource`, which
// watchPageErrors counts, which fails a spec that has nothing to do with fonts.
// Measured: 2 runs in 10 on a normal connection, and the failure named the assertion
// rather than the cause.
//
// THAT PARTICULAR REQUEST IS GONE — the engine vendors Montserrat now — and the guard
// stays, because the property it holds was never about fonts. Any off-origin request
// any lab page ever grows has the same failure mode, and this is the only place that
// can close it once for all of them.
//
// ANSWERED, NOT ABORTED, and that distinction is the whole implementation. Calling
// route.abort() here fails the request, which Chromium reports to the page as
// `console.error: Failed to load resource: net::ERR_FAILED` — the same console error
// the flake produced, now fired deterministically. Measured: 3 of 9 specs red on
// every run. Answering the request with an empty 200 means nothing failed, so
// nothing is logged, and the page falls back to the next font in its stack.
//
// Filtering the message afterwards was the other candidate and is worse: it has to
// recognise a string Chromium chose, and it would also forgive a genuine 404 on an
// ENGINE asset — which is a defect this lane must fail on.
//
// THE COST THIS USED TO CARRY IS PAID OFF, and the change is worth knowing about
// because it opened a door. While Montserrat came from fonts.gstatic.com, every spec
// downstream of this helper saw the FALLBACK font, so nothing here could assert a
// measurement that depended on Montserrat's metrics. Montserrat is same-origin now, so
// it is no longer blocked — it arrives from the asset pipeline like any engine asset,
// and text measurements are fair game. e2e/vendored_montserrat.spec.js is the first
// spec to take one, and it could not have been written before.
//
// THE ONE EXCEPTION: AN OFF-ORIGIN FILE PINNED WITH INTEGRITY. studio/_cropper_assets
// loads Cropper.js 1.6.2 from cdnjs with sha384 Subresource Integrity, so an empty
// body no longer reads as "nothing happened": the digest fails, Chromium refuses the
// file and logs `Failed to find a valid digest`, which watchPageErrors counts. Those
// two URLs are answered with byte-exact copies of the real files
// (test/fixtures/files/cropperjs-1.6.2, the same bytes whose sha512 equals cdnjs's
// published SRI), so the hash matches, nothing logs, and the page exercises the tag
// exactly as shipped. test/integration/cropper_assets_sri_test.rb holds the copies
// to the pinned hashes, so a hash bump without new copies fails the unit suite
// before it fails here. A spec that needs Cropper.js absent or refused registers
// its own route after this one (the route registered last answers first).
const PINNED_FIXTURES = path.join(__dirname, "..", "test", "fixtures", "files");
const PINNED_OFFSITE = {
  "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.js": {
    file: path.join(PINNED_FIXTURES, "cropperjs-1.6.2/cropper.min.js"),
    contentType: "application/javascript",
  },
  "https://cdnjs.cloudflare.com/ajax/libs/cropperjs/1.6.2/cropper.min.css": {
    file: path.join(PINNED_FIXTURES, "cropperjs-1.6.2/cropper.min.css"),
    contentType: "text/css",
  },
};

async function blockOffsiteRequests(page) {
  await shared.blockOffsiteRequests(page, { pinned: PINNED_OFFSITE });
}

module.exports = { watchPageErrors, expectStickyChromeIsLive, sampleAcrossFrames, blockOffsiteRequests };
