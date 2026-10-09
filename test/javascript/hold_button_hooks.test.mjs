// [unit] studio/hold_button_hooks: what one hold button asks its page. The
// hold-button:* events it dispatches and what a listener's answer does, the
// string locals it still evaluates against the nearest Alpine scope, and how
// the two combine. Loaded from source as a data: module.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/hold_button_hooks.js", import.meta.url), "utf8")
const { SUCCESS_SETTLE_MS, holdHooks } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

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

// Alpine as the hooks use it: $data(scope) and evaluate(scope, expression,
// { scope: extras }), which runs the expression with the scope's data and the
// extras in reach.
const fakeAlpine = () => ({
  $data: (scope) => scope.data,
  evaluate(scope, expression, extras = {}) {
    const names = { ...scope.data, ...(extras.scope || {}) }
    return new Function(...Object.keys(names), `return (${expression})`)(...Object.values(names))
  }
})

const rig = ({ dataset = {}, data = {}, alpine = true, scoped = true } = {}) => {
  const events = []
  const listeners = {}
  const timeouts = []
  const logs = { warn: [], error: [] }
  const classes = new Set()
  const scope = scoped ? { data } : null
  const button = {
    dataset: { holdId: "confirm", ...dataset },
    classes,
    classList: {
      add: (...names) => names.forEach((n) => classes.add(n)),
      remove: (...names) => names.forEach((n) => classes.delete(n))
    },
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
    setTimeout: (fn, ms) => { timeouts.push({ fn, ms }) }
  }
  if (alpine) win.Alpine = fakeAlpine()
  const on = (name, fn) => { (listeners[`hold-button:${name}`] = listeners[`hold-button:${name}`] || []).push(fn) }
  return { hooks: holdHooks(button, { win }), button, data, events, on, timeouts, logs, win }
}

const names = (events) => events.map((event) => event.type)

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
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

