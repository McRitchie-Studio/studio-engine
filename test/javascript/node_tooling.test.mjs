// [unit] lib/studio/node_tooling: the engine's shared Node tooling package.
//
// playwright_base.js resolves the config every host's browser lane builds on;
// e2e_helpers.js decides what counts as off-origin; node_test/ lets `node --test`
// import a module by its importmap name. The hooks run in a child node, the way a
// host's `node --import <register> --test` runs them.
import { test } from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const require = createRequire(import.meta.url)
const TOOLING = new URL("../../lib/studio/node_tooling/", import.meta.url)
const { DEFAULTS, studioBaseURL, railsWebServer, studioPlaywrightConfig } = require(fileURLToPath(new URL("playwright_base.js", TOOLING)))
const { isOffOrigin, blockOffsiteRequests } = require(fileURLToPath(new URL("e2e_helpers.js", TOOLING)))

test("the base is one chromium worker collecting ./e2e, booting Rails on /up", () => {
  const config = studioPlaywrightConfig({ defaultPort: "3000", env: {}, webServer: { command: "bin/rails s" } })
  assert.equal(config.testDir, "./e2e")
  assert.equal(config.workers, 1)
  assert.equal(config.retries, 0)
  assert.equal(config.timeout, 30_000)
  assert.equal(config.forbidOnly, false)
  assert.deepEqual(config.projects, [{ name: "chromium", use: { browserName: "chromium" } }])
  assert.deepEqual(config.use, { baseURL: "http://127.0.0.1:3000", headless: true })
  assert.equal(config.webServer.url, "http://127.0.0.1:3000/up")
  assert.equal(config.webServer.command, "bin/rails s")
  assert.deepEqual(config.webServer.env, { RAILS_ENV: "test", E2E_PORT: "3000" })
})

test("CI forbids .only and never reuses a server", () => {
  const config = studioPlaywrightConfig({ defaultPort: "3000", env: { CI: "1" }, webServer: { command: "x" } })
  assert.equal(config.forbidOnly, true)
  assert.equal(config.webServer.reuseExistingServer, false)
})

test("E2E_PORT moves the base URL and the server together", () => {
  const config = studioPlaywrightConfig({ defaultPort: "3000", env: { E2E_PORT: "3123" }, webServer: { command: "x" } })
  assert.equal(config.use.baseURL, "http://127.0.0.1:3123")
  assert.equal(config.webServer.url, "http://127.0.0.1:3123/up")
  assert.equal(config.webServer.env.E2E_PORT, "3123")
})

test("an external base URL boots no server", () => {
  for (const env of [{ PW_BASE_URL: "https://qa.example" }, { BASE_URL: "https://qa.example" }]) {
    const config = studioPlaywrightConfig({ defaultPort: "3000", env, webServer: { command: "x" } })
    assert.equal(config.use.baseURL, "https://qa.example")
    assert.equal(config.webServer, undefined)
  }
  assert.equal(studioBaseURL({ defaultPort: 3000, env: {} }).external, null)
})

test("a host overrides a default and merges `use` one level deep", () => {
  const config = studioPlaywrightConfig({ defaultPort: "3100", env: {}, retries: 2, use: { reducedMotion: "reduce" } })
  assert.equal(config.retries, 2)
  assert.equal(config.workers, DEFAULTS.workers)
  assert.deepEqual(config.use, { baseURL: "http://127.0.0.1:3100", headless: true, reducedMotion: "reduce" })
})

test("the base refuses a config with no port and a server with no command", () => {
  assert.throws(() => studioPlaywrightConfig({ env: {} }), /defaultPort is required/)
  assert.throws(() => railsWebServer({ port: "3000" }), /command is required/)
})

test("only 127.0.0.1 and localhost are this origin", () => {
  assert.equal(isOffOrigin("http://127.0.0.1:3620/x.js"), false)
  assert.equal(isOffOrigin("http://localhost:3000/"), false)
  assert.equal(isOffOrigin("https://calendar.google.com/x"), true)
  assert.equal(isOffOrigin(""), false)
  assert.equal(isOffOrigin("data:text/javascript,1"), false)
})

test("an offsite request is answered empty, a pinned one with its copy, a local one passes", async () => {
  const dir = mkdtempSync(join(tmpdir(), "studio-node-tooling-"))
  try {
    writeFileSync(join(dir, "lib.js"), "window.ok = 1")
    let handler
    const page = { route: async (_pattern, fn) => { handler = fn } }
    await blockOffsiteRequests(page, { pinned: { "https://cdn.example/lib.js": { file: join(dir, "lib.js"), contentType: "application/javascript" } } })

    const answer = (url) => {
      const seen = {}
      handler({ request: () => ({ url: () => url }), continue: () => { seen.continued = true }, fulfill: (r) => { seen.fulfilled = r } })
      return seen
    }
    assert.deepEqual(answer("http://127.0.0.1:3620/a.js"), { continued: true })
    assert.deepEqual(answer("https://fonts.example/a.woff2").fulfilled, { status: 200, body: "" })
    const pinned = answer("https://cdn.example/lib.js").fulfilled
    assert.equal(pinned.contentType, "application/javascript")
    assert.equal(pinned.headers["access-control-allow-origin"], "*")
    assert.equal(pinned.body.toString(), "window.ok = 1")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test("the hooks resolve a host's importmap prefixes and top-level names as ES modules", () => {
  const root = mkdtempSync(join(tmpdir(), "studio-node-hooks-"))
  try {
    mkdirSync(join(root, "app/javascript/board"), { recursive: true })
    mkdirSync(join(root, "test/javascript/support"), { recursive: true })
    writeFileSync(join(root, "app/javascript/board/colors.js"), "export const red = 'r'\n")
    writeFileSync(join(root, "app/javascript/board/cards.js"), "import { red } from 'board/colors'\nexport const card = red + 'c'\n")
    writeFileSync(join(root, "app/javascript/chat_follow.js"), "export const follow = 'f'\n")
    const register = new URL("node_test/register.mjs", TOOLING).href
    writeFileSync(join(root, "test/javascript/support/register.mjs"), `
      import { registerImportmapHooks } from ${JSON.stringify(register)}
      registerImportmapHooks({
        root: new URL("../../../", import.meta.url),
        prefixes: { board: "app/javascript/board/" },
        topLevelDir: "app/javascript/",
        esmDirs: ["app/javascript/", "test/javascript/"],
      })
    `)
    writeFileSync(join(root, "test/javascript/probe.js"), `
      import { card } from "board/cards"
      import { follow } from "chat_follow"
      process.stdout.write(card + follow)
    `)
    const out = execFileSync(process.execPath, ["--import", "./test/javascript/support/register.mjs", "test/javascript/probe.js"], { cwd: root, encoding: "utf8" })
    assert.equal(out, "rcf")

    // Control: without the hooks the same file cannot even resolve "board/cards".
    assert.throws(() => execFileSync(process.execPath, ["test/javascript/probe.js"], { cwd: root, stdio: "pipe" }))
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
