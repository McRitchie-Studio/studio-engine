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
                       "[role='combobox']", "[role='tablist']", "[role='radiogroup']", "[role='grid']",
                       "video", "audio"]) {
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

// THE LOOP'S SEAM (loop: true): the clones either side and the virtual index.
const loop = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("a virtual index wraps to the real slide it shows", () => {
  assert.equal(loop.wrapIndex(-1, 7), 6, "the clone before the first is the last")
  assert.equal(loop.wrapIndex(7, 7), 0, "the clone after the last is the first")
  assert.equal(loop.wrapIndex(-8, 7), 6)
  assert.equal(loop.wrapIndex(3, 7), 3)
  assert.equal(loop.wrapIndex(3, 0), 0, "an empty row")
})

test("each side gets a wide row's slides plus one clone, and a row of one none", () => {
  assert.equal(loop.cloneCount(3, 7), 4)
  assert.equal(loop.cloneCount(2.5, 7), 4, "a fractional per_view rounds up")
  assert.equal(loop.cloneCount(6, 7), 7)
  assert.equal(loop.cloneCount(9, 7), 7, "held to the partial's six")
  assert.equal(loop.cloneCount(NaN, 7), 4, "an unread per_view takes the default three")
  assert.equal(loop.cloneCount(3, 1), 0)
  assert.equal(loop.cloneCount(3, 0), 0)
})

test("the clones copy the last slides before the first and the first after the last", () => {
  assert.deepEqual(loop.cloneLayout(7, 4), { before: [3, 4, 5, 6], after: [0, 1, 2, 3] })
  assert.deepEqual(loop.cloneLayout(2, 4), { before: [0, 1, 0, 1], after: [0, 1, 0, 1] }, "a short row repeats round")
  assert.deepEqual(loop.cloneLayout(1, 4), { before: [], after: [] })
  assert.deepEqual(loop.cloneLayout(7, 0), { before: [], after: [] })
})

test("an arrow at the last slide goes on to the clone after it, and Previous at the first to the clone before", () => {
  assert.equal(loop.loopStop("next", 6, 1, 7, 4), 7, "the first slide's clone, after the last")
  assert.equal(loop.loopStop("prev", 0, 1, 7, 4), -1, "the last slide's clone, before the first")
  assert.equal(loop.loopStop("next", 5, 3, 7, 4), 8, "a page runs round the seam with no end")
  assert.equal(loop.loopStop("next", 2, 1, 7, 4), 3, "inside the row it moves as a plain row does")
  assert.equal(loop.loopStop("first", 5, 1, 7, 4), 0)
  assert.equal(loop.loopStop("last", 1, 1, 7, 4), 6)
  assert.equal(loop.loopStop("jump", 2, 1, 7, 4), 2, "an unknown action stays")
  assert.equal(loop.loopStop("next", 10, 3, 7, 4), 10, "a press mid-glide is held to the last clone")
  assert.equal(loop.loopStop("prev", -3, 3, 7, 4), -4, "and to the first")
})

test("a row resting on a clone jumps to the real slide it copies, and a real one stays", () => {
  assert.equal(loop.seamJump(7, 7), 0)
  assert.equal(loop.seamJump(-1, 7), 6)
  assert.equal(loop.seamJump(9, 7), 2)
  assert.equal(loop.seamJump(0, 7), null)
  assert.equal(loop.seamJump(6, 7), null)
  assert.equal(loop.seamJump(-1, 0), null)
})

test("a dot takes the short way round the seam", () => {
  assert.equal(loop.nearestVirtual(0, 6, 7, 4), 7, "from the last, the first is one on")
  assert.equal(loop.nearestVirtual(6, 0, 7, 4), -1, "from the first, the last is one back")
  assert.equal(loop.nearestVirtual(3, 1, 7, 4), 3, "inside the row it goes straight")
  assert.equal(loop.nearestVirtual(0, 6, 7, 0), 0, "with no clones there is one way")
})

test("a clone drops ids, names, test hooks and Stimulus wiring, and keeps its look", () => {
  for (const name of ["id", "name", "data-test", "data-testid", "data-test-id", "data-qa", "data-cy",
    "data-studio-controller", "data-controller", "data-studio-action", "data-action",
    "data-carousel-target", "data-menu-target", "data-carousel-start-slide", "data-current"]) {
    assert.ok(loop.CLONE_STRIP.test(name), name)
  }
  for (const name of ["class", "style", "href", "src", "alt", "data-lab-card", "aria-label", "data-testing-note", "identity"]) {
    assert.ok(!loop.CLONE_STRIP.test(name), name)
  }
})

test("a looping row's status line runs round the seam", () => {
  assert.equal(loop.loopPositionText(0, 3, 6), "Slides 1 to 3 of 6")
  assert.equal(loop.loopPositionText(3, 3, 6), "Slides 4 to 6 of 6")
  assert.equal(loop.loopPositionText(4, 3, 6), "Slides 5 to 6 and 1 of 6")
  assert.equal(loop.loopPositionText(5, 3, 6), "Slides 6 and 1 to 2 of 6")
  assert.equal(loop.loopPositionText(6 - 1, 1, 6), "Slide 6 of 6", "a spotlight shows one")
  assert.equal(loop.loopPositionText(1, 3, 2), "Slides 2 and 1 of 2", "a page wider than the row shows each once")
})
