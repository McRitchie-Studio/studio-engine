// [unit] studio/style_section_nav: the section the style guide's tabs highlight.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/style_section_nav.js", import.meta.url), "utf8")
const { activeIndex } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

const LINE = 100

test("the first section is current before any section reaches the line", () => {
  assert.equal(activeIndex([300, 900, 1500], LINE), 0)
})

test("a section becomes current when its top reaches the line, not before", () => {
  assert.equal(activeIndex([-500, 101, 900], LINE), 0)
  assert.equal(activeIndex([-500, 100, 900], LINE), 1)
  assert.equal(activeIndex([-900, -300, 99], LINE), 2)
})

test("the last section is current at the page end, though it never reaches the line", () => {
  assert.equal(activeIndex([-900, -300, 400], LINE), 1, "mid-page, it is not yet current")
  assert.equal(activeIndex([-900, -300, 400], LINE, true), 2)
})

test("a link whose section is missing never wins, and no sections answers -1", () => {
  assert.equal(activeIndex([-300, Infinity, 500], LINE), 0)
  assert.equal(activeIndex([], LINE), -1)
})
