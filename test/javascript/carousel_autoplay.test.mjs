// [unit] studio/carousel's loop and autoplay: where a looping row's arrows go, the
// stop autoplay moves to, and what holds autoplay still.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/carousel.js", import.meta.url), "utf8")
const {
  targetStop, autoplaySeconds, autoplayStop, autoplayRunning, withReason, initialReasons, idleDelay, toggleLabel,
  PAUSE_REASONS
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("a looping row's Next at the last stop wraps to the first", () => {
  assert.equal(targetStop("next", 3, 1, 4, true), 0)
  assert.equal(targetStop("next", 3, 3, 4, true), 0, "a page of three wraps too")
})

test("a looping row's Previous at the first stop wraps to the last", () => {
  assert.equal(targetStop("prev", 0, 1, 4, true), 3)
  assert.equal(targetStop("prev", 0, 3, 4, true), 3)
})

test("a looping page that overshoots an end lands on the end first", () => {
  assert.equal(targetStop("next", 2, 3, 4, true), 3, "no slide is skipped on the way round")
  assert.equal(targetStop("prev", 1, 3, 4, true), 0)
  assert.equal(targetStop("next", 1, 1, 4, true), 2, "inside the row a loop moves as a plain row does")
})

test("a row that does not loop is still held to its ends", () => {
  assert.equal(targetStop("next", 3, 1, 4), 3)
  assert.equal(targetStop("prev", 0, 1, 4), 0)
  assert.equal(targetStop("next", 3, 1, 4, false), 3)
})

test("a looping row with one stop goes nowhere, and Home and End do not wrap", () => {
  assert.equal(targetStop("next", 0, 1, 1, true), 0)
  assert.equal(targetStop("prev", 0, 1, 1, true), 0)
  assert.equal(targetStop("first", 2, 1, 4, true), 0)
  assert.equal(targetStop("last", 3, 1, 4, true), 3)
})

test("autoplay's interval is a number of seconds above 0, or off", () => {
  assert.equal(autoplaySeconds("5"), 5)
  assert.equal(autoplaySeconds("2.5"), 2.5)
  for (const off of [undefined, null, "", "0", "-3", "soon", "Infinity"]) {
    assert.equal(autoplaySeconds(off), null, `${off} is off`)
  }
})

test("autoplay moves one stop, and wraps only on a looping row", () => {
  assert.equal(autoplayStop(0, 4), 1)
  assert.equal(autoplayStop(2, 4), 3)
  assert.equal(autoplayStop(3, 4, true), 0, "the last stop of a loop leads to the first")
  assert.equal(autoplayStop(3, 4, false), null, "a row that does not loop stops at its end")
  assert.equal(autoplayStop(0, 1, true), null, "one stop has nowhere to go")
  assert.equal(autoplayStop(0, 0, true), null)
})

test("autoplay runs only when it is on and no reason holds it", () => {
  const none = new Set()
  assert.equal(autoplayRunning(5, none), true)
  assert.equal(autoplayRunning(null, none), false)
  for (const reason of PAUSE_REASONS) {
    assert.equal(autoplayRunning(5, withReason(none, reason, true)), false, `${reason} holds it`)
  }
})

test("a reason lifts on its own and leaves the others", () => {
  let reasons = withReason(new Set(), "hover", true)
  reasons = withReason(reasons, "focus", true)
  reasons = withReason(reasons, "hover", false)
  assert.deepEqual([...reasons], ["focus"])
  reasons = withReason(reasons, "focus", false)
  assert.equal(autoplayRunning(5, reasons), true)
})

test("setting a reason makes a new set and leaves the old one alone", () => {
  const before = new Set(["hover"])
  const after = withReason(before, "hidden", true)
  assert.deepEqual([...before], ["hover"])
  assert.deepEqual([...after].sort(), ["hidden", "hover"])
})

test("reduced motion starts the row stopped, and a hidden tab starts it hidden", () => {
  assert.deepEqual([...initialReasons({ reducedMotion: true })], ["stopped"])
  assert.deepEqual([...initialReasons({ hidden: true })], ["hidden"])
  assert.equal(initialReasons().size, 0)
  assert.equal(autoplayRunning(5, initialReasons({ reducedMotion: true })), false)
})

test("after a press autoplay waits one interval, never under five seconds", () => {
  assert.equal(idleDelay(2), 5000)
  assert.equal(idleDelay(8), 8000)
  assert.equal(idleDelay(null), 5000)
})

test("the pause button is named for what it does next", () => {
  assert.equal(toggleLabel(false), "Pause slideshow")
  assert.equal(toggleLabel(true), "Play slideshow")
})
