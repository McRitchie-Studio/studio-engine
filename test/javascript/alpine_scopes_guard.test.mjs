// [unit] The x-data factories' guard (app/views/studio/_alpine_scopes_guard.html.erb):
// which elements it answers for and the decision it makes about one, read from
// the script the partial ships. The guard is inline so that it shares no
// request with the modules it reports on, so this test runs the partial's own
// script body against a stand-in window and document;
// e2e/alpine_scopes_guard.spec.js runs it in a browser against real failed
// requests.
//
// CONTROLS, each run against this file:
//   - return "mark" before the deadline (drop the `state.now < state.deadline`
//     half): "nothing is marked before the boot has an end" fails.
//   - drop a name from the guard's NAMES: "the guard answers for every factory
//     studio/alpine_scopes publishes" fails.
//   - add an import to the script: "imports nothing" fails.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const partial = readFileSync(new URL("../../app/views/studio/_alpine_scopes_guard.html.erb", import.meta.url), "utf8")
const scopes = readFileSync(new URL("../../app/javascript/studio/alpine_scopes.js", import.meta.url), "utf8")
const opened = partial.indexOf("<%= tag.script(")
const body = partial.slice(partial.indexOf("%>", opened) + 2, partial.lastIndexOf("<% end %>"))

function boot() {
  const listeners = {}
  const window = {}
  const document = {
    readyState: "loading",
    addEventListener: (name, handler) => { (listeners[name] ||= []).push(handler) }
  }
  new Function("window", "document", body)(window, document)
  return { guard: window.studioScopesGuard, listeners, window, document }
}

test("the partial carries one script and its body is plain JavaScript", () => {
  assert.ok(opened > 0, "found no tag.script in the partial")
  assert.equal(partial.match(/tag\.script\(/g).length, 1)
  assert.ok(body.includes("studioScopesGuard"), "the slice is not the guard")
  assert.ok(!body.includes("<%"), "an ERB tag inside the script body")
  assert.ok(body.length > 1000, "the slice is too short to be the guard")
})

test("imports nothing, so no module's failure can silence it", () => {
  assert.ok(!/\bimport\s*[("'{*]/.test(body), "the guard imports a module")
  assert.ok(!/\bfetch\s*\(/.test(body), "the guard makes a request")
  assert.match(partial, /tag\.script\(nonce: local_assigns\[:nonce\]\)/)
})

test("installs once and waits for DOMContentLoaded while the page is loading", () => {
  const { guard, listeners, window, document } = boot()
  assert.equal(typeof guard.verdict, "function")
  assert.equal(listeners.DOMContentLoaded.length, 1)
  assert.equal(listeners["turbo:load"].length, 1)

  // A second copy of the script (a head Turbo re-evaluates) adds nothing.
  new Function("window", "document", body)(window, document)
  assert.equal(window.studioScopesGuard, guard)
  assert.equal(listeners.DOMContentLoaded.length, 1)
})

test("the guard answers for every factory studio/alpine_scopes publishes", () => {
  const { guard } = boot()
  const block = scopes.slice(scopes.indexOf("export const SCOPES = {"), scopes.indexOf("}", scopes.indexOf("export const SCOPES = {")))
  const published = [...block.matchAll(/^\s+(\w+): \(/gm)].map((match) => match[1])
  assert.ok(published.length >= 6, `read only ${published.length} factories out of studio/alpine_scopes`)
  assert.deepEqual([...guard.names].sort(), [...published].sort())
})

test("an x-data expression names a factory by the call it opens with", () => {
  const { guard } = boot()
  assert.equal(guard.scopeName("studioProfileForm({\"first_name\":\"Pat\"})"), "studioProfileForm")
  assert.equal(guard.scopeName("  birthdayModal({ minAge: 21 })"), "birthdayModal")
  assert.equal(guard.scopeName("imageUploadHost({\n store: 'profileModals' })"), "imageUploadHost")
  assert.equal(guard.scopeName("avatarCropperHost()"), "avatarCropperHost")
  assert.equal(guard.scopeName("cropPhotoModal({ store: 'modals' })"), "cropPhotoModal")
  assert.equal(guard.scopeName("studioBirthdayFields('1991-01-31')"), "studioBirthdayFields")
})

test("an x-data that is not one of the factories is not the guard's to judge", () => {
  const { guard } = boot()
  assert.equal(guard.scopeName(""), null)
  assert.equal(guard.scopeName(null), null)
  assert.equal(guard.scopeName("{ open: false }"), null)
  assert.equal(guard.scopeName("navCollapse()"), null)
  assert.equal(guard.scopeName("studioBoard({})"), null)
  assert.equal(guard.scopeName("myBirthdayModal()"), null)
  assert.equal(guard.scopeName("birthdayModalish()"), null)
  assert.equal(guard.verdict({ name: null, defined: false, marked: false, now: 99, deadline: 1 }), "leave")
})

test("nothing is marked before the boot has an end", () => {
  const { guard } = boot()
  const missing = { name: "birthdayModal", defined: false, marked: false }
  assert.equal(guard.verdict({ ...missing, now: 1000, deadline: null }), "wait")
  assert.equal(guard.verdict({ ...missing, now: 1000, deadline: 2500 }), "wait")
  assert.equal(guard.verdict({ ...missing, now: 2499, deadline: 2500 }), "wait")
})

test("a factory still missing once the grace is over is marked, once", () => {
  const { guard } = boot()
  assert.equal(guard.verdict({ name: "birthdayModal", defined: false, marked: false, now: 2500, deadline: 2500 }), "mark")
  assert.equal(guard.verdict({ name: "birthdayModal", defined: false, marked: true, now: 9000, deadline: 2500 }), "leave")
})

test("a healthy element is left alone, and a factory that arrives late clears the mark", () => {
  const { guard } = boot()
  assert.equal(guard.verdict({ name: "birthdayModal", defined: true, marked: false, now: 9000, deadline: 2500 }), "leave")
  assert.equal(guard.verdict({ name: "birthdayModal", defined: true, marked: false, now: 0, deadline: null }), "leave")
  assert.equal(guard.verdict({ name: "birthdayModal", defined: true, marked: true, now: 9000, deadline: 2500 }), "clear")
})

test("the grace is a second and a half", () => {
  assert.equal(boot().guard.graceMs, 1500)
})
