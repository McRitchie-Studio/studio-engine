// [unit] studio/page_header: what the page header measures.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/page_header.js", import.meta.url), "utf8")
const { isStuck, hiddenEnds, revealBy } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("a row at its place in the flow is not stuck, a row past it is", () => {
  assert.equal(isStuck(120, 120), false)
  assert.equal(isStuck(120.4, 120), false, "a fraction is rounding")
  assert.equal(isStuck(64, 63), true)
  assert.equal(isStuck(64, -400), true)
})

test("a row directly under the navbar at rest is not stuck", () => {
  assert.equal(isStuck(64, 64), false)
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
