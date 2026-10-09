// [unit] studio/identity_mini: when the full identity card counts as gone,
// what showing the compact bar does to it, and one bar's watch on one card.
// Loaded from source as a data: module, like profile_form.test.mjs; the module
// imports nothing.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/identity_mini.js", import.meta.url), "utf8")
const { VISIBLE_CLASS, FULL_SELECTOR, SHOW_BELOW_RATIO, OBSERVER_OPTIONS, cardGone, showBar, IdentityMini } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const fakeBar = () => {
  const classes = new Set()
  return {
    classes,
    inert: true,
    classList: { toggle(name, on) { if (on) classes.add(name); else classes.delete(name) } }
  }
}

// An IntersectionObserver the test drives by hand.
const fakeObserver = () => {
  const made = []
  class Observer {
    constructor(callback, options) { this.callback = callback; this.options = options; this.watched = []; this.disconnected = false; made.push(this) }
    observe(element) { this.watched.push(element) }
    disconnect() { this.disconnected = true }
    report(entry) { this.callback([entry]) }
  }
  return { Observer, made }
}

test("the bar takes over part-way: once less than the ratio of the card is on screen", () => {
  assert.equal(cardGone({ isIntersecting: true, intersectionRatio: 1 }), false)
  assert.equal(cardGone({ isIntersecting: true, intersectionRatio: SHOW_BELOW_RATIO }), false)
  assert.equal(cardGone({ isIntersecting: true, intersectionRatio: SHOW_BELOW_RATIO - 0.01 }), true)
  assert.equal(cardGone({ isIntersecting: true, intersectionRatio: 0 }), true)
})

test("a card that does not intersect at all is gone whatever its ratio says", () => {
  assert.equal(cardGone({ isIntersecting: false, intersectionRatio: 1 }), true)
})

test("the watch has a threshold either side of the ratio and discounts the navbar", () => {
  assert.ok(OBSERVER_OPTIONS.threshold.includes(SHOW_BELOW_RATIO))
  assert.ok(OBSERVER_OPTIONS.threshold.some((t) => t < SHOW_BELOW_RATIO && t > 0))
  assert.ok(OBSERVER_OPTIONS.threshold.some((t) => t > SHOW_BELOW_RATIO))
  assert.match(OBSERVER_OPTIONS.rootMargin, /^-\d+px /)
  assert.equal(FULL_SELECTOR, "[data-studio-identity-full]")
})

test("a shown bar is visible and reachable; a hidden one is inert", () => {
  const bar = fakeBar()
  showBar(bar, true)
  assert.ok(bar.classes.has(VISIBLE_CLASS))
  assert.equal(bar.inert, false)
  showBar(bar, false)
  assert.equal(bar.classes.has(VISIBLE_CLASS), false)
  assert.equal(bar.inert, true)
})

test("the bar follows the card as it scrolls away and back", () => {
  const { Observer, made } = fakeObserver()
  const bar = fakeBar()
  const card = { card: true }
  const mini = new IdentityMini(bar, card, Observer)
  assert.equal(mini.start(), true)
  assert.deepEqual(made[0].watched, [card])
  assert.equal(made[0].options, OBSERVER_OPTIONS)
  assert.equal(bar.inert, true, "nothing shows until the observer reports")

  made[0].report({ isIntersecting: true, intersectionRatio: 0.3 })
  assert.ok(bar.classes.has(VISIBLE_CLASS))
  assert.equal(bar.inert, false)

  made[0].report({ isIntersecting: true, intersectionRatio: 0.9 })
  assert.equal(bar.classes.has(VISIBLE_CLASS), false)
  assert.equal(bar.inert, true)
})

test("a browser with no IntersectionObserver leaves the bar hidden and inert", () => {
  const bar = fakeBar()
  assert.equal(new IdentityMini(bar, { card: true }, undefined).start(), false)
  assert.equal(bar.inert, true)
  assert.equal(bar.classes.size, 0)
})

test("a page with no full card watches nothing", () => {
  const { Observer, made } = fakeObserver()
  assert.equal(new IdentityMini(fakeBar(), null, Observer).start(), false)
  assert.equal(made.length, 0)
})

test("starting twice keeps one observer", () => {
  const { Observer, made } = fakeObserver()
  const mini = new IdentityMini(fakeBar(), { card: true }, Observer)
  mini.start()
  mini.start()
  assert.equal(made.length, 2)
  assert.equal(made[0].disconnected, true)
  assert.equal(made[1].disconnected, false)
})

test("reset stops the watch and hides a showing bar, as the bar ships", () => {
  const { Observer, made } = fakeObserver()
  const bar = fakeBar()
  const mini = new IdentityMini(bar, { card: true }, Observer)
  mini.start()
  made[0].report({ isIntersecting: false, intersectionRatio: 0 })
  assert.equal(bar.inert, false)

  mini.reset()
  assert.equal(made[0].disconnected, true)
  assert.equal(bar.classes.has(VISIBLE_CLASS), false)
  assert.equal(bar.inert, true)
})
