// studio-engine's shared Playwright defaults.
//
// A plain object, not a defineConfig() call: this file is loaded from the gem's
// directory, which has no node_modules, so it cannot require @playwright/test.
// The host requires its own copy and wraps the result:
//
//   const { defineConfig } = require("@playwright/test");
//   const { studioPlaywrightConfig } = require("./node_modules/.studio-engine/playwright_base.js");
//   module.exports = defineConfig(studioPlaywrightConfig({
//     defaultPort: "3000",
//     webServer: { command: "bin/rails server -p $E2E_PORT" },
//   }));
//
// Every key of `overrides` replaces the default of the same name; `use` merges
// one level deep, so a host can add `reducedMotion` and keep `baseURL`.

const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const DEFAULTS = Object.freeze({
  testDir: "./e2e",
  timeout: 30_000,
  retries: 0,
  workers: 1,
});

// The base URL, from the environment first: PW_BASE_URL (or BASE_URL) points the
// lane at a stack someone else booted, and then no webServer is started.
function studioBaseURL({ defaultPort, env = process.env } = {}) {
  const port = env.E2E_PORT || String(defaultPort);
  const external = env.PW_BASE_URL || env.BASE_URL || null;
  return { port, external, baseURL: external || `http://127.0.0.1:${port}` };
}

// The working directory of whatever listens on `port`, read with lsof: { root } for a
// listener, { root: null } for none, { unknown: true } when it cannot be told (no lsof, a
// process lsof may not read).
function listenerRoot(port) {
  const run = (args) => execFileSync("lsof", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000 });
  let pids;
  try {
    pids = run(["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"]).split("\n").filter(Boolean);
  } catch (error) {
    // lsof exits 1, printing nothing, when nothing listens.
    if (error.status === 1 && !error.stdout) return { root: null };
    return { unknown: true };
  }
  if (pids.length === 0) return { root: null };
  try {
    const line = run(["-a", "-p", pids[0], "-d", "cwd", "-Fn"]).split("\n").find((entry) => entry.startsWith("n"));
    return line ? { root: line.slice(1) } : { unknown: true };
  } catch (_error) {
    return { unknown: true };
  }
}

function realpath(path) {
  try { return fs.realpathSync(path); } catch (_error) { return path; }
}

// May this run reuse the server already on `port`? Only one this tree started. Playwright's
// own check is "something answers /up", so on a shared default port one desk's run graded
// another desk's server, and its code. A server rooted outside `root`, or one whose root
// cannot be read, is refused: Playwright then stops with "is already used", and the warning
// names the server's root and the way out. Nothing listening reuses nothing either way.
function mayReuseServer({ port, root, lookup = listenerRoot, warn = console.warn }) {
  const found = lookup(port);
  if (found.root === null) return true;
  const mine = realpath(root);
  const theirs = found.unknown ? null : realpath(found.root);
  if (theirs && (theirs === mine || theirs.startsWith(`${mine}${path.sep}`))) return true;
  warn(`[studio playwright] port ${port} is held by a server ${theirs ? `rooted at ${theirs}` : "whose root cannot be read"}, ` +
    `not by this tree (${mine}), so it is not reused. Stop it if it is yours, or give this run its own port: E2E_PORT=<free port>.`);
  return false;
}

// A Rails server Playwright boots and waits on. `/up` is the Rails health check
// every app in the ecosystem keeps. Locally a running server is reused only when this
// tree started it (mayReuseServer); CI never reuses one.
function railsWebServer({ command, port, env = {}, timeout = 120_000, ci = !!process.env.CI, root = process.cwd(), lookup }) {
  if (!command) throw new Error("railsWebServer: a command is required");
  return {
    command,
    url: `http://127.0.0.1:${port}/up`,
    reuseExistingServer: !ci && mayReuseServer({ port, root, lookup }),
    timeout,
    stdout: "pipe",
    stderr: "pipe",
    env: { RAILS_ENV: "test", E2E_PORT: String(port), ...env },
  };
}

function studioPlaywrightConfig({ defaultPort, webServer, env = process.env, use = {}, ...overrides } = {}) {
  if (!defaultPort) throw new Error("studioPlaywrightConfig: defaultPort is required");
  const { port, external, baseURL } = studioBaseURL({ defaultPort, env });
  const config = {
    ...DEFAULTS,
    forbidOnly: !!env.CI,
    projects: [{ name: "chromium", use: { browserName: "chromium" } }],
    ...overrides,
    use: { baseURL, headless: true, ...use },
  };
  if (!external && webServer) {
    config.webServer = railsWebServer({ ci: !!env.CI, ...webServer, port });
  }
  return config;
}

module.exports = { DEFAULTS, studioBaseURL, listenerRoot, mayReuseServer, railsWebServer, studioPlaywrightConfig };
