// [unit] studio/profile_form: which fields count as changed, Discard, and the
// two guards on leaving a page with changes unsaved. Loaded from source as a
// data: module, like birthday.test.mjs; the module imports nothing.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/profile_form.js", import.meta.url), "utf8")
const { LEAVE_PROMPT, fieldChanged, changeCount, studioProfileForm } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing, so the head can load it by its own tag", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("whitespace is not a change, and a blank is the same blank however it is spelled", () => {
  const initial = { first_name: "Pat", last_name: "", email: null }
  assert.equal(fieldChanged({ first_name: "  Pat " }, initial, "first_name"), false)
  assert.equal(fieldChanged({ first_name: "Patricia" }, initial, "first_name"), true)
  assert.equal(fieldChanged({ last_name: "   " }, initial, "last_name"), false)
  assert.equal(fieldChanged({ email: "" }, initial, "email"), false)
  assert.equal(fieldChanged({ email: "pat@example.com" }, initial, "email"), true)
})

test("the count is the number of fields that differ", () => {
  const initial = { first_name: "Pat", last_name: "Lee", email: "pat@example.com" }
  assert.equal(changeCount({ ...initial }, initial), 0)
  assert.equal(changeCount({ ...initial, first_name: "Sam", email: "sam@example.com" }, initial), 2)
})

// A window and document that record their listeners, and a form to guard.
const listening = (extra = {}) => {
  const listeners = {}
  return {
    listeners,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    removeEventListener(name, fn) { listeners[name] = (listeners[name] || []).filter((f) => f !== fn) },
    fire(name, event) { (listeners[name] || []).slice().forEach((fn) => fn(event)); return event },
    count: (name) => (listeners[name] || []).length,
    ...extra
  }
}

const mount = (initial, { answer = true } = {}) => {
  const asked = []
  const win = listening({ confirm(message) { asked.push(message); return answer } })
  const doc = listening()
  const form = listening()
  const scope = studioProfileForm(initial, { win, doc })
  scope.$refs = { form }
  scope.init()
  return { scope, win, doc, form, asked }
}

const leaving = () => ({ prevented: false, preventDefault() { this.prevented = true } })

test("the scope starts clean, on copies of what the page loaded with", () => {
  const initial = { first_name: "Pat" }
  const { scope } = mount(initial)
  assert.equal(scope.alpine, true)
  assert.equal(scope.dirty, false)
  assert.equal(scope.changeCount, 0)
  scope.fields.first_name = "Sam"
  assert.equal(initial.first_name, "Pat", "the caller's object is not written through")
  assert.equal(scope.initial.first_name, "Pat")
  assert.equal(scope.dirty, true)
  assert.equal(scope.changed("first_name"), true)
})

test("Discard puts every field back and the form is clean again", () => {
  const { scope } = mount({ first_name: "Pat", birthday: "1991-01-31" })
  scope.fields.first_name = "Sam"
  scope.fields.birthday = "1985-07-04"
  assert.equal(scope.changeCount, 2)
  scope.discard()
  assert.deepEqual(scope.fields, { first_name: "Pat", birthday: "1991-01-31" })
  assert.equal(scope.dirty, false)
})

test("a clean form lets the page go without a word", () => {
  const { win, doc, asked } = mount({ first_name: "Pat" })
  assert.equal(win.fire("beforeunload", leaving()).prevented, false)
  assert.equal(doc.fire("turbo:before-visit", leaving()).prevented, false)
  assert.deepEqual(asked, [])
})

test("a dirty form holds a hard navigation and asks before a Turbo visit", () => {
  const { scope, win, doc, asked } = mount({ first_name: "Pat" }, { answer: false })
  scope.fields.first_name = "Sam"

  const unload = win.fire("beforeunload", leaving())
  assert.equal(unload.prevented, true)
  assert.equal(unload.returnValue, "")

  assert.equal(doc.fire("turbo:before-visit", leaving()).prevented, true, "declined: the visit is cancelled")
  assert.deepEqual(asked, [LEAVE_PROMPT])
})

test("a Turbo visit the person confirms goes ahead", () => {
  const { scope, doc } = mount({ first_name: "Pat" }, { answer: true })
  scope.fields.first_name = "Sam"
  assert.equal(doc.fire("turbo:before-visit", leaving()).prevented, false)
})

test("submitting is not leaving: both guards drop before the form goes", () => {
  const { scope, win, doc, form, asked } = mount({ first_name: "Pat" }, { answer: false })
  scope.fields.first_name = "Sam"
  form.fire("submit", {})
  assert.equal(win.count("beforeunload"), 0)
  assert.equal(doc.count("turbo:before-visit"), 0)
  assert.equal(win.fire("beforeunload", leaving()).prevented, false)
  assert.deepEqual(asked, [])
})

test("a scope that leaves the page takes its guards with it", () => {
  const { scope, win, doc } = mount({ first_name: "Pat" })
  assert.equal(win.count("beforeunload"), 1)
  scope.destroy()
  assert.equal(win.count("beforeunload"), 0)
  assert.equal(doc.count("turbo:before-visit"), 0)
})
