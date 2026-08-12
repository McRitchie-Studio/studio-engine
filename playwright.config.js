// The studio-engine BROWSER LANE.
//
// WHY A GEM HAS ONE AT ALL. Measured across 40 merged engine feature units, 12
// (30%) add an imperative browser program — an inline <script> or a served .js —
// and ZERO have ever carried browser evidence. The hub, by comparison, is 8 of 247
// (3.2%). The client-side risk in this ecosystem CONCENTRATES in the engine, and
// until this file existed it was the one repo with no way to observe it. Two of the
// three defects that motivated the browser-evidence gate were engine-side, and both
// reached a human: a navbar that moved after paint (found by eye, on QA) and a
// re-stamper script that never executed in any browser (found in review).
//
// ================= ONE BROWSER, AND WHAT THAT CANNOT SEE =================
//
// This lane runs CHROMIUM ONLY. That is a decision with a cost, so the cost is
// written down rather than left implied.
//
// WHAT ONE ENGINE CANNOT SEE — and this is not hypothetical, it is one of the three
// motivating defects. `local-at-time-format` was a CROSS-ENGINE divergence:
// `isUS()` matched tzdb long-form zone ids, but a browser hands back the
// CLDR-CANONICAL id, and the engines disagree about which that is. Chromium and
// WebKit report America/Indianapolis; Firefox reports America/Indiana/Indianapolis.
// US readers in Indiana saw an "abroad" globe in Chrome and Safari and the correct
// bare clock in Firefox. A Chromium-only lane is STRUCTURALLY BLIND to it: V8
// canonicalizes the id before isUS() ever runs, so the spec sees the spelling that
// works and passes.
//
// WHY NOT JUST RUN THREE, THEN. Because three engines would still not close it. The
// defect needs a browser to be sitting in a specific timezone, and the lane would
// only catch it if a spec happened to pick Indiana — every other zone passes in all
// three engines. What actually closes that hole is asserting the DATA: both
// spellings of the divergent zones must be members of US_ZONES, whatever any engine
// reports. That is a property of a string table, it is true independent of any
// browser, and it belongs in a tier that runs on every PR in one second.
// test/views/at_time_zone_table_test.rb is that guard, and it is the RIGHT tier for
// this defect — not a consolation prize for the browsers this lane skips.
//
// So the split is deliberate: engine-INDEPENDENT facts are asserted in Ruby, where
// they are cheap and total; engine-DEPENDENT behavior — layout, paint, event
// ordering, does-the-script-run — is asserted here, where one engine is enough to
// answer it, because those failures are not engine-specific. Both motivating
// defects this lane is built to catch (the paint-time jump, the swallowed script)
// fail identically in every browser.
//
// NAMED, NOT HIDDEN. What this lane cannot see: rendering, CSS-support and
// Intl/locale divergence between Chromium, Firefox and WebKit. If a future defect
// is a genuine cross-engine RENDERING difference, adding projects here is a
// three-line change — and this comment is the record of why it had not been made.
//
// ================= COST =================
//
// engine-ci.yml runs ~1m20s today. This lane adds a SECOND, PARALLEL job, so the
// wall-clock a PR waits is max(existing, lane) rather than the sum. Measurements
// and the path-filter question are in docs/E2E_LANE.md.

const { defineConfig } = require("@playwright/test");

const port = process.env.E2E_PORT || "3620";
const externalBaseURL = process.env.PW_BASE_URL || process.env.BASE_URL;
const baseURL = externalBaseURL || `http://127.0.0.1:${port}`;

const config = {
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  // One worker. The lab pages are stateless, so this is not an isolation
  // requirement — it is a determinism one. The paint spec samples animation
  // frames, and frame scheduling on a loaded runner is exactly what a
  // frame-sampling assertion is sensitive to.
  workers: 1,
  forbidOnly: !!process.env.CI,
  use: {
    baseURL,
    headless: true,
  },
  // DELIBERATELY NOT `reducedMotion: "reduce"`. The hub sets it to stop Turbo view
  // transitions landing mid-click. Here it would be actively wrong: this lane's
  // sharpest spec measures whether a header MOVES between frames, and one of the
  // three ways the original defect showed itself was two headers compositing at
  // different tops DURING a view transition. Suppressing motion would suppress the
  // evidence.
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
};

if (!externalBaseURL) {
  config.webServer = {
    // A gem has no Rails root — no bin/rails, no config.ru, no config/environments.
    // e2e/boot.rb does the three jobs the hub's four-command chain does (build CSS,
    // build JS, serve) directly against test/dummy. See its header.
    command: `bundle exec ruby e2e/boot.rb`,
    url: `http://127.0.0.1:${port}/up`,
    reuseExistingServer: !process.env.CI,
    // Generous because the FIRST run compiles Tailwind. Steady-state boot is ~3s.
    timeout: 120_000,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      RAILS_ENV: "test",
      E2E_PORT: port,
    },
  };
}

module.exports = defineConfig(config);
