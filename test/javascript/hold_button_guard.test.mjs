// [unit] The hold button's guard (app/views/studio/_hold_button_guard.html.erb):
// the decision it makes about one stack, read from the script the partial
// ships. The guard is inline so that it shares no request with the modules it
// reports on, so this test runs the partial's own script body against a
// stand-in window and document; e2e/hold_button_guard.spec.js runs it in a
// browser against real failed requests.
//
// CONTROLS, each run against this file:
//   - return "mark" before the deadline (drop the `state.now < state.deadline`
//     half): "nothing is marked before the boot has an end" fails.
//   - return "leave" for a connected, marked stack: "a late connect clears"
//     fails.
//   - add an import to the script: "imports nothing" fails.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const partial = readFileSync(new URL("../../app/views/studio/_hold_button_guard.html.erb", import.meta.url), "utf8")
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
  return { guard: window.studioHoldButtonGuard, listeners, window, document }
}

test("the partial carries one script and its body is plain JavaScript", () => {
  assert.ok(opened > 0, "found no tag.script in the partial")
  assert.equal(partial.match(/tag\.script\(/g).length, 1)
  assert.ok(body.includes("studioHoldButtonGuard"), "the slice is not the guard")
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
  assert.equal(listeners.mousedown.length, 1)
  assert.equal(listeners.touchstart.length, 1)

  // A second copy of the script (a head Turbo re-evaluates) adds nothing.
  new Function("window", "document", body)(window, document)
  assert.equal(window.studioHoldButtonGuard, guard)
  assert.equal(listeners.DOMContentLoaded.length, 1)
})

test("publishes the grace it waits after DOMContentLoaded", () => {
  const { guard } = boot()
  assert.equal(guard.graceMs, 1500)
})

test("nothing is marked before the boot has an end", () => {
  const { verdict } = boot().guard
  assert.equal(verdict({ connected: false, marked: false, now: 5_000, deadline: null }), "wait")
  assert.equal(verdict({ connected: false, marked: false, now: 5_000, deadline: 5_001 }), "wait")
})

test("an unconnected stack is marked once the deadline has passed", () => {
  const { verdict } = boot().guard
  assert.equal(verdict({ connected: false, marked: false, now: 5_001, deadline: 5_001 }), "mark")
  assert.equal(verdict({ connected: false, marked: false, now: 9_000, deadline: 5_001 }), "mark")
})

test("a marked stack that is still unconnected is left as it is", () => {
  const { verdict } = boot().guard
  assert.equal(verdict({ connected: false, marked: true, now: 9_000, deadline: 5_001 }), "leave")
})

test("a connected stack is never marked, before or after the deadline", () => {
  const { verdict } = boot().guard
  assert.equal(verdict({ connected: true, marked: false, now: 0, deadline: null }), "leave")
  assert.equal(verdict({ connected: true, marked: false, now: 9_000, deadline: 5_001 }), "leave")
})

test("a late connect clears the mark", () => {
  const { verdict } = boot().guard
  assert.equal(verdict({ connected: true, marked: true, now: 9_000, deadline: 5_001 }), "clear")
})