test("with no listener and no string local: allowed, valid, not taken over, not owned", async () => {
  const { hooks } = rig()

  assert.equal(hooks.guard(), true)
  assert.equal(await hooks.validate(), true)
  assert.equal(hooks.early(), false)
  assert.equal(hooks.completed(), false)
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

test("guard: the string is evaluated against the scope, with d and data aliased to it", () => {
  assert.equal(rig({ dataset: { guard: "data.count === 6" }, data: { count: 6 } }).hooks.guard(), true)
  assert.equal(rig({ dataset: { guard: "d.count === 6" }, data: { count: 5 } }).hooks.guard(), false)
  assert.equal(rig({ dataset: { guard: "count === 6" }, data: { count: 6 } }).hooks.guard(), true)
})

test("guard: the string and the listener must both allow", () => {
  const stringNo = rig({ dataset: { guard: "false" } })
  let asked = false
  stringNo.on("guard", () => { asked = true })
  assert.equal(stringNo.hooks.guard(), false)
  assert.equal(asked, false, "a hold the string refused asks no listener")

  const listenerNo = rig({ dataset: { guard: "true" } })
  listenerNo.on("guard", (event) => event.preventDefault())
  assert.equal(listenerNo.hooks.guard(), false)
})

test("guard: a string with no Alpine scope to run in refuses the hold", () => {
  for (const options of [{ scoped: false }, { alpine: false }]) {
    const { hooks, logs } = rig({ dataset: { guard: "true" }, ...options })
    assert.equal(hooks.guard(), false)
    assert.match(logs.warn[0], /guard: no Alpine scope/)
  }
})

test("guard: a string that throws propagates, for the hold to refuse", () => {
  const { hooks } = rig({ dataset: { guard: "missing.value" } })
  assert.throws(() => hooks.guard())
})

test("guard: without Alpine and without a string, the listener alone decides", () => {
  const { hooks, on } = rig({ alpine: false })
  assert.equal(hooks.guard(), true)
  on("guard", (event) => event.preventDefault())
  assert.equal(hooks.guard(), false)
})

// ── start ────────────────────────────────────────────────────────────────────

test("start: the on_hold_start string runs, then the event fires", () => {
  const { hooks, data, events } = rig({ dataset: { onHoldStart: "d.log.push('string')" }, data: { log: [] } })

  hooks.started()

  assert.deepEqual(data.log, ["string"])
  assert.deepEqual(names(events), ["hold-button:start"])
})

test("start: a string that throws is reported and the event still fires", () => {
  const { hooks, events, logs } = rig({ dataset: { onHoldStart: "missing.call()" } })

  assert.doesNotThrow(() => hooks.started())

  assert.match(logs.error[0], /on_hold_start threw/)
  assert.deepEqual(names(events), ["hold-button:start"])
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

test("validate: the string is awaited, with d and data aliased to the scope", async () => {
  const yes = rig({ dataset: { validate: "d.check()" }, data: { check: () => Promise.resolve(true) } })
  assert.equal(await yes.hooks.validate(), true)

  const no = rig({ dataset: { validate: "data.check()" }, data: { check: async () => false } })
  assert.equal(await no.hooks.validate(), false)

  const sync = rig({ dataset: { validate: "(d.seen = true, true)" }, data: {} })
  assert.equal(await sync.hooks.validate(), true)
  assert.equal(sync.data.seen, true)
})

test("validate: a string that rejects or does not compile rejects", async () => {
  await assert.rejects(rig({ dataset: { validate: "d.check()" }, data: { check: () => Promise.reject(new Error("blocked")) } }).hooks.validate(), /blocked/)
  await assert.rejects(rig({ dataset: { validate: "this is not js" } }).hooks.validate())
})

test("validate: the string and a listener must both say yes", async () => {
  const { hooks, on } = rig({ dataset: { validate: "true" } })
  on("validate", (event) => event.detail.waitUntil(false))
  assert.equal(await hooks.validate(), false)
})

// ── early ────────────────────────────────────────────────────────────────────

test("early: a listener's preventDefault takes the action over", () => {
  const { hooks, on } = rig()
  on("early", (event) => event.preventDefault())
  assert.equal(hooks.early(), true)
})

test("early: the string action runs and takes the hold over", () => {
  const { hooks, data } = rig({ dataset: { earlyAction: "d.log.push('early')" }, data: { log: [] } })

  assert.equal(hooks.early(), true)
  assert.deepEqual(data.log, ["early"])
})

test("early: the string action waits on its guard string", () => {
  const blocked = rig({ dataset: { earlyAction: "d.log.push('early')", earlyActionGuard: "d.web3" }, data: { log: [], web3: false } })
  assert.equal(blocked.hooks.early(), false)
  assert.deepEqual(blocked.data.log, [])

  const open = rig({ dataset: { earlyAction: "d.log.push('early')", earlyActionGuard: "d.web3" }, data: { log: [], web3: true } })
  assert.equal(open.hooks.early(), true)
  assert.deepEqual(open.data.log, ["early"])
})

test("early: a string action that throws has still taken the hold, and is reported", () => {
  const { hooks, logs } = rig({ dataset: { earlyAction: "missing.call()" } })

  assert.equal(hooks.early(), true)
  assert.match(logs.error[0], /early_action threw/)
})

test("early: the event fires whether or not a string action ran", () => {
  const withString = rig({ dataset: { earlyAction: "1" } })
  withString.hooks.early()
  assert.deepEqual(names(withString.events), ["hold-button:early"])

  const guarded = rig({ dataset: { earlyAction: "1", earlyActionGuard: "false" } })
  guarded.on("early", (event) => event.preventDefault())
  assert.equal(guarded.hooks.early(), true, "a listener may take over where the string's guard declined")
})

// ── success ──────────────────────────────────────────────────────────────────

test("success: a listener's preventDefault owns the button's state", () => {
  const { hooks, on, timeouts } = rig()
  on("success", (event) => event.preventDefault())

  assert.equal(hooks.completed(), true)
  assert.deepEqual(timeouts, [], "nothing is deferred without a string")
})

test("success: the on_success string runs half a second later and owns the state", () => {
  const { hooks, data, timeouts, events, button } = rig({ dataset: { onSuccess: "d.log.push('confirmed')" }, data: { log: [] } })

  assert.equal(hooks.completed(), true)
  assert.deepEqual(names(events), ["hold-button:success"], "the event fires at once")
  assert.deepEqual(data.log, [])
  assert.equal(SUCCESS_SETTLE_MS, 500)
  assert.equal(timeouts[0].ms, 500)

  timeouts[0].fn()
  assert.deepEqual(data.log, ["confirmed"])
  assert.equal(button.classes.has("success"), false, "the string's caller sets the button's state")
})

test("success: an on_success string that throws shows the success face and is reported", () => {
  const { hooks, timeouts, button, logs } = rig({ dataset: { onSuccess: "missing.call()" } })
  button.classList.add("process")

  hooks.completed()
  timeouts[0].fn()

  assert.match(logs.error[0], /on_success threw/)
  assert.equal(button.classes.has("success"), true)
  assert.equal(button.classes.has("process"), false)
})

test("success: an on_success string with no scope left at fire time warns and runs nothing", () => {
  const { hooks, timeouts, logs, button } = rig({ dataset: { onSuccess: "d.go()" }, scoped: false })

  assert.equal(hooks.completed(), true)
  assert.doesNotThrow(() => timeouts[0].fn())

  assert.match(logs.warn[0], /on_success: no Alpine scope/)
  assert.equal(button.classes.has("success"), false)
})
