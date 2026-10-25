// [unit] studio/modal_countdown: the wait a counting card reads, and the card's
// scope (it counts its own copy down once a second and closes its store at
// zero). Loaded from source as a data: module, like birthday.test.mjs; the
// module imports nothing.
//
// CONTROLS, each run against this file:
//   - drop the `this.remaining > 0` early return in tick(): "it closes the store
//     at zero, once, and stops ticking" fails (it closes on the first tick).
//   - make autoClose default false: "it closes the store at zero" fails.
//   - drop the guard in init(): "no seconds is no countdown" fails.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/modal_countdown.js", import.meta.url), "utf8")
const { MINUTES_FROM, startSeconds, waitLabel, studioModalCountdown } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

// A clock the test advances by hand, and a store that records its closes.
function harness() {
  const intervals = new Map()
  let nextId = 1
  const closes = []
  const stores = { modals: { close: () => closes.push("modals") }, profileModals: { close: () => closes.push("profileModals") } }
  const env = {
    win: { Alpine: { store: (name) => stores[name] } },
    setInterval: (fn, ms) => { const id = nextId++; intervals.set(id, { fn, ms }); return id },
    clearInterval: (id) => { intervals.delete(id) }
  }
  const advance = (n) => {
    for (let i = 0; i < n; i++) for (const { fn } of [...intervals.values()]) fn()
  }
  return { env, intervals, closes, advance }
}

test("the module imports nothing, so the head can load it by its own tag", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("a Retry-After reads as whole seconds to wait, and anything else as none", () => {
  assert.equal(startSeconds("12"), 12)
  assert.equal(startSeconds(12), 12)
  assert.equal(startSeconds(11.2), 12, "a fractional wait rounds up, never short")
  for (const none of [0, -3, "", "soon", null, undefined, NaN, Infinity]) {
    assert.equal(startSeconds(none), 0, `${String(none)} is no wait`)
  }
})

test("a short wait reads in seconds and a long one in minutes", () => {
  assert.equal(waitLabel(45), "45s")
  assert.equal(waitLabel(MINUTES_FROM), MINUTES_FROM + "s", "the boundary itself still reads in seconds")
  assert.equal(waitLabel(MINUTES_FROM + 1), "2 min")
  assert.equal(waitLabel(181), "4 min", "minutes round up")
  assert.equal(waitLabel(0), "0s")
  assert.equal(waitLabel(-4), "0s")
})

test("it counts down once a second and closes the store at zero, once, and stops ticking", () => {
  const h = harness()
  const card = studioModalCountdown({ seconds: 3, store: "modals" }, h.env)
  card.init()

  assert.equal(h.intervals.size, 1)
  assert.equal([...h.intervals.values()][0].ms, 1000)
  assert.equal(card.waitLabel, "3s")
  assert.equal(card.counting, true)

  h.advance(2)
  assert.equal(card.remaining, 1)
  assert.deepEqual(h.closes, [], "nothing closes before zero")

  h.advance(1)
  assert.equal(card.remaining, 0)
  assert.equal(card.counting, false)
  assert.deepEqual(h.closes, ["modals"])
  assert.equal(h.intervals.size, 0, "the interval is cleared at zero")

  card.tick()
  assert.deepEqual(h.closes, ["modals"], "a stray tick after zero closes nothing more")
})

test("it closes the store it was given, not the default", () => {
  const h = harness()
  const card = studioModalCountdown({ seconds: 1, store: "profileModals" }, h.env)
  card.init()
  h.advance(1)
  assert.deepEqual(h.closes, ["profileModals"])
})

test("autoClose: false counts to zero and leaves the card open", () => {
  const h = harness()
  const card = studioModalCountdown({ seconds: 2, autoClose: false }, h.env)
  card.init()
  h.advance(2)
  assert.equal(card.remaining, 0)
  assert.deepEqual(h.closes, [])
  assert.equal(h.intervals.size, 0)
})

test("no seconds is no countdown: nothing ticks and nothing closes", () => {
  const h = harness()
  const card = studioModalCountdown({ store: "modals" }, h.env)
  card.init()
  assert.equal(h.intervals.size, 0)
  assert.equal(card.counting, false)
  assert.deepEqual(h.closes, [])
})

test("an unmounted card leaves no interval behind, and a second init starts one only", () => {
  const h = harness()
  const card = studioModalCountdown({ seconds: 30 }, h.env)
  card.init()
  card.init()
  assert.equal(h.intervals.size, 1, "a re-init replaces the interval rather than stacking a second")
  card.destroy()
  assert.equal(h.intervals.size, 0)
  h.advance(40)
  assert.deepEqual(h.closes, [])
})

test("a store that is gone by zero is not an error", () => {
  const h = harness()
  h.env.win = { Alpine: { store: () => undefined } }
  const card = studioModalCountdown({ seconds: 1, store: "nowhere" }, h.env)
  card.init()
  assert.doesNotThrow(() => h.advance(1))
  assert.equal(card.remaining, 0)
})
