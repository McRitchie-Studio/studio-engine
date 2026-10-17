// [unit] studio/nav_collapse: one frame of the navbar collapse, as a pure
// function. Loaded from source as a data: module, like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/nav_collapse.js", import.meta.url), "utf8")
const { collapseFrame, shadowLit, readTuning, holdFix, inFlow, DEFAULT_RAMP, DEFAULT_MAX_STEP } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

// A long page on a phone band: ramp 120, cap 5px of header travel per frame.
const page = { ramp: 120, maxPx: 5, scrollHeight: 5000, innerHeight: 844, reduce: false }
const smoothstep = (t) => t * t * (3 - 2 * t)

test("an unscrolled page stays expanded and asks for no frame", () => {
  assert.deepEqual(collapseFrame({ ...page, y: 0, p: 0 }), { p: 0, settling: false })
})

test("a slow scroll lands exactly on the smoothstepped target", () => {
  const frame = collapseFrame({ ...page, y: 8, p: 0 })
  assert.equal(frame.p, smoothstep(8 / 120))
  assert.equal(frame.settling, false)
})

test("past the ramp the target is fully collapsed", () => {
  let p = 0
  for (let frames = 0; frames < 20; frames++) p = collapseFrame({ ...page, y: 400, p }).p
  assert.equal(p, 1)
})

test("a flick travels at most the capped step per frame and keeps scheduling", () => {
  const maxStep = (3 * 5) / 120
  const first = collapseFrame({ ...page, y: 120, p: 0 })
  assert.equal(first.p, maxStep)
  assert.equal(first.settling, true)

  // Converges linearly and lands exactly, in ceil(1 / maxStep) frames.
  let frame = first
  let frames = 1
  while (frame.settling) {
    frame = collapseFrame({ ...page, y: 120, p: frame.p })
    frames++
    assert.ok(frames <= 20, "the collapse never settled")
  }
  assert.equal(frame.p, 1)
  assert.equal(frames, Math.ceil(1 / maxStep))
})

test("the cap applies on the way back up too", () => {
  const frame = collapseFrame({ ...page, y: 0, p: 1 })
  assert.equal(frame.p, 1 - (3 * 5) / 120)
  assert.equal(frame.settling, true)
})

test("a short page snaps expanded instead of collapsing away its own scroll room", () => {
  const short = { ...page, scrollHeight: 844 + 100 }
  assert.deepEqual(collapseFrame({ ...short, y: 100, p: 0 }), { p: 0, settling: false })
})

test("the short-page guard adds back the shrink already applied", () => {
  // Collapsed, the document has 30px left to scroll. Expanded it would have
  // 30 + 120 = 150, past the 144 the guard needs, so the frame ramps toward
  // the scroll's target (one capped step down from 1) instead of snapping to 0.
  // Measuring the collapsed document alone would read 30 and flap open.
  const collapsed = { ...page, scrollHeight: 844 + 30 }
  assert.deepEqual(collapseFrame({ ...collapsed, y: 30, p: 1 }), { p: 1 - (3 * 5) / 120, settling: true })
})

test("reduced motion snaps on the 60/5 hysteresis with no ramp", () => {
  const reduce = { ...page, reduce: true }
  assert.deepEqual(collapseFrame({ ...reduce, y: 61, p: 0 }), { p: 1, settling: false })
  assert.deepEqual(collapseFrame({ ...reduce, y: 30, p: 0 }), { p: 0, settling: false })
  assert.deepEqual(collapseFrame({ ...reduce, y: 30, p: 1 }), { p: 1, settling: false })
  assert.deepEqual(collapseFrame({ ...reduce, y: 4, p: 1 }), { p: 0, settling: false })
})

test("the shadow lights past 60 and goes out under 5", () => {
  assert.equal(shadowLit(false, 60), false)
  assert.equal(shadowLit(false, 61), true)
  assert.equal(shadowLit(true, 6), true)
  assert.equal(shadowLit(true, 5), false)
})

test("tuning reads the band's CSS and falls back to the defaults", () => {
  const style = (values) => ({ getPropertyValue: (name) => values[name] || "" })
  assert.deepEqual(readTuning(style({ "--nav-ramp": "120px", "--nav-max-step": "4px" })), { ramp: 120, maxPx: 4 })
  assert.deepEqual(readTuning(style({})), { ramp: DEFAULT_RAMP, maxPx: DEFAULT_MAX_STEP })
  assert.deepEqual(readTuning(style({ "--nav-ramp": "0px", "--nav-max-step": "-1px" })), { ramp: 144, maxPx: 5 })
})

