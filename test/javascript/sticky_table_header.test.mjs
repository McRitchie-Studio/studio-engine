// [unit] studio/sticky_table_header: where the cloned header row is placed, and
// what re-places it. The asset is a classic script (an IIFE, no exports), so it
// runs here in a node:vm context over a fake document that answers only what
// the script reads. Each test gets a fresh context: the script guards itself
// with window.StudioStickyTableHeaders.loaded.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../app/assets/javascripts/studio/sticky_table_header.js", import.meta.url), "utf8")

const rect = (r) => ({ top: 0, bottom: 0, left: 0, width: 0, height: 0, ...r })

// An element with only the surface the script touches.
function element(tag, extra = {}) {
  const attrs = {}
  const listeners = {}
  return {
    tagName: tag.toUpperCase(),
    nodeType: 1,
    style: {},
    className: "",
    innerHTML: "",
    children: [],
    classList: { add() {} },
    attrs,
    rect: rect({}),
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    hasAttribute: (name) => name in attrs,
    setAttribute: (name, value) => { attrs[name] = String(value) },
    removeAttribute: (name) => { delete attrs[name] },
    appendChild(child) { this.children.push(child); return child },
    remove() {},
    closest: () => null,
    matches: () => false,
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener: (type, fn) => { listeners[type] = fn },
    removeEventListener() {},
    getBoundingClientRect() { return this.rect },
    ...extra
  }
}

// A page with one long table whose header row has scrolled up under the bar,
// and a pinned stack the test sets by hand.
function page({ reading, rootProps = {} } = {}) {
  const th = element("th")
  const thead = element("thead", { outerHTML: "<thead><tr><th>Name</th></tr></thead>" })
  thead.rect = rect({ top: -200, bottom: -160, height: 40, left: 0, width: 800 })
  thead.querySelector = (sel) => (sel === "th" ? th : null)
  thead.querySelectorAll = (sel) => (sel === "th" ? [th] : [])
  const scroller = element("div")
  scroller.rect = rect({ left: 0, width: 800 })
  const table = element("table", { tHead: thead, parentElement: scroller })
  table.rect = rect({ top: -200, bottom: 3000, left: 0, width: 800 })
  const header = element("header")

  const created = []
  const docListeners = {}
  const winListeners = {}
  const frames = []
  const observers = []
  const stack = { reading: reading || { bottom: 96, timeline: false, travel: 0 }, reads: 0 }

  const body = element("body")
  body.contains = () => true
  const document = {
    documentElement: element("html"),
    body,
    createElement: (tag) => { const el = element(tag); created.push(el); return el },
    querySelector: (sel) => (sel === "header" ? header : null),
    querySelectorAll: (sel) => (sel === "[data-pin]" ? [header] : sel.includes("table") ? [table] : []),
    addEventListener: (type, fn) => { (docListeners[type] ||= []).push(fn) }
  }
  const window = {
    scrollY: 600,
    requestAnimationFrame: (fn) => { frames.push(fn); return frames.length },
    addEventListener: (type, fn) => { (winListeners[type] ||= []).push(fn) },
    studioPinnedStack: {
      read: () => { stack.reads++; return { ...stack.reading, layers: {} } },
      bottom: () => stack.reading.bottom
    },
    ResizeObserver: class {
      constructor(cb) { this.cb = cb; this.watched = []; observers.push(this) }
      observe(el) { this.watched.push(el) }
      disconnect() {}
    }
  }
  const context = {
    window,
    document,
    requestAnimationFrame: window.requestAnimationFrame,
    ResizeObserver: window.ResizeObserver,
    MutationObserver: undefined,
    Node: { ELEMENT_NODE: 1 },
    getComputedStyle: (el) => ({
      position: "static",
      getPropertyValue: (name) => (el === document.documentElement ? (rootProps[name] ?? "") : "")
    })
  }
  vm.createContext(context)
  vm.runInContext(source, context)

  const fire = (type, detail) => (docListeners[type] || []).forEach((fn) => fn({ type, detail }))
  const flush = () => { while (frames.length) frames.shift()() }
  const clone = () => created.find((el) => el.className === "sticky-table-header-clone")
  return { window, stack, fire, flush, clone, observers, header, docListeners, winListeners }
}

