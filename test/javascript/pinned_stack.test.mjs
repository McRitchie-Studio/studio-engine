// [unit] studio/pinned_stack: how the publisher composes the stack. Loaded
// from source as a data: module, like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/pinned_stack.js", import.meta.url), "utf8")
const { composed, order } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

// A reading as measure() returns it, with an element that answers only the
// one attribute composed() reads.
const pin = (name, bottom, pinOrder) => ({
  name, bottom, h: 0,
  el: { getAttribute: (attr) => (attr === "data-pin-order" && pinOrder !== undefined ? String(pinOrder) : null) }
})

test("the stack bottom is the lowest edge of any layer", () => {
  const pins = [pin("apps", 40), pin("nav", 120), pin("banner", 60)]
  assert.equal(composed(pins), 120)
})

test("each layer's top is the lowest edge of the layers above it, in document order", () => {
  const pins = [pin("devnet", 30), pin("apps", 70), pin("nav", 150)]
  composed(pins)
  assert.deepEqual(pins.map((p) => p.top), [0, 30, 70])
})

test("a layer never counts its own edge as above itself", () => {
  const pins = [pin("nav", 100)]
  assert.equal(composed(pins), 100)
  assert.equal(pins[0].top, 0)
})

test("data-pin-order overrides document order when both layers carry it", () => {
  // The nav is first in the DOM but sits BELOW the apps strip on screen.
  const pins = [pin("nav", 150, 2), pin("apps", 70, 1)]
  composed(pins)
  assert.equal(pins[0].top, 70, "nav sits under the strip it is ordered after")
  assert.equal(pins[1].top, 0, "the strip has nothing above it")
})

test("one unordered layer falls back to document order", () => {
  const pins = [pin("nav", 150, 2), pin("apps", 70)]
  composed(pins)
  assert.equal(pins[0].top, 0)
  assert.equal(pins[1].top, 150)
})

test("an empty registry publishes a zero stack", () => {
  assert.equal(composed([]), 0)
})

test("order reads a plain number and refuses anything else", () => {
  assert.equal(order(pin("a", 0, 3)), 3)
  assert.equal(order(pin("a", 0, "1.5")), 1.5)
  assert.equal(order(pin("a", 0)), null)
  assert.equal(order(pin("a", 0, "top")), null)
})
