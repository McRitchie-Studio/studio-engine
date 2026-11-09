// [unit] lib/studio/node_tooling: the engine's shared Node tooling package.
//
// playwright_base.js resolves the config every host's browser lane builds on;
// e2e_helpers.js decides what counts as off-origin; node_test/ lets `node --test`
// import a module by its importmap name. The hooks run in a child node, the way a
// host's `node --import <register> --test` runs them.
import { test } from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, realpathSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const require = createRequire(import.meta.url)
const TOOLING = new URL("../../lib/studio/node_tooling/", import.meta.url)
const { DEFAULTS, studioBaseURL, listenerRoot, mayReuseServer, railsWebServer, studioPlaywrightConfig } = require(fileURLToPath(new URL("playwright_base.js", TOOLING)))
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

test("a top-level name with digits maps to its file; a relative or URL specifier still falls through", () => {
  const root = mkdtempSync(join(tmpdir(), "studio-node-hooks-"))
  try {
    mkdirSync(join(root, "app/javascript"), { recursive: true })
    mkdirSync(join(root, "test/javascript/support"), { recursive: true })
    writeFileSync(join(root, "app/javascript/base58.js"), "export const encode = () => 'b58'\n")
    // topLevelDir holds the file a name-mapping of "./x.js" would land on, so a
    // hook that mapped relative specifiers by name would answer "top", not "local".
    writeFileSync(join(root, "app/javascript/x.js.js"), "export const where = 'top'\n")
    writeFileSync(join(root, "test/javascript/x.js"), "export const where = 'local'\n")
    const register = new URL("node_test/register.mjs", TOOLING).href
    writeFileSync(join(root, "test/javascript/support/register.mjs"), `
      import { registerImportmapHooks } from ${JSON.stringify(register)}
      registerImportmapHooks({
        root: new URL("../../../", import.meta.url),
        topLevelDir: "app/javascript/",
        esmDirs: ["app/javascript/", "test/javascript/"],
      })
    `)
    writeFileSync(join(root, "test/javascript/probe.js"), `
      import { encode } from "base58"
      import { where } from "./x.js"
      import { u } from "data:text/javascript,export const u = 'url'"
      process.stdout.write(encode() + " " + where + " " + u)
    `)
    const out = execFileSync(process.execPath, ["--import", "./test/javascript/support/register.mjs", "test/javascript/probe.js"], { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })
    assert.equal(out, "b58 local url")
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("a local run reuses only a server this tree started", () => {
  const root = mkdtempSync(join(tmpdir(), "studio-desk-"))
  try {
    mkdirSync(join(root, "test/dummy"), { recursive: true })
    const warnings = []
    const warn = (message) => warnings.push(message)
    const reuse = (found) => mayReuseServer({ port: "3620", root, lookup: () => found, warn })
    assert.equal(reuse({ root: null }), true, "nothing listens: nothing to refuse")
    assert.equal(reuse({ root }), true)
    assert.equal(reuse({ root: join(root, "test/dummy") }), true, "a server started from inside the tree is the tree's")
    assert.deepEqual(warnings, [])
    assert.equal(reuse({ root: `${root}-sibling` }), false, "a sibling desk's path shares the prefix but not the tree")
    assert.equal(reuse({ root: "/Users/alex/projects/studio-engine/.worktrees/another-desk" }), false)
    assert.equal(reuse({ unknown: true }), false, "a root that cannot be read is not assumed to be this one")
    assert.equal(warnings.length, 3)
    assert.match(warnings[0], /port 3620 is held by a server rooted at .*-sibling.*E2E_PORT=/)
    assert.match(warnings[2], /whose root cannot be read/)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("the server's reuse follows the listener's root, and CI never asks", () => {
  let asked = 0
  const lookup = (port) => { asked += 1; assert.equal(port, "3620"); return { root: "/elsewhere" } }
  const local = studioPlaywrightConfig({ defaultPort: "3620", env: {}, webServer: { command: "x", root: "/here", lookup } })
  assert.equal(local.webServer.reuseExistingServer, false)
  const mine = studioPlaywrightConfig({ defaultPort: "3620", env: {}, webServer: { command: "x", root: "/here", lookup: () => ({ root: "/here" }) } })
  assert.equal(mine.webServer.reuseExistingServer, true)
  const ci = studioPlaywrightConfig({ defaultPort: "3620", env: { CI: "1" }, webServer: { command: "x", lookup } })
  assert.equal(ci.webServer.reuseExistingServer, false)
  assert.equal(asked, 1)
})

test("the listener lookup reads a real server's working directory", async () => {
  const { createServer } = await import("node:net")
  const server = createServer()
  await new Promise((done) => server.listen(0, "127.0.0.1", done))
  try {
    const found = listenerRoot(String(server.address().port))
    if (found.unknown) return // no lsof on this machine; mayReuseServer then refuses, tested above
    assert.equal(realpathSync(found.root), realpathSync(process.cwd()))
  } finally {
    await new Promise((done) => server.close(done))
  }
  const free = createServer()
  await new Promise((done) => free.listen(0, "127.0.0.1", done))
  const port = String(free.address().port)
  await new Promise((done) => free.close(done))
  const none = listenerRoot(port)
  if (!none.unknown) assert.equal(none.root, null)
})

test("logOnRed prints and attaches the log for a red only, and survives an unreadable one", async () => {
  const { logOnRed, sessionLog } = require(fileURLToPath(new URL("e2e_helpers.js", TOOLING)))
  let hook
  logOnRed({ afterEach: (fn) => { hook = fn } }, async () => ["pagereveal transition", "::view-transition-old(root) pt-out-left"])
  const run = async (status, read) => {
    const attached = []
    const info = { status, expectedStatus: "passed", title: "a test", attach: async (name, body) => attached.push({ name, ...body }) }
    const logged = []
    const real = console.log
    console.log = (line) => logged.push(line)
    try { await (read || hook)({ page: {} }, info) } finally { console.log = real }
    return { attached, logged }
  }
  assert.deepEqual(await run("passed"), { attached: [], logged: [] })
  const red = await run("failed")
  assert.equal(red.attached.length, 1)
  assert.equal(red.attached[0].name, "pt-log")
  assert.equal(red.attached[0].body, "pagereveal transition\n::view-transition-old(root) pt-out-left")
  assert.match(red.logged[0], /^pt-log for "a test":\npagereveal transition/)

  let broken
  logOnRed({ afterEach: (fn) => { broken = fn } }, () => { throw new Error("context destroyed") }, { name: "event-log" })
  const unreadable = await run("timedOut", broken)
  assert.equal(unreadable.attached[0].name, "event-log")
  assert.match(unreadable.attached[0].body, /the log could not be read: context destroyed/)

  // The default reader is the sessionStorage log, by key.
  const page = { evaluate: async (fn, key) => { assert.equal(key, "pt-log"); return ["x"] } }
  assert.deepEqual(await sessionLog(page), ["x"])
})

test("the reveal waits ask the page for its reveal, never for a clock", async () => {
  const { watchReveal, revealed, settled, arrivalSettled } = require(fileURLToPath(new URL("e2e_helpers.js", TOOLING)))
  const source = readFileSync(fileURLToPath(new URL("e2e_helpers.js", TOOLING)), "utf8")
  assert.doesNotMatch(source, /waitForTimeout|setTimeout/, "a helper here waits on an event, not a pause")

  const calls = []
  const page = {
    addInitScript: async (fn) => calls.push(["init", fn.toString()]),
    locator: (selector) => ({ first: () => ({ waitFor: async (options) => calls.push(["visible", selector, options.state]) }) }),
    waitForFunction: async (fn) => calls.push(["until", fn.toString()]),
    evaluate: async (_fn, count) => calls.push(["frames", count]),
  }
  await watchReveal(page)
  assert.match(calls[0][1], /pagereveal/)
  assert.match(calls[0][1], /finished\.then/)
  calls.length = 0
  await revealed(page, '[data-test="page-b"]')
  await settled(page, '[data-test="page-b"]')
  await arrivalSettled(page, '[data-test="page-b"]')
  const kinds = calls.map(([kind]) => kind)
  assert.deepEqual(kinds, ["visible", "until", "visible", "until", "until", "visible", "until", "until", "frames"])
  assert.match(calls[1][1], /__studioReveal\.revealed === true/)
  assert.match(calls[4][1], /::view-transition/)
  assert.match(calls[7][1], /__studioReveal\.done === true/)
  assert.equal(calls[8][1], 2)

  // Every wait names the new page. With no selector, the old page's own reveal answers it
  // the moment after a click, so the wait refuses before it asks the page anything.
  calls.length = 0
  for (const wait of [revealed, settled, arrivalSettled]) {
    await assert.rejects(wait(page), /needs a selector only the new page has/)
  }
  assert.deepEqual(calls, [])
})
