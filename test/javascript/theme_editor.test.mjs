// [unit] studio/theme_editor: the two theme editors' colour helpers, the CSS
// variables each writes, and the save-in-place request. Loaded from source as a
// data: module, like nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/theme_editor.js", import.meta.url), "utf8")
const {
  ROLES, normalizeHex, lightenColor, seededColors, previewProperties, stylePreviewProperties,
  formRequest, saved, themeEditor, dsThemeEditor
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

test("normalizeHex adds the #, doubles a short hex, and refuses anything else", () => {
  assert.equal(normalizeHex("#1a2B3c"), "#1a2B3c")
  assert.equal(normalizeHex(" 1a2b3c "), "#1a2b3c")
  assert.equal(normalizeHex("#abc"), "#aabbcc")
  assert.equal(normalizeHex("f0c"), "#ff00cc")
  assert.equal(normalizeHex("#12345"), null)
  assert.equal(normalizeHex("purple"), null)
  assert.equal(normalizeHex(""), null)
  assert.equal(normalizeHex(null), null)
})

test("lightenColor moves each channel toward white", () => {
  assert.equal(lightenColor("#000000", 0.3), "#4d4d4d")
  assert.equal(lightenColor("#ffffff", 0.3), "#ffffff")
  assert.equal(lightenColor("#0f172a", 0), "#0f172a")
  assert.equal(lightenColor("102030", 1), "#ffffff", "a hex with no # is read the same")
})

test("the standalone editor seeds every role, blank where the server resolved none", () => {
  assert.deepEqual(Object.keys(seededColors({ primary: "#111111" })), ROLES)
  assert.equal(seededColors({ primary: "#111111" }).primary, "#111111")
  assert.equal(seededColors({ warning: null }).warning, "")
  assert.equal(seededColors(undefined).dark, "")
})

test("the standalone preview sets the fill beside a typed colour and drops it when cleared", () => {
  const typed = Object.fromEntries(previewProperties(seededColors({ primary: "#111111", success: "#222222", warning: "#333333", danger: "#444444" })))
  assert.deepEqual(typed, {
    "--color-cta": "#111111", "--color-success": "#222222",
    "--color-warning": "#333333", "--color-danger": "#444444",
    "--color-warning-fill": "#333333", "--color-danger-fill": "#444444"
  })

  const cleared = Object.fromEntries(previewProperties(seededColors({ primary: "#111111" })))
  assert.equal(cleared["--color-warning"], "#FF7C47", "a cleared warning previews the engine default")
  assert.equal(cleared["--color-danger"], "#EF4444")
  assert.equal(cleared["--color-warning-fill"], null, "and its fill override is removed")
  assert.equal(cleared["--color-danger-fill"], null)
})

test("themeEditor: typing, resetting and normalizing repaint the document", async () => {
  const doc = fakeRoot()
  await withGlobals({ document: doc }, () => {
    const editor = themeEditor({ primary: "#111111", warning: "#333333", dark: "#000000", light: "#fafafa" })

    editor.updatePreview()
    assert.equal(doc.documentElement.style.values["--color-cta"], "#111111")
    assert.equal(doc.documentElement.style.values["--color-warning-fill"], "#333333")

    editor.colors.warning = ""
    editor.updatePreview()
    assert.equal("--color-warning-fill" in doc.documentElement.style.values, false)

    editor.resetColor("primary", "#abcdef")
    assert.equal(doc.documentElement.style.values["--color-cta"], "#abcdef")

    editor.colors.primary = "0f0"
    editor.normalizeHex("primary")
    assert.equal(editor.colors.primary, "#00ff00")
    assert.equal(doc.documentElement.style.values["--color-cta"], "#00ff00")

    editor.colors.primary = "not a colour"
    editor.normalizeHex("primary")
    assert.equal(editor.colors.primary, "not a colour", "an unreadable value is left for the operator to fix")

    assert.deepEqual(editor.darkPreviewStyle(), { backgroundColor: "#000000", borderRadius: "0" })
    assert.equal(editor.darkSurfaceStyle().backgroundColor, "#4d4d4d")
    assert.deepEqual(editor.lightPreviewStyle(), { backgroundColor: "#fafafa", borderRadius: "0" })
    assert.equal(editor.lightSurfaceStyle().backgroundColor, "#ffffff")
  })
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

test("formRequest sends the form's real method and drops the _method override", () => {
  const patch = new Map([["_method", "patch"], ["theme[primary]", "#111111"]])
  const request = formRequest(patch)
  assert.equal(request.method, "PATCH")
  assert.equal(request.body.has("_method"), false)
  assert.equal(request.body.get("theme[primary]"), "#111111")

  assert.equal(formRequest(new Map([["x", "1"]])).method, "POST")
  assert.equal(request.redirect, "manual")
})

test("saved: a 2xx or the server's own redirect; a 422 and a network-level failure are not", () => {
  assert.equal(saved({ ok: true, status: 200, type: "basic" }), true)
  assert.equal(saved({ ok: false, status: 0, type: "opaqueredirect" }), true)
  assert.equal(saved({ ok: false, status: 422, type: "basic" }), false)
  assert.equal(saved({ ok: false, status: 500, type: "basic" }), false)
})

// One save through persist(), with fetch answering `response` or rejecting.
async function save(response) {
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
    editor.saveTheme({ target: { action: "/admin/theme" } })
    during = editor.saving
    editor.saveTheme({ target: { action: "/admin/theme" } })
    await new Promise((resolve) => setTimeout(resolve, 0))
  })
  return { editor, toasts, calls, during }
}

test("dsThemeEditor: a save fetches once, in place, and toasts the outcome", async () => {
  const { editor, toasts, calls, during } = await save({ ok: true })

  assert.equal(during, true, "saving is set while the request is out")
  assert.equal(calls.length, 1, "a second submit while saving is ignored")
  assert.equal(calls[0].url, "/admin/theme")
  assert.equal(calls[0].options.method, "PATCH")
  assert.equal(editor.saving, false)
  assert.deepEqual(toasts.map((t) => [t.type, t.detail.type, t.detail.title]), [["toast", "notice", "Theme saved"]])
})

// THE DEFECT THIS PINS. The controller answers a save with a 302 to
// /admin/theme. A fetch that follows a 302 keeps a PATCH a PATCH, so it sent
// the save again, and again, until the browser gave up at twenty redirects and
// the editor toasted "Save failed" over a theme it had saved twenty-one times.
// So the redirect is not followed: it is the server's own word that it saved.
test("dsThemeEditor: the server's redirect is the success, and it is not followed", async () => {
  const { toasts, calls } = await save({ ok: false, status: 0, type: "opaqueredirect" })

  assert.equal(calls.length, 1)
  assert.equal(calls[0].options.redirect, "manual", "a followed 302 re-sends the PATCH")
  assert.deepEqual(toasts.map((t) => [t.detail.type, t.detail.title]), [["notice", "Theme saved"]])
})

test("dsThemeEditor: an HTTP error and a network failure both toast a failure and release the button", async () => {
  const refused = await save({ ok: false, status: 422 })
  assert.deepEqual(refused.toasts.map((t) => [t.detail.type, t.detail.title, t.detail.message]), [["alert", "Save failed", "HTTP 422"]])
  assert.equal(refused.editor.saving, false)

  const dropped = await save(new Error("offline"))
  assert.deepEqual(dropped.toasts.map((t) => t.detail.message), ["offline"])
  assert.equal(dropped.editor.saving, false)
})
