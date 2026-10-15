// [unit] studio/pinned_stack: how the publisher composes the stack. Loaded
// from source as a data: module, like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/pinned_stack.js", import.meta.url), "utf8")
const { composed, order, readsLive, followerSelectors } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

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

// --- the motion write (task smooth-navbar-collapse) --------------------------
//
// While a scroll is in motion the publisher writes the stack onto the elements
// that read it live, not documentElement, whose every write restyles the whole
// document. Which elements read it live is decided here.

test("a declaration that positions off the stack reads it live", () => {
  assert.equal(readsLive("top: var(--nav-bottom, var(--nav-h, 6rem)); height: calc(100% - var(--nav-bottom))"), true)
  assert.equal(readsLive("top: var(--pin-stack-bottom, 0px)"), true)
  assert.equal(readsLive("--sheet-top: calc(var(--nav-h) + 1px)"), true)
})

test("scroll-margin and scroll-padding are served by the settled root", () => {
  assert.equal(readsLive("scroll-margin-top: var(--nav-h, 64px)"), false)
  assert.equal(readsLive("scroll-padding-top: calc(var(--nav-bottom) + 1rem)"), false)
})

test("--nav-hold is not --nav-h", () => {
  assert.equal(readsLive("margin-bottom: calc(0px + var(--nav-hold, 0px) * var(--nav-p, 0))"), false)
})

test("the stylesheet scan lifts the selectors of live rules, nested ones included", () => {
  const rule = (selectorText, cssText) => ({ selectorText, style: { cssText } })
  const sheets = [
    { cssRules: [
      rule(".pkg-matrix thead th", "top: var(--pin-stack-bottom, 0px);"),
      rule(".anchor", "scroll-margin-top: var(--nav-h);"),
      { cssRules: [rule(".lane-head, .strip", "top: var(--pin-apps-top);")] }
    ] },
    { get cssRules() { throw new Error("cross-origin") } }
  ]
  const found = followerSelectors(sheets)
  assert.ok(found.includes(".pkg-matrix thead th"))
  assert.ok(found.includes(".lane-head"))
  assert.ok(found.includes(".strip"))
  assert.ok(!found.includes(".anchor"))
  assert.ok(found.includes("[data-pin-follow]"))
})
