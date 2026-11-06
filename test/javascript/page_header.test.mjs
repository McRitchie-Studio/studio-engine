// [unit] studio/page_header: what the page header measures.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/page_header.js", import.meta.url), "utf8")
const { isStuck, hiddenEnds, revealBy, sentinelMarksThePlace, menuPlacement } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("a row at its place in the flow is not stuck, a row past it is", () => {
  assert.equal(isStuck(120, 120), false)
  assert.equal(isStuck(120.4, 120), false, "a fraction is rounding")
  assert.equal(isStuck(64, 63), true)
  assert.equal(isStuck(64, -400), true)
})

test("a row directly under the navbar at rest is not stuck", () => {
  assert.equal(isStuck(64, 64), false)
})

test("the sentinel marks the row's place in a block parent, not in a flex or grid one", () => {
  for (const display of ["block", "flow-root", "inline-block"]) assert.equal(sentinelMarksThePlace(display), true, display)
  for (const display of ["flex", "inline-flex", "grid", "inline-grid"]) assert.equal(sentinelMarksThePlace(display), false, display)
})

test("only an end that hides a tab is marked", () => {
  assert.deepEqual(hiddenEnds({ scrollLeft: 0, clientWidth: 300, scrollWidth: 300 }), { start: false, end: false })
  assert.deepEqual(hiddenEnds({ scrollLeft: 0, clientWidth: 300, scrollWidth: 700 }), { start: false, end: true })
  assert.deepEqual(hiddenEnds({ scrollLeft: 100, clientWidth: 300, scrollWidth: 700 }), { start: true, end: true })
  assert.deepEqual(hiddenEnds({ scrollLeft: 400, clientWidth: 300, scrollWidth: 700 }), { start: true, end: false })
})

test("a tab in view does not move the tabs; one past an end clears the fade", () => {
  const box = { left: 100, right: 400 }
  assert.equal(revealBy(box, { left: 120, right: 200 }), 0)
  assert.equal(revealBy(box, { left: 500, right: 580 }), 212)
  assert.equal(revealBy(box, { left: 40, right: 90 }), -92)
})

test("the quick-links list hangs under the button, its right edge on the button's", () => {
  const button = { top: 100, bottom: 132, left: 900, right: 960 }
  assert.deepEqual(menuPlacement(button, { width: 160, height: 120 }, { width: 1280, height: 800 }), { top: 136, left: 800 })
})

test("the quick-links list stays on the screen at the left edge", () => {
  const button = { top: 100, bottom: 132, left: 4, right: 64 }
  assert.deepEqual(menuPlacement(button, { width: 160, height: 120 }, { width: 390, height: 844 }), { top: 136, left: 8 })
})

test("the quick-links list opens above the button when only above has room", () => {
  const button = { top: 700, bottom: 732, left: 900, right: 960 }
  assert.deepEqual(menuPlacement(button, { width: 160, height: 120 }, { width: 1280, height: 800 }), { top: 576, left: 800 })
})
