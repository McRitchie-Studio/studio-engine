// [unit] studio/theme_editor: the theme editor's CSS variables, and the save-in-place request. Loaded from source as a
// data: module, like nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/theme_editor.js", import.meta.url), "utf8")
const {
  stylePreviewProperties, formRequest, saved, failureReason, SIGNED_OUT, dsThemeEditor
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

// The root's inline style, as the factories write it.
function fakeRoot() {
  const style = {
    values: {},
    setProperty(name, value) { this.values[name] = value },
    removeProperty(name) { delete this.values[name] }
  }
  return { documentElement: { style } }
}

// Runs `run` (sync or async) with `globals` on globalThis, and puts back what
// was there once it has finished.
async function withGlobals(globals, run) {
  const before = {}
  for (const name of Object.keys(globals)) { before[name] = globalThis[name]; globalThis[name] = globals[name] }
  try { return await run() } finally {
    for (const name of Object.keys(globals)) {
      if (before[name] === undefined) delete globalThis[name]; else globalThis[name] = before[name]
    }
  }
}

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("the style guide's preview sets the cta fill and only what has a value", () => {
  assert.deepEqual(Object.fromEntries(stylePreviewProperties({ primary: "#111111", success: "", warning: "#333333", danger: "" })), {
    "--color-cta": "#111111", "--color-cta-fill": "#111111",
    "--color-warning": "#333333", "--color-warning-fill": "#333333"
  })
})

test("dsThemeEditor: the seed overrides the defaults one role at a time", () => {
  const editor = dsThemeEditor({ primary: "#123456" })
  assert.equal(editor.colors.primary, "#123456")
  assert.equal(editor.colors.accent, "#6366F1")
  assert.equal(dsThemeEditor().colors.primary, "#000")
})

test("formRequest sends the form's real method, asks for JSON, and follows no redirect", () => {
  const patch = new Map([["_method", "patch"], ["theme[primary]", "#111111"]])
  const request = formRequest(patch)
  assert.equal(request.method, "PATCH")
  assert.equal(request.body.has("_method"), false)
  assert.equal(request.body.get("theme[primary]"), "#111111")

  assert.equal(formRequest(new Map([["x", "1"]])).method, "POST")
  assert.equal(request.redirect, "manual")
  assert.deepEqual(request.headers, { Accept: "application/json" })
})

test("saved: only a 2xx from the request itself; a redirect, a 4xx and a 5xx are not", () => {
  assert.equal(saved({ ok: true, status: 204, type: "basic" }), true)
  assert.equal(saved({ ok: true, status: 200, type: "basic" }), true)
  assert.equal(saved({ ok: false, status: 0, type: "opaqueredirect" }), false)
  assert.equal(saved({ ok: false, status: 401, type: "basic" }), false)
  assert.equal(saved({ ok: false, status: 422, type: "basic" }), false)
  assert.equal(saved({ ok: false, status: 500, type: "basic" }), false)
})

test("failureReason: a redirect or a 401 is the sign-in bounce; anything else names its status", () => {
  assert.equal(failureReason({ ok: false, status: 0, type: "opaqueredirect" }), SIGNED_OUT)
  assert.equal(failureReason({ ok: false, status: 401, type: "basic" }), SIGNED_OUT)
  assert.equal(failureReason({ ok: false, status: 422, type: "basic" }), "HTTP 422")
})

// One save through persist(), with fetch answering `response` or rejecting.
async function save(response, action = "saveTheme") {
  const toasts = []
  const calls = []
  const globals = {
    FormData: class { constructor() { return new Map([["_method", "patch"]]) } },
    fetch: (url, options) => { calls.push({ url, options }); return response instanceof Error ? Promise.reject(response) : Promise.resolve(response) },
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init.detail } },
    window: { dispatchEvent: (event) => toasts.push(event) }
  }
  const editor = dsThemeEditor()
  let during
  await withGlobals(globals, async () => {
    editor[action]({ target: { action: "/admin/theme" } })
    during = editor.saving
    editor[action]({ target: { action: "/admin/theme" } })
    await new Promise((resolve) => setTimeout(resolve, 0))
  })
  return { editor, toasts, calls, during }
}

test("dsThemeEditor: a save fetches once, in place, and toasts the outcome", async () => {
  const { editor, toasts, calls, during } = await save({ ok: true, status: 204 })

  assert.equal(during, true, "saving is set while the request is out")
  assert.equal(calls.length, 1, "a second submit while saving is ignored")
  assert.equal(calls[0].url, "/admin/theme")
  assert.equal(calls[0].options.method, "PATCH")
  assert.equal(editor.saving, false)
  assert.deepEqual(toasts.map((t) => [t.type, t.detail.type, t.detail.title]), [["toast", "notice", "Theme saved"]])
})

// A save that an ended session bounces to sign-in arrives as an opaque
// redirect, because the fetch follows none. Nothing was written, so it is a
// failure, and the one PATCH is not sent again.
test("dsThemeEditor: an opaque redirect that is the sign-in bounce is not a save", async () => {
  const { editor, toasts, calls } = await save({ ok: false, status: 0, type: "opaqueredirect" })

  assert.equal(calls.length, 1, "one PATCH, never re-sent")
  assert.equal(calls[0].options.redirect, "manual", "a followed 302 re-sends the PATCH")
  assert.deepEqual(toasts.map((t) => [t.detail.type, t.detail.title, t.detail.message]), [["alert", "Save failed", SIGNED_OUT]])
  assert.equal(editor.saving, false)
})

test("dsThemeEditor: Regenerate claims the cache cleared only on a 2xx", async () => {
  const cleared = await save({ ok: true, status: 204 }, "regenerate")
  assert.deepEqual(cleared.toasts.map((t) => [t.detail.type, t.detail.title]), [["notice", "Theme cache cleared"]])

  const bounced = await save({ ok: false, status: 0, type: "opaqueredirect" }, "regenerate")
  assert.equal(bounced.calls.length, 1)
  assert.deepEqual(bounced.toasts.map((t) => [t.detail.type, t.detail.title]), [["alert", "Save failed"]])
})

test("dsThemeEditor: an HTTP error and a network failure both toast a failure and release the button", async () => {
  const refused = await save({ ok: false, status: 422 })
  assert.deepEqual(refused.toasts.map((t) => [t.detail.type, t.detail.title, t.detail.message]), [["alert", "Save failed", "HTTP 422"]])
  assert.equal(refused.editor.saving, false)

  const dropped = await save(new Error("offline"))
  assert.deepEqual(dropped.toasts.map((t) => t.detail.message), ["offline"])
  assert.equal(dropped.editor.saving, false)
})
