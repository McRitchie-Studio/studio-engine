// [unit] studio/pinned_stack: how the publisher composes the stack. Loaded
// from source as a data: module, like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/pinned_stack.js", import.meta.url), "utf8")
const { composed, order, readsLive, followerSelectors, pinnedAt, measurePin, stackBottom, stackReading } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

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

// --- the live read and the timeline header (task pinned-stack-live-reads) ----
//
// A fake document small enough to reason about: a header and any extra layers,
// each answering only what measurePin and readStack read. `rect` is where the
// window has the element right now; the root's style records every write.

const fakeStyle = (writes, initial = {}) => {
  const props = new Map(Object.entries(initial))
  return {
    getPropertyValue: (n) => props.get(n) ?? "",
    setProperty: (n, v) => { props.set(n, v); writes.push(n) },
    removeProperty: (n) => { props.delete(n); writes.push(`-${n}`) },
    props
  }
}
const fakeEl = ({ name, h, bottom, attrs = {}, style = {}, writes = [] }) => {
  const a = new Map(Object.entries(attrs))
  if (name) a.set("data-pin", name)
  return {
    offsetHeight: h,
    rect: { bottom },
    getBoundingClientRect() { return { bottom: this.rect.bottom } },
    getAttribute: (n) => (a.has(n) ? a.get(n) : null),
    hasAttribute: (n) => a.has(n),
    setAttribute: (n, v) => a.set(n, v),
    removeAttribute: (n) => a.delete(n),
    style: fakeStyle(writes, style)
  }
}
const fakeDocument = (header, layers = []) => {
  const rootWrites = []
  const listeners = {}
  const root = fakeEl({ h: 0, bottom: 0, writes: rootWrites })
  return {
    rootWrites,
    listeners,
    documentElement: root,
    body: {},
    head: {},
    styleSheets: [],
    querySelector: (sel) => (sel === "header" ? header : null),
    querySelectorAll: (sel) => (sel === "[data-pin]" ? [header, ...layers].filter((e) => e && e.hasAttribute("data-pin")) : []),
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
    dispatchEvent: (e) => (listeners[e.type] || []).forEach((fn) => fn(e))
  }
}
// A fresh copy of the module per use: startPinnedStack runs once per module.
let copies = 0
const freshModule = () => import(`data:text/javascript,${encodeURIComponent(`${source}\n// copy ${++copies}`)}`)

test("on the timeline each layer sits one height below the layers above it, whatever the scroll", () => {
  const nav = { name: "nav", h: 64, bottom: 0, el: pin("nav", 0).el }
  const apps = { name: "apps", h: 40, bottom: 0, el: pin("apps", 0).el }
  const hidden = { name: "devnet", h: 0, bottom: 0, el: pin("devnet", 0).el }
  const pins = [nav, apps, hidden]
  assert.equal(pinnedAt(pins), 104)
  assert.deepEqual(pins.map((p) => [p.top, p.bottom]), [[0, 64], [64, 104], [104, 0]])
})

test("pinnedAt honours data-pin-order and settles", () => {
  const pins = [{ name: "nav", h: 64, el: pin("nav", 0, 2).el }, { name: "apps", h: 40, el: pin("apps", 0, 1).el }]
  assert.equal(pinnedAt(pins), 104)
  assert.deepEqual(pins.map((p) => [p.top, p.bottom]), [[40, 104], [0, 40]])
})

test("a timeline header measures as its compact bar and reads no rect", () => {
  const header = fakeEl({ name: "nav", h: 104, bottom: 140, attrs: { "data-nav-timeline-on": "" }, style: { "--nav-band": "40px" } })
  header.getBoundingClientRect = () => { throw new Error("read a rect on the timeline") }
  assert.equal(measurePin(header, "nav", true, true).h, 64)
})

test("the live read is a fresh measure, never the root's lagging value", () => {
  const header = fakeEl({ name: "nav", h: 64, bottom: 64 })
  const had = globalThis.document
  globalThis.document = fakeDocument(header)
  try {
    // The root still holds what the last settled write left there.
    globalThis.document.documentElement.style.props.set("--pin-stack-bottom", "94px")
    assert.equal(stackBottom(), 64)
    // Mid-motion the header's edge moves; the read moves with it, on call.
    header.rect.bottom = 34
    assert.equal(stackBottom(), 34)
    assert.deepEqual(stackReading(), { bottom: 34, timeline: false, travel: 0, layers: { nav: { h: 64, top: 0, bottom: 34 } } })
  } finally {
    globalThis.document = had
  }
})

test("on the timeline the live read is the pinned bar and the travel is start plus band", () => {
  const header = fakeEl({ name: "nav", h: 104, bottom: 140, attrs: { "data-nav-timeline-on": "" },
    style: { "--nav-band": "40px", "--nav-start": "36px" } })
  const had = globalThis.document
  globalThis.document = fakeDocument(header)
  try {
    assert.deepEqual(stackReading(), { bottom: 64, timeline: true, travel: 76, layers: { nav: { h: 64, top: 0, bottom: 64 } } })
  } finally {
    globalThis.document = had
  }
})

test("window.studioPinnedStack exposes the live read to scripts with no import", async () => {
  const hadWindow = globalThis.window
  globalThis.window = {}
  try {
    const mod = await freshModule()
    assert.equal(globalThis.window.studioPinnedStack.bottom, mod.stackBottom)
    assert.equal(globalThis.window.studioPinnedStack.read, mod.stackReading)
  } finally {
    globalThis.window = hadWindow
  }
})

// Drives the publisher itself through a scroll: every rAF runs at once, and the
// clock advances 8ms per frame so the gesture stays "in motion" throughout.
const scrollRun = async (header, frames) => {
  const saved = ["window", "document", "ResizeObserver", "performance"].map((k) => [k, globalThis[k]])
  const doc = fakeDocument(header)
  const follower = fakeEl({ h: 10, bottom: 0, attrs: { "data-pin-follow": "" } })
  doc.querySelectorAll = ((orig) => (sel) => (sel === "[data-pin-follow]" ? [follower] : orig(sel)))(doc.querySelectorAll)
  const winListeners = {}
  let now = 1000
  globalThis.document = doc
  globalThis.performance = { now: () => now }
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
  globalThis.window = {
    ResizeObserver: globalThis.ResizeObserver,
    requestAnimationFrame: (fn) => fn(),
    addEventListener: (type, fn) => { (winListeners[type] ||= []).push(fn) }
  }
  const timers = []
  const hadSetTimeout = globalThis.setTimeout
  globalThis.setTimeout = (fn) => { timers.push(fn); return timers.length }
  try {
    const mod = await freshModule()
    mod.startPinnedStack()
    doc.rootWrites.length = 0
    const followerWrites = []
    follower.style.setProperty = (n) => followerWrites.push(n)
    for (const f of frames) {
      now += 8
      f()
      ;(winListeners.scroll || []).forEach((fn) => fn())
    }
    return { rootWrites: [...doc.rootWrites], followerWrites, doc }
  } finally {
    globalThis.setTimeout = hadSetTimeout
    saved.forEach(([k, v]) => { globalThis[k] = v })
  }
}

test("a timeline header publishes nothing through a flick: no root write, no follower write", async () => {
  const header = fakeEl({ name: "nav", h: 104, bottom: 140, attrs: { "data-nav-timeline-on": "" },
    style: { "--nav-band": "40px", "--nav-start": "36px" } })
  // The header's rect moves every frame, as the band scrolls away.
  const frames = [130, 110, 90, 70, 64, 64, 64, 90, 140].map((b) => () => { header.rect.bottom = b })
  const run = await scrollRun(header, frames)
  assert.deepEqual(run.rootWrites, [], "root writes during the flick")
  assert.deepEqual(run.followerWrites, [], "follower writes during the flick")
})

test("off the timeline the same flick does reach the followers (the control)", async () => {
  const header = fakeEl({ name: "nav", h: 104, bottom: 140 })
  const frames = [130, 110, 90, 70].map((b) => () => { header.rect.bottom = b })
  const run = await scrollRun(header, frames)
  assert.ok(run.followerWrites.includes("--pin-stack-bottom"), JSON.stringify(run.followerWrites))
})

test("a resize on the timeline still publishes, once, through the refresh event", async () => {
  const header = fakeEl({ name: "nav", h: 104, bottom: 140, attrs: { "data-nav-timeline-on": "" },
    style: { "--nav-band": "40px", "--nav-start": "0px" } })
  const run = await scrollRun(header, [() => {
    header.style.props.set("--nav-band", "48px")
    globalThis.document.dispatchEvent({ type: "studio:pinned-stack-refresh" })
  }])
  assert.ok(run.rootWrites.includes("--pin-stack-bottom"))
  assert.ok(run.rootWrites.includes("--pin-stack-travel"))
  assert.equal(run.doc.documentElement.style.props.get("--pin-stack-bottom"), "56px")
})
