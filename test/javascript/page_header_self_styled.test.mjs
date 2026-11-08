// [unit] studio/page_header_self_styled: the plain-CSS app's page-header script. Its five
// measurements are studio/page_header's, copied because it may load with no import map;
// this file holds each copy to its original on the same inputs. How it behaves in a
// browser is e2e/page_header_self_styled.spec.js.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const load = async (name) => {
  const source = readFileSync(new URL(`../../app/javascript/studio/${name}.js`, import.meta.url), "utf8")
  return [source, await import(`data:text/javascript,${encodeURIComponent(source)}`)]
}
const [source, copy] = await load("page_header_self_styled")
const [, original] = await load("page_header")

test("it imports nothing, so a page with no import map can load it", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
  assert.doesNotMatch(source, /\bimport\(/)
})

test("isStuck and sentinelMarksThePlace agree with studio/page_header", () => {
  for (const [row, rest] of [[120, 120], [120.4, 120], [64, 63], [64, -400], [0, 0.6]]) {
    assert.equal(copy.isStuck(row, rest), original.isStuck(row, rest), `${row}, ${rest}`)
  }
  for (const display of ["block", "flow-root", "flex", "inline-flex", "grid", "inline-grid", "contents"]) {
    assert.equal(copy.sentinelMarksThePlace(display), original.sentinelMarksThePlace(display), display)
  }
})

test("hiddenEnds and revealBy agree with studio/page_header", () => {
  for (const scrollLeft of [0, 1, 2, 100, 399, 400]) {
    const box = { scrollLeft, clientWidth: 300, scrollWidth: 700 }
    assert.deepEqual(copy.hiddenEnds(box), original.hiddenEnds(box))
  }
  const box = { left: 0, right: 300 }
  for (const tab of [{ left: 10, right: 80 }, { left: -40, right: 20 }, { left: 280, right: 360 }]) {
    assert.equal(copy.revealBy(box, tab), original.revealBy(box, tab))
  }
})

test("menuPlacement agrees with studio/page_header", () => {
  const viewport = { width: 390, height: 844 }
  const list = { width: 160, height: 90 }
  for (const button of [
    { top: 100, bottom: 130, right: 380 },
    { top: 790, bottom: 820, right: 200 },
    { top: 100, bottom: 130, right: 60 }
  ]) {
    assert.deepEqual(copy.menuPlacement(button, list, viewport), original.menuPlacement(button, list, viewport))
  }
})

test("the masthead's bottom counts only for a sticky or fixed header", () => {
  assert.equal(copy.mastheadBottom("sticky", 61), 61)
  assert.equal(copy.mastheadBottom("fixed", 64.5), 64.5)
  assert.equal(copy.mastheadBottom("static", 61), 0)
  assert.equal(copy.mastheadBottom("relative", 61), 0)
  assert.equal(copy.mastheadBottom("sticky", -10), 0, "a header scrolled off reads 0, never negative")
})