// --- the hold (task smooth-navbar-collapse) ---------------------------------
//
// A held header keeps its expanded footprint in the page, so the document
// never shortens. The cap still eases the header itself (task
// eased-navbar-collapse-rate): uncapped, a flick snapped it full to compact in
// one frame.

test("held, a flick eases at the capped step and keeps scheduling until it lands", () => {
  const maxStep = (3 * 5) / 120
  const first = collapseFrame({ ...page, held: true, y: 120, p: 0 })
  assert.equal(first.p, maxStep)
  assert.equal(first.settling, true)

  let frame = first
  let frames = 1
  while (frame.settling) {
    frame = collapseFrame({ ...page, held: true, y: 120, p: frame.p })
    frames++
    assert.ok(frames <= 20, "the collapse never settled")
  }
  assert.equal(frame.p, 1)
  assert.equal(frames, Math.ceil(1 / maxStep))
})

test("held, the way back up eases too", () => {
  const frame = collapseFrame({ ...page, held: true, y: 0, p: 1 })
  assert.equal(frame.p, 1 - (3 * 5) / 120)
  assert.equal(frame.settling, true)
})

test("held, a slow scroll under the cap lands exactly on the scroll position", () => {
  const frame = collapseFrame({ ...page, held: true, y: 8, p: 0 })
  assert.equal(frame.p, smoothstep(8 / 120))
  assert.equal(frame.settling, false)
})

test("held, a short page collapses with its scroll instead of snapping open", () => {
  // The unheld guard would answer p 0 here and stop. Held, it moves toward
  // the scroll position, eased.
  const short = { ...page, held: true, scrollHeight: 900, innerHeight: 844 }
  const frame = collapseFrame({ ...short, y: 56, p: 0 })
  assert.equal(frame.p, (3 * 5) / 120)
  assert.equal(frame.settling, true)
  const unheld = collapseFrame({ ...short, held: false, y: 56, p: 0 })
  assert.equal(unheld.p, 0)
})

test("held, reduced motion still snaps on its hysteresis", () => {
  assert.equal(collapseFrame({ ...page, held: true, reduce: true, y: 61, p: 0 }).p, 1)
  assert.equal(collapseFrame({ ...page, held: true, reduce: true, y: 4, p: 1 }).p, 0)
})

test("the residue is what the linear hold missed", () => {
  // Linear collapse: the CSS margin already holds it exactly.
  assert.equal(holdFix({ rest: 96, height: 74.5, hold: 43, p: 0.5 }), 0)
  // The scrolled state's 1px border: one pixel less margin.
  assert.equal(holdFix({ rest: 96, height: 54, hold: 43, p: 1 }), -1)
  // A collapse that runs ahead of linear mid-ramp: the residue adds the rest.
  assert.equal(holdFix({ rest: 96, height: 70, hold: 43, p: 0.5 }), 4.5)
})

test("only a header in the page's flow is held", () => {
  assert.equal(inFlow("sticky"), true)
  assert.equal(inFlow("relative"), true)
  assert.equal(inFlow("static"), true)
  assert.equal(inFlow("fixed"), false)
  assert.equal(inFlow("absolute"), false)
})

// [unit] the scroll-driven mode: what the timeline is told, measured once.
const { timelineVars, timelineOn, TIMELINE_QUERY, clearTimeline, PINNED_STACK_REFRESH } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

// The hub's header at 1440: 88 -> 48, wordmark 32 -> 20, avatar 40 -> 32.
const hub = { rest: 88, collapsed: 48, brand0: 32, brand1: 20, avatar0: 40, avatar1: 32, nameW: 50 }

test("the band is what the header loses, and the brand scales by its own ratio", () => {
  const vars = timelineVars(hub)
  assert.equal(vars.band, 40)
  assert.equal(vars.brandScale, 0.625)
})

test("the name scales with the avatar, and the icon rail slides by what the account gives up", () => {
  const vars = timelineVars(hub)
  assert.equal(vars.avatarScale, 0.8)
  assert.equal(vars.avatarShrink, 8)
  // 50px of name at 0.8 gives back 10px, plus the avatar's 8px.
  assert.ok(Math.abs(vars.toolsShift - 18) < 1e-9)
})

