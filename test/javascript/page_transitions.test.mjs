// [unit] studio/page_transitions: the pure half. One direction per app; each page change
// draws one of its two styles; a same-page visit plays nothing. Loaded from source as a
// data: module, like nav_collapse.test.mjs. Outside a browser it installs nothing.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/page_transitions.js", import.meta.url), "utf8")
const { DIRECTIONS, STILL, READY_CAP_MS, pickStyle, planVisit, withCap, shareName, holdRender, installPageTransitions } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const visit = { direction: "left", from: "/", to: "/chat", transitions: true, sharedName: false }

test("the module imports nothing, so a head tag can load it alone", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("without the setting's meta it binds nothing", () => {
  const doc = { querySelector: () => null, addEventListener() { throw new Error("bound a listener") } }
  assert.equal(installPageTransitions(doc), false)
})

test("each direction pairs a fade with the unfold moving the same way", () => {
  assert.deepEqual(DIRECTIONS.left, ["fade-left", "unfold-right"])
  assert.deepEqual(DIRECTIONS.right, ["fade-right", "unfold-left"])
  assert.deepEqual(DIRECTIONS.top, ["fade-top", "unfold-bottom"])
  assert.deepEqual(DIRECTIONS.bottom, ["fade-bottom", "unfold-top"])
})

test("a page change can draw either style of the pair, and only those", () => {
  assert.equal(pickStyle("top", () => 0), "fade-top")
  assert.equal(pickStyle("top", () => 0.49), "fade-top")
  assert.equal(pickStyle("top", () => 0.5), "unfold-bottom")
  assert.equal(pickStyle("top", () => 0.999), "unfold-bottom")
})

test("an unknown direction picks nothing, an inherited Object key included", () => {
  assert.equal(pickStyle("diagonal"), null)
  assert.equal(pickStyle("constructor"), null)
  assert.equal(planVisit({ ...visit, direction: "constructor" }), null)
})

test("a plan is the app's own direction on any route, with nothing remembered", () => {
  for (const [from, to] of [["/", "/chat"], ["/chat", "/"], ["/a", "/b"]]) {
    assert.equal(planVisit({ ...visit, from, to }, () => 0), "fade-left")
  }
})

test("a same-page visit is still", () => {
  assert.equal(planVisit({ ...visit, to: "/" }), STILL)
  assert.equal(planVisit({ ...visit, to: "/", sharedName: true }), STILL)
})

test("two pages sharing a name play no style, so their morph stands", () => {
  assert.equal(planVisit({ ...visit, sharedName: true }), null)
})

test("no view transition, no setting or no known target leaves the swap alone", () => {
  assert.equal(planVisit({ ...visit, transitions: false }), null)
  assert.equal(planVisit({ ...visit, direction: null }), null)
  assert.equal(planVisit({ ...visit, to: null }), null)
})

test("shareName needs one name on both sides", () => {
  assert.equal(shareName(new Set(["a", "b"]), new Set(["b"])), true)
  assert.equal(shareName(new Set(["a"]), new Set(["b"])), false)
  assert.equal(shareName(new Set(["a"]), undefined), false)
  assert.equal(shareName(new Set(), new Set()), false)
})

test("a slow wait cannot pass the cap, and a fast one ends it", async () => {
  let cap = null
  await withCap(new Promise(() => {}), READY_CAP_MS, (done, ms) => { cap = ms; done() })
  assert.equal(cap, 500)
  assert.equal(await withCap(Promise.resolve("ready"), 500, () => {}), "ready")
})

const fakeEvent = (resume) => ({ detail: { resume }, prevented: false, preventDefault() { this.prevented = true } })

test("the render resumes once the wait ends", async () => {
  let resumed = 0
  const event = fakeEvent(() => { resumed += 1 })
  assert.equal(holdRender(event, () => Promise.resolve()), true)
  assert.equal(event.prevented, true)
  assert.equal(resumed, 0)
  await new Promise((done) => setTimeout(done, 5))
  assert.equal(resumed, 1)
})

test("a failing wait, thrown or rejected, still resumes", async () => {
  let resumed = 0
  holdRender(fakeEvent(() => { resumed += 1 }), () => { throw new Error("importNode") })
  holdRender(fakeEvent(() => { resumed += 1 }), () => Promise.reject(new Error("decode")))
  await new Promise((done) => setTimeout(done, 5))
  assert.equal(resumed, 2)
})

test("a hung wait still resumes at the cap", async () => {
  let resumed = 0
  holdRender(fakeEvent(() => { resumed += 1 }), () => new Promise(() => {}), 10)
  await new Promise((done) => setTimeout(done, 30))
  assert.equal(resumed, 1)
})

test("another listener's resume cannot end the wait", async () => {
  let resumed = 0
  let finish
  const event = fakeEvent(() => { resumed += 1 })
  holdRender(event, () => new Promise((done) => { finish = done }))
  event.detail.resume()
  await new Promise((done) => setTimeout(done, 5))
  assert.equal(resumed, 0)
  finish()
  await new Promise((done) => setTimeout(done, 5))
  assert.equal(resumed, 1)
})

test("with no resume to call, the render is not paused", () => {
  const event = { detail: {}, preventDefault() { throw new Error("paused a render it cannot restart") } }
  assert.equal(holdRender(event, () => {}), false)
})
