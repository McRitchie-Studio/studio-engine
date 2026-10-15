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
// never shortens: the progress IS the scroll position, every frame.

test("held, a flick lands on the scroll position in one frame, with nothing to settle", () => {
  const frame = collapseFrame({ ...page, held: true, y: 90, p: 0 })
  assert.equal(frame.p, smoothstep(90 / 120))
  assert.equal(frame.settling, false)
})

test("held, the way back up lands exactly too, so no gap opens above the content", () => {
  const frame = collapseFrame({ ...page, held: true, y: 0, p: 1 })
  assert.deepEqual(frame, { p: 0, settling: false })
})

test("held, a short page collapses with its scroll instead of snapping open", () => {
  const short = { ...page, held: true, scrollHeight: 900, innerHeight: 844 }
  const frame = collapseFrame({ ...short, y: 56, p: 0 })
  assert.equal(frame.p, smoothstep(56 / 120))
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
