// [unit] studio/carousel's cascade math: which slide sits at which step of the 3D
// stack, the slot it is written as, the slides that jump round a looping set's seam,
// and where a drag takes the stack. The partial writes the first paint's slots with
// the same rule (test/views/carousel_render_test.rb pins that side).
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/carousel.js", import.meta.url), "utf8")
const {
  CASCADE_REACH, DRAG_THRESHOLD, cascadeJumps, cascadeReach, cascadeSlot, cascadeStep, cascadeSteps,
  cascadeTarget, dragSteps, targetStop, autoplayStop
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("a set that does not loop steps from the open slide in row order", () => {
  assert.deepEqual(cascadeSteps(7, 3), [-3, -2, -1, 0, 1, 2, 3])
  assert.deepEqual(cascadeSteps(7, 0), [0, 1, 2, 3, 4, 5, 6])
  assert.deepEqual(cascadeSteps(7, 6), [-6, -5, -4, -3, -2, -1, 0])
})

test("a looping set steps the short way round, so the first slide has the last two on its left", () => {
  assert.deepEqual(cascadeSteps(7, 0, true), [0, 1, 2, 3, -3, -2, -1])
  assert.deepEqual(cascadeSteps(7, 6, true), [1, 2, 3, -3, -2, -1, 0])
  assert.deepEqual(cascadeSteps(5, 0, true), [0, 1, 2, -2, -1])
})

test("an even looping set breaks the far tie to the later side", () => {
  assert.deepEqual(cascadeSteps(4, 0, true), [0, 1, 2, -1])
  assert.deepEqual(cascadeSteps(6, 2, true), [-2, -1, 0, 1, 2, 3])
  assert.equal(cascadeStep(3, 0, 6, true), 3)
})

test("a set of one or none has nowhere to wrap", () => {
  assert.deepEqual(cascadeSteps(1, 0, true), [0])
  assert.deepEqual(cascadeSteps(0, 0, true), [])
})

test("five in view reach two each side; past that a slide is before or after", () => {
  assert.equal(CASCADE_REACH, 2)
  assert.deepEqual(cascadeSteps(7, 3).map((step) => cascadeSlot(step)), ["before", "-2", "-1", "0", "1", "2", "after"])
  assert.deepEqual(cascadeSteps(7, 0, true).map((step) => cascadeSlot(step)), ["0", "1", "2", "after", "before", "-2", "-1"])
})

test("three in view reach one each side", () => {
  assert.equal(cascadeReach(3), 1)
  assert.equal(cascadeReach("3"), 1)
  assert.equal(cascadeReach(5), 2)
  assert.equal(cascadeReach(undefined), 2)
  assert.deepEqual(cascadeSteps(5, 2).map((step) => cascadeSlot(step, cascadeReach(3))), ["before", "-1", "0", "1", "after"])
})

test("a plain move shifts every slide by one and none jumps", () => {
  const before = cascadeSteps(7, 3)
  const after = cascadeSteps(7, 4)
  assert.deepEqual(cascadeJumps(before, after, 4), [false, false, false, false, false, false, false])
})

test("Home on a set that does not loop shifts every slide alike: none jumps", () => {
  assert.deepEqual(cascadeJumps(cascadeSteps(7, 6), cascadeSteps(7, 0), 0), Array(7).fill(false))
})

test("round a looping set's seam, only the slide that crosses the stack jumps", () => {
  // Five slides, all in view: Next takes the far left one (step -2) to the far right.
  const before = cascadeSteps(5, 0, true)
  const after = cascadeSteps(5, 1, true)
  assert.deepEqual(before, [0, 1, 2, -2, -1])
  assert.deepEqual(after, [-1, 0, 1, 2, -2])
  assert.deepEqual(cascadeJumps(before, after, 1), [false, false, false, true, false])
})

test("Previous from the first slide of a looping set wraps to the last, and the far right slide jumps", () => {
  const before = cascadeSteps(7, 0, true)
  const last = targetStop("prev", 0, 1, 7, true)
  assert.equal(last, 6)
  const after = cascadeSteps(7, last, true)
  assert.deepEqual(after, [1, 2, 3, -3, -2, -1, 0])
  assert.deepEqual(cascadeJumps(before, after, last), [false, false, false, true, false, false, false])
})

test("a drag under the threshold moves nothing; past it, one step or more against the pointer", () => {
  assert.equal(DRAG_THRESHOLD, 40)
  assert.equal(dragSteps(39, 100), 0)
  assert.equal(dragSteps(-39, 100), 0)
  assert.equal(dragSteps(-40, 100), 1, "a drag left brings the next slide in")
  assert.equal(dragSteps(60, 100), -1, "a drag right brings the previous slide in")
  assert.equal(dragSteps(-260, 100), 3)
  assert.equal(dragSteps(-80, 0), 80, "a row with no width still moves")
  assert.equal(dragSteps(Number.NaN, 100), 0)
})

test("a drag or click target is held to the ends, or wraps round a looping set", () => {
  assert.equal(cascadeTarget(5, 3, 7), 6)
  assert.equal(cascadeTarget(1, -4, 7), 0)
  assert.equal(cascadeTarget(5, 3, 7, true), 1)
  assert.equal(cascadeTarget(1, -4, 7, true), 4)
  assert.equal(cascadeTarget(0, 1, 0), 0)
})

test("autoplay steps one slide on, round a looping set, and stops at the end of one that does not loop", () => {
  assert.equal(autoplayStop(3, 7, false), 4)
  assert.equal(autoplayStop(6, 7, false), null)
  assert.equal(autoplayStop(6, 7, true), 0)
})

const { CHANGE_EVENT, changeDetail, clickedSlide } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the change event is named once and documented", () => {
  assert.equal(CHANGE_EVENT, "studio:carousel:change")
})

test("a change detail names the open slide, the one before, its element and the count", () => {
  const slides = ["a", "b", "c"]
  assert.deepEqual(changeDetail(0, 2, slides), { index: 2, previous: 0, slide: "c", total: 3 })
  assert.deepEqual(changeDetail(undefined, 1, slides), { index: 1, previous: null, slide: "b", total: 3 })
})

test("no change, no detail: the same slide, an index off the set, or no slides", () => {
  assert.equal(changeDetail(1, 1, ["a", "b"]), null)
  assert.equal(changeDetail(0, 5, ["a", "b"]), null)
  assert.equal(changeDetail(0, -1, ["a", "b"]), null)
  assert.equal(changeDetail(0, Number.NaN, ["a", "b"]), null)
  assert.equal(changeDetail(null, 0, []), null)
})

test("a click with no press (Enter on a link) is the slide it lands in, whatever a press left", () => {
  assert.equal(clickedSlide(4, 0, 3), 3, "a stale press on card 5 does not steal Enter on the open card")
  assert.equal(clickedSlide(null, 0, 2), 2)
})

test("a mouse click reads its press first, then the slide it lands in", () => {
  assert.equal(clickedSlide(4, 1, 3), 4)
  assert.equal(clickedSlide(null, 1, 3), 3)
  assert.equal(clickedSlide(undefined, 2, -1), -1)
})

test("Next then Previous round a five-card loop's seam takes the same card across twice", () => {
  // The controller replays that card's fade each time (e2e/carousel_cascade.spec.js).
  const first = cascadeJumps(cascadeSteps(5, 0, true), cascadeSteps(5, 1, true), 1)
  const back = cascadeJumps(cascadeSteps(5, 1, true), cascadeSteps(5, 0, true), 0)
  assert.deepEqual(first, [false, false, false, true, false])
  assert.deepEqual(back, [false, false, false, true, false])
})