function booted(options) {
  const p = page(options)
  p.fire("DOMContentLoaded")
  p.flush()
  return p
}

test("the clone sits at the pinned stack's bottom, read live", () => {
  const p = booted({ reading: { bottom: 50, timeline: false, travel: 0 } })
  assert.equal(p.clone().style.display, "block")
  assert.equal(p.clone().style.top, "50px")
  assert.ok(p.stack.reads > 0, "the live read was taken")
})

test("a refresh from the timeline header re-places the clone with no scroll", () => {
  // The restored-scroll load: the clone is placed while the header is still
  // expanded, then the nav-collapse controller starts and publishes the compact
  // bar. Nothing scrolls and nothing resizes.
  const p = booted({ reading: { bottom: 96, timeline: false, travel: 0 } })
  assert.equal(p.clone().style.top, "96px")
  p.stack.reading = { bottom: 50, timeline: true, travel: 46 }
  p.fire("studio:pinned-stack-refresh")
  p.flush()
  assert.equal(p.clone().style.top, "50px")
})

test("a stack publish re-places the clone in the same call, from the publisher's reading", () => {
  const p = booted({ reading: { bottom: 96, timeline: false, travel: 0 } })
  const before = p.stack.reads
  p.fire("studio:pinned-stack-published", { bottom: 64, timeline: false, travel: 0 })
  assert.equal(p.clone().style.top, "64px", "placed without waiting for a frame")
  assert.equal(p.stack.reads, before, "the event's reading is used, not a second read")
})

test("a resize of any pinned layer re-places the clone synchronously", () => {
  const p = booted({ reading: { bottom: 96, timeline: false, travel: 0 } })
  const observer = p.observers.at(-1)
  assert.ok(observer.watched.includes(p.header), "the header is observed")
  p.stack.reading = { bottom: 70, timeline: false, travel: 0 }
  observer.cb([])
  assert.equal(p.clone().style.top, "70px", "placed inside the observer callback, before paint")
})

test("the timeline edge closes the expanded header's travel as the page scrolls", () => {
  const reading = { bottom: 50, timeline: true, travel: 46 }
  const p = page()
  p.window.scrollY = 0
  assert.equal(p.window.StudioStickyTableHeaders.pinnedEdge(reading), 96)
  p.window.scrollY = 20
  assert.equal(p.window.StudioStickyTableHeaders.pinnedEdge(reading), 76)
  p.window.scrollY = 608
  assert.equal(p.window.StudioStickyTableHeaders.pinnedEdge(reading), 50)
})

test("off the timeline the edge is the stack's bottom whatever the scroll", () => {
  const p = page()
  p.window.scrollY = 0
  assert.equal(p.window.StudioStickyTableHeaders.pinnedEdge({ bottom: 143, timeline: false, travel: 99 }), 143)
})

test("with no publisher it falls back to --pin-stack-bottom and never to --nav-h", () => {
  const p = page({ rootProps: { "--pin-stack-bottom": "57px", "--nav-h": "96px" } })
  delete p.window.studioPinnedStack
  assert.equal(p.window.StudioStickyTableHeaders.pinnedEdge(), 57)
  const bare = page({ rootProps: { "--nav-h": "96px" } })
  delete bare.window.studioPinnedStack
  assert.equal(bare.window.StudioStickyTableHeaders.pinnedEdge(), 0, "a header height is not an edge")
})

test("placement: hidden until the header reaches the edge, then pushed up by the table's end", () => {
  // Spread out of the vm's realm: deepStrictEqual compares prototypes.
  const placement = (m) => ({ ...page().window.StudioStickyTableHeaders.placement(m) })
  assert.deepEqual(placement({ edge: 50, headerTop: 51, tableBottom: 900, cloneHeight: 40 }), { active: false, top: null })
  assert.deepEqual(placement({ edge: 50, headerTop: 50, tableBottom: 900, cloneHeight: 40 }), { active: true, top: 50 })
  assert.deepEqual(placement({ edge: 50, headerTop: -300, tableBottom: 70, cloneHeight: 40 }), { active: true, top: 30 })
  assert.deepEqual(placement({ edge: 50, headerTop: -300, tableBottom: 50, cloneHeight: 40 }), { active: false, top: null })
})