test("signed out, with no avatar, nothing on the right moves", () => {
  const vars = timelineVars({ ...hub, avatar0: 0, avatar1: 0, nameW: 0 })
  assert.deepEqual([vars.avatarScale, vars.avatarShrink, vars.toolsShift], [1, 0, 0])
})

test("a two-row nav whose avatar keeps its size moves no account", () => {
  const vars = timelineVars({ ...hub, avatar0: 32, avatar1: 32 })
  assert.deepEqual([vars.avatarScale, vars.avatarShrink, vars.toolsShift], [1, 0, 0])
})

test("a header that grows never publishes a negative band", () => {
  assert.equal(timelineVars({ ...hub, collapsed: 90 }).band, 0)
})

test("the timeline needs the opt-in, the wide query and browser support, all three", () => {
  const header = (opted) => ({ hasAttribute: (name) => opted && name === "data-nav-timeline" })
  const had = globalThis.CSS
  try {
    globalThis.CSS = { supports: () => true }
    assert.equal(timelineOn(header(true), true), true)
    assert.equal(timelineOn(header(false), true), false)
    assert.equal(timelineOn(header(true), false), false)
    globalThis.CSS = { supports: () => false }
    assert.equal(timelineOn(header(true), true), false)
  } finally {
    globalThis.CSS = had
  }
  assert.equal(TIMELINE_QUERY, "(min-width: 768px)")
})

test("a header restored below 768px sheds what the timeline left inline", () => {
  const props = new Map([["--nav-band", "40px"], ["--nav-start", "0px"], ["--nav-tools-shift", "18px"], ["--nav-hold", "4px"]])
  const attrs = new Set(["data-nav-timeline", "data-nav-timeline-on"])
  const fired = []
  const hadDocument = globalThis.document
  globalThis.document = { dispatchEvent: (e) => fired.push(e.type) }
  const header = {
    style: { removeProperty: (n) => props.delete(n) },
    hasAttribute: (n) => attrs.has(n),
    removeAttribute: (n) => attrs.delete(n)
  }
  try {
    clearTimeline(header)
    assert.deepEqual([...props.keys()], ["--nav-hold"])
    assert.deepEqual([...attrs], ["data-nav-timeline"])
    // The header's pinned height just grew by the band without its box
    // resizing: the pinned stack is told, once.
    assert.deepEqual(fired, [PINNED_STACK_REFRESH])
    // Clearing a header that was not on the timeline tells nobody.
    clearTimeline(header)
    assert.deepEqual(fired, [PINNED_STACK_REFRESH])
  } finally {
    globalThis.document = hadDocument
  }
})

test("the refresh event is the one studio/pinned_stack listens for", () => {
  const stack = readFileSync(new URL("../../app/javascript/studio/pinned_stack.js", import.meta.url), "utf8")
  assert.match(stack, new RegExp(`REFRESH_EVENT = '${PINNED_STACK_REFRESH}'`))
})

// [unit] crossing 768px while scrolled (task timeline-header-resize-collapse).
// The resize that crosses the query fires the --nav-p path's resize listener,
// which queues a frame, and the query's change then swaps to the timeline
// before that frame runs. The binding is driven here with a hand-run frame
// queue, so the test decides exactly when the queued frame lands.
const { NavCollapse } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

