// [unit] studio/email_banner_scale: the scale that fits the fixed 600px banner
// into a fluid frame. Loaded from source as a data: module, like
// nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/email_banner_scale.js", import.meta.url), "utf8")
const { PREVIEWS, FRAMES, bannerScale, fitBanner, startBannerScale } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("a narrow frame scales the banner down in proportion", () => {
  assert.equal(bannerScale(600, 300), 0.5)
  assert.equal(bannerScale(600, 467), 467 / 600)
})

test("the banner is never scaled above its real size", () => {
  assert.equal(bannerScale(600, 600), 1)
  assert.equal(bannerScale(600, 2200), 1)
})

test("a frame with no width is left alone, and a missing natural width reads as 600", () => {
  assert.equal(bannerScale(600, 0), null)
  assert.equal(bannerScale(NaN, 300), 0.5)
})

const preview = (available, width = "600") => ({
  dataset: { bannerWidth: width },
  style: {},
  parentElement: available === null ? null : { clientWidth: available }
})

test("fit writes the transform on the preview from its parent's width", () => {
  const fitted = preview(300)
  assert.equal(fitBanner(fitted), 0.5)
  assert.equal(fitted.style.transform, "scale(0.5)")

  const wide = preview(300, "1200")
  fitBanner(wide)
  assert.equal(wide.style.transform, "scale(0.25)", "the preview's own data-banner-width is the natural width")
})

test("fit leaves a preview with no frame, or a frame with no width, untouched", () => {
  const orphan = preview(null)
  const hidden = preview(0)
  assert.equal(fitBanner(orphan), null)
  assert.equal(fitBanner(hidden), null)
  assert.deepEqual([orphan.style, hidden.style], [{}, {}])
})

function fakeDocument(previews, frames) {
  return { querySelectorAll: (selector) => (selector === PREVIEWS ? previews : selector === FRAMES ? frames : []) }
}

test("start fits every preview, watches every frame, refits on a resize, and stops", () => {
  const previews = [preview(300), preview(450)]
  const frames = [{ id: 1 }, { id: 2 }]
  const observers = []
  class Observer {
    constructor(callback) { this.callback = callback; this.observed = []; this.live = true; observers.push(this) }
    observe(frame) { this.observed.push(frame) }
    disconnect() { this.live = false }
  }

  const stop = startBannerScale(fakeDocument(previews, frames), Observer)

  assert.deepEqual(previews.map((p) => p.style.transform), ["scale(0.5)", "scale(0.75)"])
  assert.deepEqual(observers[0].observed, frames)

  previews[0].parentElement.clientWidth = 150
  observers[0].callback()
  assert.equal(previews[0].style.transform, "scale(0.25)")

  stop()
  assert.equal(observers[0].live, false)
})

test("start still fits once in a browser with no ResizeObserver", () => {
  const previews = [preview(300)]
  const stop = startBannerScale(fakeDocument(previews, []), undefined)

  assert.equal(previews[0].style.transform, "scale(0.5)")
  assert.doesNotThrow(stop)
})
