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

// A Rails server Playwright boots and waits on. `/up` is the Rails health check
// every app in the ecosystem keeps.
function railsWebServer({ command, port, env = {}, timeout = 120_000, ci = !!process.env.CI }) {
  if (!command) throw new Error("railsWebServer: a command is required");
  return {
    command,
    url: `http://127.0.0.1:${port}/up`,
    reuseExistingServer: !ci,
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

module.exports = { DEFAULTS, studioBaseURL, railsWebServer, studioPlaywrightConfig };
