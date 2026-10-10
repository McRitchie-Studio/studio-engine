// [unit] studio/hold_button_hooks: what one hold button asks its page. The
// hold-button:* events it dispatches, what a listener's answer does, and the
// refusal of a button that still carries a removed JavaScript-string hook.
// Loaded from source as a data: module.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/hold_button_hooks.js", import.meta.url), "utf8")
const { REMOVED_HOOKS, holdHooks } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

class FakeEvent {
  constructor(type, init = {}) {
    this.type = type
    this.bubbles = !!init.bubbles
    this.cancelable = !!init.cancelable
    this.detail = init.detail
    this.defaultPrevented = false
  }
  preventDefault() { if (this.cancelable) this.defaultPrevented = true }
}

// Alpine as the hooks use it: $data(scope). evaluate is a trap: the hooks must
// never reach it.
const fakeAlpine = (evaluated) => ({
  $data: (scope) => scope.data,
  evaluate(_scope, expression) { evaluated.push(expression) }
})

const rig = ({ attributes = {}, data = {}, alpine = true, scoped = true } = {}) => {
  const events = []
  const listeners = {}
  const evaluated = []
  const logs = { warn: [], error: [] }
  const scope = scoped ? { data } : null
  const held = { "data-hold-id": "confirm", ...attributes }
  const button = {
    getAttribute: (name) => (name in held ? held[name] : null),
    hasAttribute: (name) => name in held,
    closest: (selector) => (selector === "[x-data]" ? scope : null),
    dispatchEvent(event) {
      events.push(event)
      ;(listeners[event.type] || []).forEach((fn) => fn(event))
      return !event.defaultPrevented
    }
  }
  const win = {
    CustomEvent: FakeEvent,
    console: { warn: (...args) => logs.warn.push(args.join(" ")), error: (...args) => logs.error.push(args.join(" ")) },
    setTimeout: () => { throw new Error("the hooks defer nothing") }
  }
  if (alpine) win.Alpine = fakeAlpine(evaluated)
  const on = (name, fn) => { (listeners[`hold-button:${name}`] = listeners[`hold-button:${name}`] || []).push(fn) }
  return { hooks: holdHooks(button, { win }), button, data, events, on, logs, evaluated, win }
}

const names = (events) => events.map((event) => event.type)

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("the module compiles and evaluates no string", () => {
  const code = source.split("\n").filter((line) => !line.trimStart().startsWith("//")).join("\n")

  for (const banned of ["AsyncFunction", "Alpine.evaluate", ".evaluate(", ".constructor", "Function(", "eval("]) {
    assert.equal(code.includes(banned), false, `${banned} is in the module's code`)
  }
  assert.doesNotMatch(source, /AsyncFunction|Alpine\.evaluate/, "nor in its comments")
})

test("every event bubbles, can be cancelled and carries the button's hold id", () => {
  const { hooks, events } = rig()

  hooks.guard()
  hooks.started()
  hooks.validate()
  hooks.early()
  hooks.completed()

  assert.deepEqual(names(events), ["hold-button:guard", "hold-button:start", "hold-button:validate",
                                   "hold-button:early", "hold-button:success"])
  for (const event of events) {
    assert.equal(event.bubbles, true, event.type)
    assert.equal(event.cancelable, true, event.type)
    assert.equal(event.detail.id, "confirm", event.type)
  }
})

test("a button with no hold id answers as 'hold'", () => {
  const { hooks, events, button } = rig()
  button.getAttribute = () => null

  hooks.started()

  assert.equal(events[0].detail.id, "hold")
})

test("with no listener: allowed, valid, not taken over, not owned", async () => {
  const { hooks } = rig()

  assert.equal(hooks.guard(), true)
  assert.equal(await hooks.validate(), true)
  assert.equal(hooks.early(), false)
  assert.equal(hooks.completed(), false)
})

test("each hook dispatches its event exactly once", async () => {
  const { hooks, events } = rig()

  hooks.guard()
  hooks.started()
  await hooks.validate()
  hooks.early()
  hooks.completed()

  const counts = {}
  for (const event of events) counts[event.type] = (counts[event.type] || 0) + 1
  assert.deepEqual(counts, { "hold-button:guard": 1, "hold-button:start": 1, "hold-button:validate": 1,
                             "hold-button:early": 1, "hold-button:success": 1 })
})

// ── removed string hooks ─────────────────────────────────────────────────────

test("the removed hooks are the six attributes the string locals wrote", () => {
  assert.deepEqual(REMOVED_HOOKS, {
    "data-guard": ["guard", "hold-button:guard"],
    "data-on-hold-start": ["on_hold_start", "hold-button:start"],
    "data-validate": ["validate", "hold-button:validate"],
    "data-early-action": ["early_action", "hold-button:early"],
    "data-early-action-guard": ["early_action_guard", "hold-button:early"],
    "data-on-success": ["on_success", "hold-button:success"]
  })
})

