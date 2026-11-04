// [unit] studio/transition_snapshot: which classes count as a mid-slide state, that
// the strip takes only those, and when the finish runs. Loaded from source as a
// data: module, like link_sidebar.test.mjs; the module imports nothing, which is what
// lets the head load it when studio/application does not.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/transition_snapshot.js", import.meta.url), "utf8")
const { midSlideClasses, stripMidSlideClasses, finishTransitions, installTransitionSnapshot } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

// components/_sidebar_panel's x-transition attributes.
const PANEL = {
  "x-transition:enter": "transition ease-out duration-300",
  "x-transition:enter-start": "translate-x-full",
  "x-transition:enter-end": "translate-x-0",
  "x-transition:leave": "transition ease-in duration-200",
  "x-transition:leave-start": "translate-x-0",
  "x-transition:leave-end": "translate-x-full"
}

const element = (classes, attributes = PANEL) => {
  const set = new Set(classes.split(" ").filter(Boolean))
  return {
    classList: {
      contains: (name) => set.has(name),
      remove: (...names) => names.forEach((name) => set.delete(name))
    },
    getAttribute: (name) => attributes[name] ?? null,
    get className() { return [...set].join(" ") }
  }
}

const rootOf = (...elements) => ({ querySelectorAll: () => elements })

test("the classes a clone keeps at the end of the leave count, and only with a whole phase", () => {
  const el = element("fixed right-0 transition ease-in duration-200 translate-x-full")
  assert.deepEqual(midSlideClasses(el).sort(), ["duration-200", "ease-in", "transition", "translate-x-0", "translate-x-full"].sort())
})

test("the start of the leave and either phase of the enter count too", () => {
  for (const held of ["transition ease-in duration-200 translate-x-0",
                      "transition ease-out duration-300 translate-x-full",
                      "transition ease-out duration-300 translate-x-0"]) {
    assert.notEqual(midSlideClasses(element(held)).length, 0, held)
  }
})

test("a panel at rest holds no phase, even one that keeps a named class", () => {
  for (const atRest of ["fixed right-0 bg-surface",
                        "fixed transition",
                        "fixed translate-x-full",
                        "fixed transition ease-in translate-x-full",
                        "fixed transition ease-in duration-200"]) {
    assert.deepEqual(midSlideClasses(element(atRest)), [], atRest)
  }
})

test("an x-transition with empty or missing attributes names no phase", () => {
  assert.deepEqual(midSlideClasses(element("fixed", {})), [])
  const leaveOnly = { "x-transition:leave": "transition", "x-transition:leave-end": "" }
  assert.deepEqual(midSlideClasses(element("fixed transition", leaveOnly)), [])
})

test("the strip removes only the panel's named classes", () => {
  const stale = element("hidden md:flex fixed right-0 w-80 lab-rest-class transition ease-in duration-200 translate-x-full")
  stripMidSlideClasses(rootOf(stale))
  assert.equal(stale.className, "hidden md:flex fixed right-0 w-80 lab-rest-class")
})

test("the strip leaves a panel at rest byte for byte", () => {
  const atRest = element("fixed right-0 transition")
  stripMidSlideClasses(rootOf(atRest))
  assert.equal(atRest.className, "fixed right-0 transition")
})

test("the strip and the finish take a missing root", () => {
  assert.doesNotThrow(() => stripMidSlideClasses(null))
  assert.doesNotThrow(() => stripMidSlideClasses({}))
  assert.doesNotThrow(() => finishTransitions(undefined))
})

test("the finish calls Alpine's finish on a running transition and skips the rest", () => {
  let finished = 0
  const running = { _x_transitioning: { finish: () => { finished += 1 } } }
  finishTransitions(rootOf(running, {}))
  assert.equal(finished, 1)
})

// A document and window with hand-driven listeners and timers.
const stage = () => {
  const listeners = {}
  const timers = []
  const doc = {
    body: null,
    addEventListener: (name, fn) => { (listeners[name] ||= []).push(fn) }
  }
  const win = { document: doc, setTimeout: (fn, ms) => { timers.push({ fn, ms }) } }
  return { doc, win, timers, fire: (name, event = {}) => (listeners[name] || []).forEach((fn) => fn(event)), listeners }
}

test("before-cache finishes on a zero timeout, not inside the event, and on the body it left", () => {
  const { doc, win, timers, fire } = stage()
  installTransitionSnapshot({ win, doc })

  // A transition the event's own handlers start only after this listener returns.
  const panel = element("transition ease-in duration-200 translate-x-0")
  doc.body = rootOf(panel)
  const bodyAtTheEvent = doc.body
  let finished = 0
  fire("turbo:before-cache")
  panel._x_transitioning = { finish: () => { finished += 1 } }

  assert.equal(finished, 0, "nothing runs inside the event")
  assert.deepEqual(timers.map((timer) => timer.ms), [0])

  doc.body = rootOf() // Turbo swapped the body before the timer fired.
  timers[0].fn()
  assert.equal(finished, 1, "the finish reached the body the event saw")
  assert.equal(panel.className, "", "and the strip ran on it, for a disconnected panel Alpine skips")
  assert.ok(bodyAtTheEvent)
})

test("before-render finishes the live body while it is still connected", () => {
  const { doc, win, fire } = stage()
  installTransitionSnapshot({ win, doc })
  let finished = 0
  doc.body = rootOf({ _x_transitioning: { finish: () => { finished += 1 } } })

  fire("turbo:before-render", { detail: { newBody: rootOf() } })
  assert.equal(finished, 1)
})

test("before-render strips the incoming body, and takes an event with none", () => {
  const { doc, win, fire } = stage()
  installTransitionSnapshot({ win, doc })
  doc.body = rootOf()
  const panel = element("fixed transition ease-in duration-200 translate-x-full")

  fire("turbo:before-render", { detail: { newBody: rootOf(panel) } })
  assert.equal(panel.className, "fixed")
  assert.doesNotThrow(() => fire("turbo:before-render", {}))
})

test("a second install adds no second listener", () => {
  const { doc, win, listeners } = stage()
  assert.equal(installTransitionSnapshot({ win, doc }), true)
  assert.equal(installTransitionSnapshot({ win, doc }), false)
  assert.equal(listeners["turbo:before-cache"].length, 1)
})

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("a handle with no finish() does not throw, so the strip still runs", () => {
  const el = element("transition ease-in duration-200 translate-x-full")
  el._x_transitioning = {}
  assert.doesNotThrow(() => finishTransitions(rootOf(el)))
  stripMidSlideClasses(rootOf(el))
  assert.equal(el.className, "")
})

// What the first half leans on in the vendored build. An Alpine bump that renames
// these fails here, not in a browser.
test("the vendored Alpine keeps the transition handle this module calls", () => {
  const alpine = readFileSync(new URL("../../app/assets/javascripts/studio/alpine.js", import.meta.url), "utf8")
  assert.match(alpine, /t\._x_transitioning=\{beforeCancels:\[\]/)
  assert.match(alpine, /finish:o\}/)
  assert.match(alpine, /delete t\._x_transitioning/)
})