function harness({ wide, scrollY }) {
  const frames = new Map()
  let nextId = 1
  const listeners = { scroll: new Set(), resize: new Set() }
  const queries = new Map()
  const media = (q) => {
    if (!queries.has(q)) {
      const mq = { matches: q === "(min-width: 768px)" ? wide : false, handlers: new Set(),
        addEventListener: (_, f) => mq.handlers.add(f), removeEventListener: (_, f) => mq.handlers.delete(f) }
      queries.set(q, mq)
    }
    return queries.get(q)
  }
  const props = new Map()
  const attrs = new Set(["data-nav-timeline"])
  const el = {
    style: {
      marginBottom: "",
      setProperty: (n, v) => props.set(n, String(v)),
      removeProperty: (n) => props.delete(n),
      getPropertyValue: (n) => props.get(n) || ""
    },
    // 88 expanded, 48 collapsed, linear in --nav-p.
    get offsetHeight() { return 88 - 40 * parseFloat(props.get("--nav-p") || "0") },
    getBoundingClientRect() { return { height: this.offsetHeight } },
    hasAttribute: (n) => attrs.has(n),
    setAttribute: (n) => attrs.add(n),
    removeAttribute: (n) => attrs.delete(n),
    querySelector: () => null
  }
  const win = {
    scrollY, innerHeight: 800,
    matchMedia: media,
    addEventListener: (t, f) => listeners[t] && listeners[t].add(f),
    removeEventListener: (t, f) => listeners[t] && listeners[t].delete(f)
  }
  const globals = {
    window: win,
    CSS: { supports: () => true },
    requestAnimationFrame: (f) => { const id = nextId++; frames.set(id, f); return id },
    cancelAnimationFrame: (id) => frames.delete(id),
    getComputedStyle: () => ({ position: "sticky", marginBottom: "0px", getPropertyValue: () => "" }),
    document: { documentElement: { scrollHeight: 5000 }, querySelector: () => null, dispatchEvent: () => {} },
    CustomEvent: class { constructor(type) { this.type = type } },
    ResizeObserver: undefined
  }
  const saved = {}
  for (const k in globals) { saved[k] = globalThis[k]; globalThis[k] = globals[k] }
  return {
    el, props, attrs, frames, listeners,
    flush() {
      for (let i = 0; i < 100 && frames.size; i++) {
        const [id, f] = frames.entries().next().value
        frames.delete(id)
        f()
      }
    },
    // A window resize across 768px: the resize event first, then the query's change.
    resizeTo(isWide) {
      ;[...listeners.resize].forEach((f) => f())
      const mq = media("(min-width: 768px)")
      mq.matches = isWide;
      ;[...mq.handlers].forEach((f) => f())
    },
    restore() { for (const k in saved) globalThis[k] = saved[k] }
  }
}

test("widening while scrolled: the frame the resize queued writes no --nav-p on the timeline header", () => {
  const h = harness({ wide: false, scrollY: 1200 })
  try {
    const nav = new NavCollapse(h.el)
    nav.start()
    h.flush()
    assert.equal(h.props.get("--nav-p"), "1.0000", "narrow and scrolled, the --nav-p path collapses")

    h.resizeTo(true)
    assert.equal(nav.timeline, true)
    assert.ok(h.attrs.has("data-nav-timeline-on"))
    // The swap cancels the frame the old mode queued...
    assert.equal(h.frames.size, 0, "a frame from the --nav-p path is still queued")
    // ...and a frame that runs anyway (one already dispatched) writes nothing.
    nav.apply()
    h.flush()
    assert.equal(h.props.has("--nav-p"), false, `--nav-p left inline: ${h.props.get("--nav-p")}`)
    assert.equal(h.props.has("--nav-hold"), false)
    assert.equal(h.el.style.marginBottom, "")
    nav.stop()
  } finally {
    h.restore()
  }
})

test("narrowing while scrolled: the --nav-p path takes the header back and keeps scheduling frames", () => {
  const h = harness({ wide: true, scrollY: 1200 })
  try {
    const nav = new NavCollapse(h.el)
    nav.start()
    assert.equal(nav.timeline, true)
    assert.equal(h.props.has("--nav-p"), false)

    h.resizeTo(false)
    assert.equal(nav.timeline, false)
    assert.equal(h.attrs.has("data-nav-timeline-on"), false)
    assert.equal(h.props.has("--nav-band"), false, "the timeline's band is cleared")
    h.flush()
    assert.equal(h.props.get("--nav-p"), "1.0000")
    assert.equal(h.props.get("--nav-hold"), "40px")

    // Live: a scroll back to the top is heard and opens the header again.
    globalThis.window.scrollY = 0
    ;[...h.listeners.scroll].forEach((f) => f())
    assert.equal(h.frames.size, 1, "the scroll scheduled a frame")
    h.flush()
    assert.equal(h.props.get("--nav-p"), "0.0000")
    nav.stop()
  } finally {
    h.restore()
  }
})

test("a swap with a frame queued leaves the --nav-p path able to schedule again", () => {
  const h = harness({ wide: false, scrollY: 1200 })
  try {
    const nav = new NavCollapse(h.el)
    nav.start()
    h.flush()
    // Narrow -> wide with a frame queued, then straight back.
    h.resizeTo(true)
    h.resizeTo(false)
    h.flush()
    assert.equal(nav.queued, false)
    globalThis.window.scrollY = 0
    ;[...h.listeners.scroll].forEach((f) => f())
    h.flush()
    assert.equal(h.props.get("--nav-p"), "0.0000")
    nav.stop()
  } finally {
    h.restore()
  }
})
