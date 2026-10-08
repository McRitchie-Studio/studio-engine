// [unit] studio/hold_button: one hold's timeline (guard, start, validate, early,
// completion), what a release and a second press do to it, and the idle nudge.
// Loaded from source as a data: module, like modal_host.test.mjs. The fizz
// portal is geometry and observers, so it is e2e/hold_button.spec.js's.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/hold_button.js", import.meta.url), "utf8")
const {
  DEFAULT_DURATION_MS, DEFAULT_VALIDATE_AT_MS, DEFAULT_EARLY_AT_MS, NUDGE_FIRST_S, NUDGE_REPEAT_S, FIZZ_SLOTS,
  holdConfig, Hold, NudgeCycle, installHoldButton
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

// Timers the test turns by hand, in due order.
const fakeTimers = () => {
  let now = 0
  let seq = 0
  let queue = []
  const add = (fn, ms, every) => { queue.push({ fn, at: now + ms, every, id: seq += 1 }); return seq }
  const drop = (id) => { queue = queue.filter((t) => t.id !== id) }
  return {
    setTimeout: (fn, ms) => add(fn, ms || 0, null),
    clearTimeout: drop,
    setInterval: (fn, ms) => add(fn, ms, ms),
    clearInterval: drop,
    pending: () => queue.length,
    advance(ms) {
      const until = now + ms
      for (;;) {
        const due = queue.filter((t) => t.at <= until).sort((a, b) => a.at - b.at || a.id - b.id)[0]
        if (!due) break
        now = due.at
        if (due.every) due.at += due.every
        else drop(due.id)
        due.fn()
      }
      now = until
    }
  }
}

// The button as the partial renders it: classes, data attributes, the progress
// ring and the nudge ring.
const fakeButton = (dataset = {}) => {
  const classes = new Set()
  const fill = { style: {} }
  const count = { textContent: "" }
  const circle = { style: {}, offsetWidth: 0 }
  const debug = { querySelector: (sel) => (sel === "circle.fill" ? fill : count) }
  return {
    dataset: { holdId: "confirm", duration: "600", validateAt: "150", earlyActionAt: "400", ...dataset },
    classes,
    fill,
    count,
    properties: {},
    offsetWidth: 0,
    classList: {
      add: (...names) => names.forEach((n) => classes.add(n)),
      remove: (...names) => names.forEach((n) => classes.delete(n)),
      contains: (n) => classes.has(n)
    },
    style: { setProperty(name, value) { this[name] = value } },
    querySelector: (sel) => (sel === "svg.progress circle" ? circle : sel === ".nudge-debug" ? debug : null)
  }
}

const hold = (hooks = {}, dataset = {}) => {
  const timers = fakeTimers()
  const button = fakeButton(dataset)
  const reports = []
  const log = []
  const recorded = {}
  for (const name of ["guard", "started", "validate", "early", "completed"]) {
    const answer = hooks[name]
    if (name in hooks || name === "started" || name === "completed") {
      recorded[name] = () => { log.push(name); return typeof answer === "function" ? answer() : answer }
    }
  }
  const subject = new Hold(button, recorded, { timers, report: (what, error) => reports.push([what, error]) })
  return { subject, button, timers, log, reports }
}

// Lets a settled promise's handlers run.
const settle = () => new Promise((resolve) => setImmediate(resolve))

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("a button's timing comes from its data attributes, with the partial's defaults", () => {
  assert.deepEqual(holdConfig({ holdId: "desktop", duration: "2000", validateAt: "750", earlyActionAt: "1500" }),
                   { id: "desktop", duration: 2000, validateAt: 750, earlyAt: 1500 })
  assert.deepEqual(holdConfig({}), { id: "hold", duration: 2000, validateAt: 750, earlyAt: 1500 })
  assert.deepEqual(holdConfig(undefined), { id: "hold", duration: 2000, validateAt: 750, earlyAt: 1500 })
  assert.equal(holdConfig({ duration: "soon" }).duration, 2000)
  assert.deepEqual([DEFAULT_DURATION_MS, DEFAULT_VALIDATE_AT_MS, DEFAULT_EARLY_AT_MS], [2000, 750, 1500])
  assert.equal(FIZZ_SLOTS, 18)
})

test("a press held to term completes once, at its duration and not before", () => {
  const { subject, button, timers, log } = hold()

  assert.equal(subject.start(), true)
  assert.deepEqual(log, ["started"])
  assert.equal(button.classes.has("process"), true)
  assert.equal(button.style["--duration"], "600ms")

  timers.advance(599)
  assert.equal(log.includes("completed"), false, "not one millisecond early")
  assert.equal(button.classes.has("success"), false)

  timers.advance(1)
  assert.deepEqual(log, ["started", "completed"])
  assert.equal(button.classes.has("success"), true)
  assert.equal(button.classes.has("process"), false)

  timers.advance(10_000)
  assert.equal(log.filter((name) => name === "completed").length, 1)
})

test("a release before the duration ends the hold and nothing completes", () => {
  const { subject, button, timers, log } = hold({ validate: true, early: false })

  subject.start()
  timers.advance(100)
  subject.end()
  assert.equal(button.classes.has("process"), false)
  assert.equal(subject.holding, false)

  timers.advance(10_000)
  assert.deepEqual(log, ["started"], "no validate, no early action and no completion after a release")
  assert.equal(button.classes.has("success"), false)
})

test("a guard that says no refuses the press: nothing starts", () => {
  const { subject, button, timers, log } = hold({ guard: false })

  assert.equal(subject.start(), false)
  timers.advance(10_000)

  assert.deepEqual(log, ["guard"])
  assert.equal(button.classes.has("process"), false)
  assert.equal(button.classes.has("success"), false)
})

test("a guard that throws refuses the press and is reported", () => {
  const { subject, timers, log, reports } = hold({ guard: () => { throw new Error("no scope") } })

  assert.equal(subject.start(), false)
  timers.advance(10_000)

  assert.deepEqual(log, ["guard"])
  assert.match(reports[0][0], /guard threw/)
})

test("a guard that says yes lets the hold run", () => {
  const { subject, timers, log } = hold({ guard: true })
  assert.equal(subject.start(), true)
  timers.advance(600)
  assert.deepEqual(log, ["guard", "started", "completed"])
})

test("the hooks fire in order, each at its own time", () => {
  const { subject, timers, log } = hold({ validate: true, early: false })

  subject.start()
  timers.advance(149)
  assert.deepEqual(log, ["started"])
  timers.advance(1)
  assert.deepEqual(log, ["started", "validate"])
  timers.advance(249)
  assert.deepEqual(log, ["started", "validate"])
  timers.advance(1)
  assert.deepEqual(log, ["started", "validate", "early"])
  timers.advance(200)
  assert.deepEqual(log, ["started", "validate", "early", "completed"], "an early hook that declines leaves the hold to complete")
})

test("an early action that is taken cancels the completion", () => {
  const { subject, button, timers, log } = hold({ early: true })

  subject.start()
  timers.advance(10_000)

  assert.deepEqual(log, ["started", "early"])
  assert.equal(button.classes.has("success"), false)
  assert.equal(button.classes.has("process"), true, "the button stays in its holding state for the action to resolve")
})

test("an early hook that throws takes nothing over: the hold still completes", () => {
  const { subject, timers, log, reports } = hold({ early: () => { throw new Error("boom") } })

  subject.start()
  timers.advance(600)

  assert.deepEqual(log, ["started", "early", "completed"])
  assert.match(reports[0][0], /early threw/)
})

test("validation that answers false aborts the hold", async () => {
  const { subject, button, timers, log } = hold({ validate: () => Promise.resolve(false) })

  subject.start()
  timers.advance(150)
  await settle()

  assert.equal(button.classes.has("process"), false)
  assert.equal(subject.holding, false)
  timers.advance(10_000)
  assert.deepEqual(log, ["started", "validate"], "no early action and no completion after an abort")
  assert.equal(button.classes.has("success"), false)
})

test("validation that rejects, or throws, aborts the hold and is reported", async () => {
  for (const validate of [() => Promise.reject(new Error("geo")), () => { throw new Error("sync") }]) {
    const { subject, button, timers, log, reports } = hold({ validate })

    subject.start()
    timers.advance(150)
    await settle()
    timers.advance(10_000)

    assert.deepEqual(log, ["started", "validate"])
    assert.equal(button.classes.has("success"), false)
    assert.match(reports[0][0], /validate failed/)
  }
})

test("validation that answers true, sync or async, lets the hold complete", async () => {
  for (const validate of [true, () => Promise.resolve(true)]) {
    const { subject, timers, log } = hold({ validate })
    subject.start()
    timers.advance(150)
    await settle()
    timers.advance(450)
    assert.deepEqual(log, ["started", "validate", "completed"])
  }
})

test("a no from an earlier press does not abort the press that followed it", async () => {
  let answer
  const { subject, button, timers } = hold({ validate: () => new Promise((resolve) => { answer = resolve }) })

  subject.start()
  timers.advance(150)
  const first = answer
  subject.end()
  subject.start()
  first(false)
  await settle()

  assert.equal(subject.holding, true, "the second press is still running")
  assert.equal(button.classes.has("process"), true)
})

test("a no that arrives after completion takes nothing back", async () => {
  let answer
  const { subject, button, timers, log } = hold({ validate: () => new Promise((resolve) => { answer = resolve }) })

  subject.start()
  timers.advance(600)
  answer(false)
  await settle()

  assert.deepEqual(log, ["started", "validate", "completed"])
  assert.equal(button.classes.has("success"), true)
})

test("nothing of the timeline fires after completion", () => {
  const { subject, timers, log } = hold({ validate: true, early: true }, { duration: "600", validateAt: "700", earlyActionAt: "900" })

  subject.start()
  timers.advance(10_000)

  assert.deepEqual(log, ["started", "completed"], "a validate or early action due after the duration never runs")
})

test("a no that arrives after an owned completion leaves the holding state to its owner", async () => {
  let answer
  const { subject, button, timers } = hold({ completed: true, validate: () => new Promise((resolve) => { answer = resolve }) })

  subject.start()
  timers.advance(600)
  answer(false)
  await settle()

  assert.equal(button.classes.has("process"), true)
})

test("completion a caller owns leaves the button in its holding state", () => {
  const { subject, button, timers } = hold({ completed: true })

  subject.start()
  timers.advance(600)

  assert.equal(button.classes.has("process"), true)
  assert.equal(button.classes.has("success"), false)
})

test("a completed hook that throws still shows success: the hold was held", () => {
  const { subject, button, timers, reports } = hold({ completed: () => { throw new Error("boom") } })

  subject.start()
  timers.advance(600)

  assert.equal(button.classes.has("success"), true)
  assert.match(reports[0][0], /completed threw/)
})

test("a started hook that throws does not stop the hold", () => {
  const { subject, timers, log, reports } = hold({ started: () => { throw new Error("boom") } })

  assert.equal(subject.start(), true)
  timers.advance(600)

  assert.deepEqual(log, ["started", "completed"])
  assert.match(reports[0][0], /started threw/)
})

test("a second press without a release starts over and completes once", () => {
  const { subject, timers, log } = hold()

  subject.start()
  timers.advance(400)
  subject.start()
  assert.equal(timers.pending(), 4, "one hold's three timers and the nudge; the first press's are cleared")
  timers.advance(599)
  assert.equal(log.filter((name) => name === "completed").length, 0, "the first press's timer is gone")
  timers.advance(1)
  assert.equal(log.filter((name) => name === "completed").length, 1)
})

test("a release after completion takes nothing back, and a finished button ignores a release", () => {
  const { subject, button, timers, log } = hold()

  subject.start()
  timers.advance(600)
  subject.end()

  assert.deepEqual(log, ["started", "completed"])
  assert.equal(button.classes.has("success"), true)

  const errored = hold()
  errored.button.classList.add("error")
  errored.subject.end()
  assert.equal(errored.timers.pending(), 0, "an errored button restarts no nudge")
})

test("a press on a finished button starts a fresh hold", () => {
  const { subject, button, timers } = hold()
  subject.start()
  timers.advance(600)

  subject.start()

  assert.equal(button.classes.has("success"), false)
  assert.equal(button.classes.has("process"), true)
})

test("stop clears the hold and the nudge", () => {
  const { subject, timers, log } = hold()
  subject.start()

  subject.stop()

  assert.equal(timers.pending(), 0)
  timers.advance(10_000)
  assert.deepEqual(log, ["started"])
})

test("the idle nudge: a firm one after three seconds, soft ones every ten", () => {
  const timers = fakeTimers()
  const button = fakeButton()
  const nudge = new NudgeCycle(button, timers)
  assert.deepEqual([NUDGE_FIRST_S, NUDGE_REPEAT_S], [3, 10])

  nudge.start()
  assert.equal(button.count.textContent, 3)
  timers.advance(2000)
  assert.equal(button.classes.has("nudge"), false)
  assert.equal(button.count.textContent, 1)
  timers.advance(1000)
  assert.equal(button.classes.has("nudge"), true)
  assert.equal(button.count.textContent, 10, "the ring refills for the ten-second repeat")

  button.classList.remove("nudge")
  timers.advance(10_000)
  assert.equal(button.classes.has("nudge-soft"), true)
  assert.equal(button.classes.has("nudge"), false)
})

test("starting the nudge again replaces the countdown that was running", () => {
  const timers = fakeTimers()
  const nudge = new NudgeCycle(fakeButton(), timers)
  nudge.start()
  nudge.start()
  assert.equal(timers.pending(), 1)
})

test("after a release the nudge is soft only, ten seconds out", () => {
  const { subject, button, timers } = hold()
  subject.start()
  subject.end()

  timers.advance(9000)
  assert.equal(button.classes.has("nudge-soft"), false)
  timers.advance(1000)
  assert.equal(button.classes.has("nudge-soft"), true)
  assert.equal(button.classes.has("nudge"), false)
})

test("a holding or confirmed button is not nudged", () => {
  for (const state of ["process", "success"]) {
    const timers = fakeTimers()
    const button = fakeButton()
    button.classList.add(state)
    new NudgeCycle(button, timers).start()
    timers.advance(3000)
    assert.equal(button.classes.has("nudge"), false)
  }
})

test("the nudge ring empties as the countdown runs", () => {
  const timers = fakeTimers()
  const button = fakeButton()
  new NudgeCycle(button, timers).start()

  assert.equal(button.fill.style.strokeDashoffset, (2 * Math.PI * 9).toFixed(2))
  timers.advance(1000)
  assert.equal(button.fill.style.strokeDashoffset, (2 * Math.PI * 9 * (2 / 3)).toFixed(2))
})

test("a press clears a showing nudge and restarts the countdown", () => {
  const { subject, button, timers } = hold()
  subject.nudge.start()
  timers.advance(3000)
  assert.equal(button.classes.has("nudge"), true)

  subject.start()

  assert.equal(button.classes.has("nudge"), false)
  assert.equal(button.count.textContent, 3)
})

test("install publishes the portal handle once and restores portals before Turbo caches", () => {
  const listeners = {}
  const doc = { addEventListener: (name, fn) => { (listeners[name] = listeners[name] || []).push(fn) } }
  const win = {}

  assert.equal(installHoldButton({ win, doc }), true)
  assert.equal(installHoldButton({ win, doc }), false)
  assert.deepEqual(Object.keys(win.studioFizzPortal), ["mount", "mountAll", "count"])
  assert.equal(win.studioFizzPortal.count(), 0)
  assert.equal(listeners["turbo:before-cache"].length, 1)
  assert.doesNotThrow(() => listeners["turbo:before-cache"][0]())
  assert.equal(installHoldButton({ win: {}, doc: null }), false)
})
