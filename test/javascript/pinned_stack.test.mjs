// [unit] studio/pinned_stack: how the publisher composes the stack. Loaded
// from source as a data: module, like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/pinned_stack.js", import.meta.url), "utf8")
const { composed, stuckSection, sectionBottom, order, readsLive, followerSelectors, pinnedAt, measurePin, stackBottom, stackReading, publishedKey, PUBLISHED_EVENT } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

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

test("a header adopted with no data-pin takes its place in the document, so a layer under it stacks under it", () => {
  const row = fakeEl({ name: "page", h: 50, bottom: 200 })
  const banner = fakeEl({ name: "banner", h: 30, bottom: 30 })
  const header = fakeEl({ h: 64, bottom: 94 })
  // The banner precedes the header (PRECEDING = 2); the row follows it (FOLLOWING = 4).
  header.compareDocumentPosition = (other) => (other === row ? 4 : 2)
  const had = globalThis.document
  globalThis.document = fakeDocument(header, [banner, row])
  try {
    const { layers } = stackReading()
    assert.equal(layers.nav.top, 30, "the banner is above the header")
    assert.equal(layers.page.top, 94, "the row is under the header, not at the top of the window")
  } finally {
    globalThis.document = had
  }
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

test("a publish is announced only when the stack moved: its bottom, its mode or its travel", () => {
  const base = { stack: 50, timeline: true, travel: 46 }
  assert.equal(publishedKey(base), publishedKey({ ...base, pins: [] }), "the layers alone do not count")
  assert.notEqual(publishedKey(base), publishedKey({ ...base, stack: 96 }))
  assert.notEqual(publishedKey(base), publishedKey({ ...base, timeline: false }))
  assert.notEqual(publishedKey(base), publishedKey({ ...base, travel: 0 }))
  assert.equal(PUBLISHED_EVENT, "studio:pinned-stack-published")
})

// --- the section layer (task stacked-section-headers) ------------------------
//
// Many headers, one layer. A header waiting below the fold must not move the stack,
// and only the stuck one adds its edge.

const rect = (top, parentTop, parentBottom = parentTop + 5000) => ({ top, bottom: top + 36, parentTop, parentBottom })

test("a header counts once it leaves its place, until its section's end has pushed it out", () => {
  const at = (...args) => stuckSection([rect(...args)], 100)
  assert.equal(at(400, 400), -1, "below the fold, in its place")
  assert.equal(at(100, 100), -1, "resting exactly on the line, in its place")
  assert.equal(at(100, 60), 0, "held on the line")
  assert.equal(at(80, -500, 116), 0, "being pushed out: part of it still shows")
  assert.equal(at(64, -500, 100), -1, "pushed out whole")
})

test("a header stays stuck while the line rises ahead of it in a navbar's collapse", () => {
  assert.equal(stuckSection([rect(121, -400)], 116), 0)
})

test("a stuck header's bottom is one height under the line, whatever its own top still says", () => {
  assert.equal(sectionBottom(rect(121, -400), 116), 152)
  assert.equal(sectionBottom(rect(80, -500, 116), 100), 116, "or its section's end")
})

test("of the headers on the page, the one at the line is the stuck one", () => {
  assert.equal(stuckSection([rect(-900, -900), rect(100, -300), rect(900, 900)], 100), 1)
})

const sectionEl = (top, parentTop = top - 500, parentBottom = parentTop + 5000) => {
  const el = fakeEl({ h: 36, bottom: top + 36 })
  el.getBoundingClientRect = () => ({ top, bottom: top + 36 })
  el.parentElement = { getBoundingClientRect: () => ({ top: parentTop, bottom: parentBottom }) }
  el.compareDocumentPosition = () => 0
  return el
}

// A nav, a page row under it, and the given headers, in document order.
const withSections = (sections, { attrs = {}, style = {}, position = "sticky", navH = 64, navBottom = 64, pageBottom = 120 } = {}) => {
  const nav = fakeEl({ name: "nav", h: navH, bottom: navBottom, attrs, style })
  const page = fakeEl({ name: "page", h: 56, bottom: pageBottom })
  const doc = fakeDocument(nav, [page])
  const all = doc.querySelectorAll
  doc.querySelectorAll = (sel) => (sel === "[data-pin-section]" ? sections : all(sel))
  return { doc, win: { getComputedStyle: () => ({ position }) } }
}

const reading = (sections, options) => {
  const { doc, win } = withSections(sections, options)
  const saved = [globalThis.document, globalThis.window]
  globalThis.document = doc
  globalThis.window = win
  try { return stackReading() } finally { [globalThis.document, globalThis.window] = saved }
}

test("headers waiting below the fold do not move the stack, and publish at height 0", () => {
  const r = reading([sectionEl(900, 900), sectionEl(2000, 2000)])
  assert.equal(r.bottom, 120)
  assert.deepEqual(r.layers.section, { h: 0, top: 120, bottom: 0 })
})

test("the stack bottom includes the stuck header", () => {
  const r = reading([sectionEl(-400, -900), sectionEl(120), sectionEl(900, 900)])
  assert.equal(r.bottom, 156)
  assert.deepEqual(r.layers.section, { h: 36, top: 120, bottom: 156 })
})

test("a header being pushed out gives its room back", () => {
  const r = reading([sectionEl(100, -500, 136), sectionEl(900, 900)])
  assert.equal(r.bottom, 136)
  assert.deepEqual(r.layers.section, { h: 16, top: 120, bottom: 136 })
})

test("a header the CSS left in the flow never counts", () => {
  const r = reading([sectionEl(120), sectionEl(900, 900)], { position: "relative" })
  assert.equal(r.bottom, 120)
  assert.equal(r.layers.section.h, 0)
})

test("on the scroll timeline the stuck header stacks by height too", () => {
  const options = { attrs: { "data-nav-timeline-on": "" }, style: { "--nav-band": "40px" }, navH: 104 }
  const r = reading([sectionEl(120), sectionEl(900, 900)], options)
  // The compact bar 64, the row 56, the bar 36.
  assert.equal(r.bottom, 156)
  assert.deepEqual(r.layers.section, { h: 36, top: 120, bottom: 156 })
})

test("the publisher puts the bar on the stuck header alone, and a swap keeps the roster", async () => {
  const toggled = (el) => { el.toggleAttribute = (n, on) => (on ? el.setAttribute(n, "") : el.removeAttribute(n)); return el }
  let top = 900
  const first = toggled(sectionEl(0))
  first.getBoundingClientRect = () => ({ top, bottom: top + 36 })
  first.parentElement = { getBoundingClientRect: () => ({ top: top === 900 ? 900 : -400, bottom: 4000 }) }
  const second = toggled(sectionEl(2000, 2000))
  second.setAttribute("data-stuck", "") // a Turbo snapshot's leftover
  const { doc, win } = withSections([first, second])
  toggled(doc.documentElement)
  const saved = ["window", "document", "ResizeObserver", "performance", "setTimeout"].map((k) => [k, globalThis[k]])
  globalThis.setTimeout = () => 0 // the settle timer, which would outlive the test
  const scroll = []
  globalThis.document = doc
  globalThis.performance = { now: () => 1000 }
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
  globalThis.window = { ...win, ResizeObserver: globalThis.ResizeObserver, requestAnimationFrame: (fn) => fn(),
    location: { hash: "" }, addEventListener: (type, fn) => { if (type === "scroll") scroll.push(fn) } }
  try {
    const mod = await freshModule()
    mod.startPinnedStack()
    assert.equal(doc.documentElement.hasAttribute("data-pin-live"), true, "the publisher says it runs")
    assert.equal(first.hasAttribute("data-stuck"), false)
    assert.equal(second.hasAttribute("data-stuck"), false, "the leftover is cleared")
    assert.equal(doc.documentElement.hasAttribute("data-pin-section-stuck"), false)
    assert.equal(doc.documentElement.style.getPropertyValue("--pin-section-top"), "120px", "the line is published while none is stuck")

    top = 120
    scroll.forEach((fn) => fn())
    assert.equal(first.hasAttribute("data-stuck"), true)
    assert.equal(second.hasAttribute("data-stuck"), false)
    assert.equal(doc.documentElement.hasAttribute("data-pin-section-stuck"), true)
  } finally {
    saved.forEach(([k, v]) => { globalThis[k] = v })
  }
})

test("a publish that moved a layer's top asks for one more frame, and it ends", async () => {
  const saved = ["window", "document", "ResizeObserver", "performance", "setTimeout"].map((k) => [k, globalThis[k]])
  globalThis.setTimeout = () => 0 // the settle timer, which would outlive the test
  const nav = fakeEl({ name: "nav", h: 64, bottom: 64 })
  const page = fakeEl({ name: "page", h: 56, bottom: 120 })
  const doc = fakeDocument(nav, [page])
  const frames = []
  const scroll = []
  globalThis.document = doc
  globalThis.performance = { now: () => 1000 }
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
  globalThis.window = { ResizeObserver: globalThis.ResizeObserver, location: { hash: "" }, requestAnimationFrame: (fn) => frames.push(fn),
    addEventListener: (type, fn) => { if (type === "scroll") scroll.push(fn) } }
  const drain = () => { let n = 0; while (frames.length) { frames.shift()(); n++ } return n }
  try {
    const mod = await freshModule()
    mod.startPinnedStack()
    drain()
    assert.equal(frames.length, 0)
    // The navbar's edge moves; the page row's top moves with it, one publish on.
    nav.rect.bottom = 40
    scroll.forEach((fn) => fn())
    const passes = drain()
    assert.equal(passes, 2, "the publish that moved the top, and the one after it")
  } finally {
    saved.forEach(([k, v]) => { globalThis[k] = v })
  }
})

// The publisher started in a page with no section headers, with the frames and the
// timers held for the test to run.
const heldPublisher = async ({ hash = "", navigationType = "navigate", getElementById = () => null } = {}) => {
  const saved = ["window", "document", "ResizeObserver", "performance", "setTimeout"].map((k) => [k, globalThis[k]])
  const nav = fakeEl({ name: "nav", h: 64, bottom: 64 })
  const page = fakeEl({ name: "page", h: 56, bottom: 120 })
  const doc = fakeDocument(nav, [page])
  doc.getElementById = getElementById
  doc.readyState = "complete"
  const frames = []
  const timers = []
  const scroll = []
  let now = 1000
  globalThis.document = doc
  globalThis.performance = { now: () => now, getEntriesByType: () => [{ type: navigationType }] }
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
  globalThis.setTimeout = (fn) => { timers.push(fn); return timers.length }
  globalThis.window = { ResizeObserver: globalThis.ResizeObserver, location: { hash }, requestAnimationFrame: (fn) => frames.push(fn),
    addEventListener: (type, fn) => { if (type === "scroll") scroll.push(fn) } }
  const mod = await freshModule()
  mod.startPinnedStack()
  return { nav, frames, timers, scroll, tick: (ms) => { now += ms },
    drain: () => { let n = 0; while (frames.length && n < 50) { frames.shift()(); n++ } return n },
    restore: () => saved.forEach(([k, v]) => { globalThis[k] = v }) }
}

test("a settle reads the layers once more, after it gives their copies back", async () => {
  const run = await heldPublisher()
  try {
    run.drain()
    run.tick(1000)
    run.nav.rect.bottom = 40
    run.scroll.forEach((fn) => fn())
    run.drain()
    assert.equal(run.timers.length > 0, true, "a motion publish arms the settle")
    run.frames.length = 0
    run.tick(1000)
    run.timers.at(-1)()
    assert.equal(run.frames.length > 0, true, "another frame is asked for")
  } finally {
    run.restore()
  }
})

test("a load with a hash looks for its section; a reload or a Back keeps the reader's place", async () => {
  for (const [type, landed] of [["navigate", true], ["reload", false], ["back_forward", false]]) {
    let looked = false
    const run = await heldPublisher({ hash: "#modals", navigationType: type, getElementById: () => { looked = true; return null } })
    run.restore()
    assert.equal(looked, landed, type)
  }
})
