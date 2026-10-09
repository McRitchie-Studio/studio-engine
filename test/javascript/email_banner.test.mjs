// [unit] studio/email_banner: the placeholder rule the browser repeats from
// Studio::Banner, the Save button's two questions, the logo's three states, and
// what each factory paints. Loaded from source as a data: module, like
// nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/email_banner.js", import.meta.url), "utf8")
const {
  firstNameOf, resolveBannerText, resolveSubjectText, scrimPercent, formDirty, logoMode,
  emailBannerEditor, emailRecipients
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("the first name is the first word, and blank for no name", () => {
  assert.equal(firstNameOf("Alex McRitchie"), "Alex")
  assert.equal(firstNameOf("  Sam   Lee "), "Sam")
  assert.equal(firstNameOf(""), "")
  assert.equal(firstNameOf(null), "")
})

test("a header fills {name} and {app} for a named recipient", () => {
  assert.equal(resolveBannerText("Hi {name}, welcome to {app}", "Welcome to {app}", "Alex", "Turf"), "Hi Alex, welcome to Turf")
  assert.equal(resolveBannerText("{name} {name}", "x", "Alex", ""), "Alex Alex", "every occurrence is filled")
})

test("a header that greets by name gives way to its fallback for a nameless recipient", () => {
  assert.equal(resolveBannerText("Hi {name}, welcome to {app}", "Welcome to {app}", "", "Turf"), "Welcome to Turf")
  assert.equal(resolveBannerText("Welcome to {app}", "unused", "", "Turf"), "Welcome to Turf", "no {name}, no fallback")
  assert.equal(resolveBannerText("Hi {name}", undefined, "", "Turf"), "")
  assert.equal(resolveBannerText(undefined, undefined, "Alex", "Turf"), "")
})

test("no raw placeholder survives either path", () => {
  for (const first of ["Alex", ""]) {
    const text = resolveBannerText("Hi {name}, welcome to {app}", "Welcome to {app}", first, "Turf")
    assert.doesNotMatch(text, /[{}]/)
  }
})

test("a subject drops an unresolved {name} with the punctuation holding it", () => {
  assert.equal(resolveSubjectText("Sign in, {name}", "Alex", "Turf"), "Sign in, Alex")
  assert.equal(resolveSubjectText("Sign in, {name}", "", "Turf"), "Sign in")
  assert.equal(resolveSubjectText("{name}, your link for {app}", "", "Turf"), "your link for Turf")
  assert.equal(resolveSubjectText("Hello {name} — welcome", "", "Turf"), "Hello — welcome")
  assert.equal(resolveSubjectText("Welcome to {app}", "", "Turf"), "Welcome to Turf")
  assert.equal(resolveSubjectText(undefined, "", "Turf"), "")
})

test("the scrim is a clamped whole percentage, the default when unreadable", () => {
  assert.equal(scrimPercent("40", 55), 40)
  assert.equal(scrimPercent(140, 55), 100)
  assert.equal(scrimPercent("-3", 55), 0)
  assert.equal(scrimPercent("", 55), 55)
  assert.equal(scrimPercent(undefined, 55), 55)
})

test("dirty compares field by field, with a missing value read as blank", () => {
  assert.equal(formDirty({ a: "x", b: "" }, { a: "x", b: "" }), false)
  assert.equal(formDirty({ a: "y", b: "" }, { a: "x", b: "" }), true)
  assert.equal(formDirty({ a: "x" }, { a: "x", b: null }), false, "undefined and null are both blank")
  assert.equal(formDirty({ a: "x", extra: "new" }, { a: "x" }), false, "a field the server never sent is not an edit")
  assert.equal(formDirty({ hide: true }, { hide: false }), true, "false is not blank")
})

test("the logo has three states", () => {
  assert.equal(logoMode(true, "/up.png"), "hidden")
  assert.equal(logoMode("1", ""), "hidden")
  assert.equal(logoMode(false, "/up.png"), "custom")
  assert.equal(logoMode(false, ""), "standard")
  assert.equal(logoMode("0", ""), "standard", "the server's unchecked value is not hidden")
})

// A node that records what is written to it.
const node = (attrs = {}) => ({
  style: {},
  attrs: { ...attrs },
  getAttribute(name) { return this.attrs[name] === undefined ? null : this.attrs[name] },
  setAttribute(name, value) { this.attrs[name] = value }
})

// Alpine's magics, as far as the factories use them.
function mount(component, nodes = {}) {
  const watchers = {}
  component.$root = { querySelector: (selector) => nodes[selector] || null, querySelectorAll: (selector) => nodes[selector] || [] }
  component.$watch = (name, fn) => { watchers[name] = fn }
  component.$refs = { saveForm: { submits: 0, requestSubmit() { this.submits++ } } }
  component.init()
  return watchers
}

const editorConfig = (over = {}) => ({
  values: { header: "Welcome {name}!", header_fallback: "Welcome!", subject: "Hi {name}", subtext: "tap below", scrim_percent: "40", hide_logo: false },
  targets: [{ id: 1, name: "Alex McRitchie" }, { id: 2, name: "" }],
  targetId: 1,
  appName: "Turf",
  uploadedLogo: "",
  inheritedLogo: "/standard.png",
  defaultScrim: 55,
  ...over
})

const banner = () => ({
  "[data-banner-header]": node(), "[data-banner-subtext]": node(),
  "[data-banner-logo]": node({ src: "/old.png" }), "[data-banner-scrim]": node()
})

test("the editor paints the header, subtext, tint and logo on init", () => {
  const nodes = banner()
  const editor = emailBannerEditor(editorConfig())
  mount(editor, nodes)

  assert.equal(nodes["[data-banner-header]"].textContent, "Welcome Alex!")
  assert.equal(nodes["[data-banner-subtext]"].textContent, "tap below")
  assert.equal(nodes["[data-banner-scrim]"].style.backgroundColor, "rgba(24,16,64,0.4)")
  assert.equal(nodes["[data-banner-logo]"].attrs.src, "/standard.png")
  assert.equal(nodes["[data-banner-logo]"].style.display, "block")
  assert.equal(editor.scrimFill(), "40%")
  assert.equal(editor.subjectText(), "Hi Alex")
})

test("the editor repaints when the form or the recipient changes, and typing marks it touched", () => {
  const nodes = banner()
  const editor = emailBannerEditor(editorConfig())
  const watchers = mount(editor, nodes)

  editor.form.header = "Good to see you, {name}"
  watchers.form()
  assert.equal(nodes["[data-banner-header]"].textContent, "Good to see you, Alex")
  assert.equal(editor.touched, true)

  editor.targetId = 2
  watchers.targetId()
  assert.equal(nodes["[data-banner-header]"].textContent, "Welcome!", "a nameless recipient gets the fallback")

  editor.targetId = 99
  assert.equal(editor.firstName(), "Alex", "an unknown id falls back to the first target")
})

test("the editor hides the logo, prefers an upload, and saves only when dirty", () => {
  const nodes = banner()
  const editor = emailBannerEditor(editorConfig({ uploadedLogo: "/up.png" }))
  mount(editor, nodes)
  assert.equal(nodes["[data-banner-logo]"].attrs.src, "/up.png")
  assert.equal(editor.logoMode(), "custom")

  editor.save()
  assert.equal(editor.$refs.saveForm.submits, 0, "nothing changed, nothing is sent")

  editor.setLogoMode("hidden")
  editor.paint()
  assert.equal(nodes["[data-banner-logo]"].style.display, "none")
  assert.equal(editor.currentLogo(), "")
  assert.equal(editor.dirty(), true)
  editor.save()
  assert.equal(editor.$refs.saveForm.submits, 1)

  editor.setLogoMode("standard")
  assert.equal(editor.dirty(), false, "undoing the edit leaves nothing to save")
})

test("the editor paints a page that carries no banner without throwing", () => {
  assert.doesNotThrow(() => mount(emailBannerEditor(editorConfig({ targets: undefined, targetId: undefined }))))
})

// A row on the emails list: its templates ride on its dataset.
function row({ framed = false, loaded = true } = {}) {
  const header = node()
  const subject = node()
  const listeners = {}
  const frame = framed ? {
    dataset: {},
    contentDocument: loaded ? { querySelector: (s) => (s === "[data-banner-header]" ? header : null) } : null,
    addEventListener(name, fn) { listeners[name] = fn }
  } : null
  return {
    header, subject, frame, listeners,
    dataset: { header: "Welcome {name}!", headerFallback: "Welcome!", subject: "Sign in, {name}", emailPath: "/admin/emails/sign_in" },
    querySelector(selector) {
      if (selector === "iframe[data-email-banner-preview]") return frame
      if (selector === "[data-banner-header]") return framed ? null : header
      if (selector === "[data-row-subject]") return subject
      return null
    }
  }
}

const recipientsConfig = { targets: [{ id: 1, name: "Alex" }, { id: 2, name: "" }], targetId: 1, appName: "Turf" }

test("the list paints every row, and repaints them when the recipient changes", () => {
  const rows = [row(), row({ framed: true })]
  const list = emailRecipients(recipientsConfig)
  const watchers = mount(list, { "[data-email-row]": rows })

  assert.deepEqual(rows.map((r) => r.header.textContent), ["Welcome Alex!", "Welcome Alex!"])
  assert.deepEqual(rows.map((r) => r.subject.textContent), ["Sign in, Alex", "Sign in, Alex"])

  list.targetId = 2
  watchers.targetId()
  assert.deepEqual(rows.map((r) => r.header.textContent), ["Welcome!", "Welcome!"])
  assert.deepEqual(rows.map((r) => r.subject.textContent), ["Sign in", "Sign in"])
})

test("a framed banner that has not parsed yet is painted when its frame loads, and bound once", () => {
  const waiting = row({ framed: true, loaded: false })
  const list = emailRecipients(recipientsConfig)
  mount(list, { "[data-email-row]": [waiting] })

  assert.equal(waiting.header.textContent, undefined)
  assert.equal(waiting.subject.textContent, "Sign in, Alex", "the subject is the row's own and paints at once")
  assert.equal(waiting.frame.dataset.repaintBound, "1")

  const first = waiting.listeners.load
  list.paint()
  assert.equal(waiting.listeners.load, first, "a second paint adds no second listener")

  waiting.frame.contentDocument = { querySelector: () => waiting.header }
  waiting.listeners.load()
  assert.equal(waiting.header.textContent, "Welcome Alex!")
})

test("a frame whose document cannot be read is skipped", () => {
  const blocked = row({ framed: true })
  Object.defineProperty(blocked.frame, "contentDocument", { get() { throw new Error("cross-origin") } })
  const list = emailRecipients(recipientsConfig)

  assert.doesNotThrow(() => mount(list, { "[data-email-row]": [blocked] }))
  assert.equal(blocked.subject.textContent, "Sign in, Alex")
})

test("a click on a row opens the email, and a click on a control inside it does not", () => {
  const list = emailRecipients(recipientsConfig)
  const win = {}
  globalThis.window = win
  try {
    const plain = { target: { closest: () => null } }
    const onButton = { target: { closest: (selector) => (selector.includes("button") ? {} : null) } }

    list.openRow(onButton, row())
    assert.equal(win.location, undefined)
    list.openRow(plain, null)
    assert.equal(win.location, undefined, "a click between rows arrives with no row")
    list.openRow(plain, row())
    assert.equal(win.location, "/admin/emails/sign_in")
  } finally {
    delete globalThis.window
  }
})