test("a string hook is refused with a console error naming it and its event", () => {
  for (const [attribute, [local, event]] of Object.entries(REMOVED_HOOKS)) {
    const { hooks, events, logs, evaluated } = rig({ attributes: { [attribute]: "d.go()" } })

    assert.equal(hooks.guard(), false, attribute)
    assert.equal(logs.error.length, 1, attribute)
    assert.ok(logs.error[0].startsWith("[hold:confirm] "), logs.error[0])
    assert.ok(logs.error[0].includes(attribute), logs.error[0])
    assert.ok(logs.error[0].includes(`${local}: local`), logs.error[0])
    assert.ok(logs.error[0].includes(`answer ${event} instead`), logs.error[0])
    assert.ok(logs.error[0].includes("The hold is refused."), logs.error[0])
    assert.deepEqual(events, [], "a refused press asks no listener")
    assert.deepEqual(evaluated, [], "and evaluates nothing")
  }
})

test("a string hook is refused on every press, an empty one included, each hook named", () => {
  const { hooks, logs, on } = rig({ attributes: { "data-guard": "", "data-on-success": "go()" } })
  let asked = 0
  on("guard", () => { asked += 1 })

  assert.equal(hooks.guard(), false)
  assert.equal(hooks.guard(), false)

  assert.equal(logs.error.length, 4)
  assert.ok(logs.error[0].includes("data-guard"))
  assert.ok(logs.error[1].includes("data-on-success"))
  assert.equal(asked, 0)
})

test("no hook evaluates the text a removed attribute carries", async () => {
  const attributes = Object.fromEntries(Object.keys(REMOVED_HOOKS).map((name) => [name, "globalThis.__holdEvaluated = true"]))
  const { hooks, evaluated } = rig({ attributes })

  hooks.guard()
  hooks.started()
  await hooks.validate()
  hooks.early()
  hooks.completed()

  assert.deepEqual(evaluated, [])
  assert.equal(globalThis.__holdEvaluated, undefined)
})

test("the timing attributes are not hooks", () => {
  const { hooks, logs } = rig({ attributes: { "data-validate-at": "150", "data-early-action-at": "400", "data-duration": "600" } })

  assert.equal(hooks.guard(), true)
  assert.deepEqual(logs.error, [])
})

// ── guard ────────────────────────────────────────────────────────────────────

test("guard: a listener's preventDefault refuses the hold", () => {
  const { hooks, on } = rig()
  on("guard", (event) => event.preventDefault())
  assert.equal(hooks.guard(), false)
})

test("guard: the scope's submitting flag refuses the hold before anything is asked", () => {
  const { hooks, events } = rig({ data: { submitting: true } })

  assert.equal(hooks.guard(), false)
  assert.deepEqual(events, [], "no guard event for a press that is refused outright")
})

test("guard: without Alpine or without a scope, the listener alone decides", () => {
  for (const options of [{ alpine: false }, { scoped: false }]) {
    const { hooks, on } = rig({ data: { submitting: true }, ...options })
    assert.equal(hooks.guard(), true)
    on("guard", (event) => event.preventDefault())
    assert.equal(hooks.guard(), false)
  }
})

// ── validate ─────────────────────────────────────────────────────────────────

test("validate: a listener answers through waitUntil, with a value or a promise", async () => {
  const yes = rig()
  yes.on("validate", (event) => event.detail.waitUntil(Promise.resolve(true)))
  assert.equal(await yes.hooks.validate(), true)

  const no = rig()
  no.on("validate", (event) => event.detail.waitUntil(false))
  assert.equal(await no.hooks.validate(), false)

  const failed = rig()
  failed.on("validate", (event) => event.detail.waitUntil(Promise.reject(new Error("geo"))))
  await assert.rejects(failed.hooks.validate(), /geo/)
})

test("validate: every answer must be a yes", async () => {
  const { hooks, on } = rig()
  on("validate", (event) => event.detail.waitUntil(true))
  on("validate", (event) => event.detail.waitUntil(Promise.resolve(false)))
  assert.equal(await hooks.validate(), false)
})

// ── early ────────────────────────────────────────────────────────────────────

test("early: a listener's preventDefault takes the action over", () => {
  const { hooks, on } = rig()
  on("early", (event) => event.preventDefault())
  assert.equal(hooks.early(), true)
})

// ── success ──────────────────────────────────────────────────────────────────

test("success: a listener's preventDefault owns the button's state", () => {
  const { hooks, on } = rig()
  on("success", (event) => event.preventDefault())

  assert.equal(hooks.completed(), true)
})
