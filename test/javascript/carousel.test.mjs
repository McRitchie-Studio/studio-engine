// [unit] studio/carousel: where the carousel's row rests and where a press takes it.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/carousel.js", import.meta.url), "utf8")
const { hiddenEnds, stops, currentStop, perPage, targetStop, keyAction, positionText, ownsKey, KEY_OWNERS } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

// Six 100px slides, no gap, a 300px row: it rests at 0, 100, 200 and 300.
const SIX = [0, 100, 200, 300, 400, 500]

test("only an end that hides a slide is marked", () => {
  assert.deepEqual(hiddenEnds({ scrollLeft: 0, clientWidth: 300, scrollWidth: 300 }), { start: false, end: false })
  assert.deepEqual(hiddenEnds({ scrollLeft: 0, clientWidth: 300, scrollWidth: 600 }), { start: false, end: true })
  assert.deepEqual(hiddenEnds({ scrollLeft: 150, clientWidth: 300, scrollWidth: 600 }), { start: true, end: true })
  assert.deepEqual(hiddenEnds({ scrollLeft: 300, clientWidth: 300, scrollWidth: 600 }), { start: true, end: false })
})

test("a fraction of a pixel from an end is at it", () => {
  assert.deepEqual(hiddenEnds({ scrollLeft: 1.5, clientWidth: 300, scrollWidth: 600 }), { start: false, end: true })
  assert.deepEqual(hiddenEnds({ scrollLeft: 298.6, clientWidth: 300, scrollWidth: 600 }), { start: true, end: false })
})

test("the slides past the last stop share it", () => {
  assert.deepEqual(stops(SIX, 300), [0, 100, 200, 300])
})

test("a peek leaves the last stop short of a slide's start", () => {
  assert.deepEqual(stops([0, 280, 560, 840], 610), [0, 280, 560, 610])
})

test("a row that fits has one stop", () => {
  assert.deepEqual(stops([0, 100, 200], 0), [0])
  assert.deepEqual(stops([], 0), [0])
})

test("the row rests at the nearest stop, and at the last one from its end", () => {
  const positions = stops(SIX, 300)
  assert.equal(currentStop(0, positions), 0)
  assert.equal(currentStop(40, positions), 0)
  assert.equal(currentStop(60, positions), 1)
  assert.equal(currentStop(299, positions), 3)
  assert.equal(currentStop(0, []), 0)
})

test("a page is the whole slides in view", () => {
  assert.equal(perPage(300, 100, 0), 3)
  assert.equal(perPage(1000, 300, 16), 3, "3 slides and a peek")
  assert.equal(perPage(390, 320, 16), 1, "a phone: one slide and a peek")
  assert.equal(perPage(316, 100, 8), 3, "three slides and their gaps, to the pixel")
  assert.equal(perPage(300, 0, 0), 1, "an unmeasured slide still moves the row")
})

test("an arrow moves a page, held to the first and last stop", () => {
  assert.equal(targetStop("next", 0, 3, 4), 3)
  assert.equal(targetStop("next", 3, 3, 4), 3)
  assert.equal(targetStop("prev", 3, 3, 4), 0)
  assert.equal(targetStop("prev", 1, 1, 4), 0)
  assert.equal(targetStop("prev", 0, 1, 4), 0)
  assert.equal(targetStop("first", 2, 1, 4), 0)
  assert.equal(targetStop("last", 0, 1, 4), 3)
  assert.equal(targetStop("other", 2, 1, 4), 2)
})

test("the arrow keys, Home and End move the row; other keys do not", () => {
  assert.equal(keyAction("ArrowLeft"), "prev")
  assert.equal(keyAction("ArrowRight"), "next")
  assert.equal(keyAction("Home"), "first")
  assert.equal(keyAction("End"), "last")
  assert.equal(keyAction("ArrowDown"), null)
  assert.equal(keyAction("Enter"), null)
})

test("the status line says which slides are in view", () => {
  assert.equal(positionText(0, 3, 9), "Slides 1 to 3 of 9")
  assert.equal(positionText(7, 3, 9), "Slides 8 to 9 of 9")
  assert.equal(positionText(2, 1, 6), "Slide 3 of 6")
})

// A stand-in element: `closest` answers from the ancestors it was built with, each
// a set of selectors it matches, nearest first.
function node(ancestors) {
  return {
    closest(selector) {
      const wanted = selector.split(",").map((part) => part.trim())
      return ancestors.find((el) => wanted.some((one) => el.matches.includes(one))) || null
    }
  }
}

test("a key in a field or an arrow-key widget is that element's, not the row's", () => {
  const region = { matches: [".carousel"] }
  assert.equal(ownsKey(node([{ matches: [] }, region]), region), true, "a link in a slide")
  for (const owner of ["input", "textarea", "select", "[role='slider']", "[role='listbox']",
                       "[role='combobox']", "[role='tablist']", "[role='radiogroup']", "[role='grid']"]) {
    assert.ok(KEY_OWNERS.includes(owner), `${owner} is a key owner`)
    assert.equal(ownsKey(node([{ matches: [owner] }, region]), region), false, owner)
  }
})

test("a key in a carousel nested in a slide is the inner carousel's", () => {
  const outer = { matches: [".carousel"] }
  const inner = { matches: [".carousel"] }
  assert.equal(ownsKey(node([{ matches: [] }, inner, outer]), outer), false)
  assert.equal(ownsKey(node([{ matches: [] }, inner, outer]), inner), true)
  assert.equal(ownsKey({}, outer), false, "a target with no closest")
})
