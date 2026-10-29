// [unit] studio/loader: when the page-load overlay shows and hides, the percent
// a loader takes, and which submitter counts as carrying a pending loader.
// Loaded from source as a data: module, like head_chrome.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/loader.js", import.meta.url), "utf8")
const { overlayDelay, clampPercent, show, hide, showSoon, setPercent, pendingSubmitter, DEFAULT_DELAY_MS } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

function fakeOverlay(delay) {
  const attrs = { "data-delay": delay }
  const caption = { textContent: "" }
  return {
    hidden: true,
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v) },
    removeAttribute: (k) => { delete attrs[k] },
    querySelector: () => caption,
    attrs,
    caption
  }
}
const fakeDoc = (overlay) => ({
  querySelector: () => overlay,
  defaultView: { requestAnimationFrame: (fn) => fn() }
})

test("the overlay delay is read from data-delay, else the default", () => {
  assert.equal(overlayDelay(fakeOverlay("0")), 0)
  assert.equal(overlayDelay(fakeOverlay("800")), 800)
  assert.equal(overlayDelay(fakeOverlay("nope")), DEFAULT_DELAY_MS)
  assert.equal(overlayDelay(null), DEFAULT_DELAY_MS)
})

test("show unhides the overlay, names the caption and fades it in; hide undoes all of it", () => {
  const overlay = fakeOverlay("350")
  const doc = fakeDoc(overlay)
  assert.equal(show("Saving your page", doc), true)
  assert.equal(overlay.hidden, false)
  assert.equal(overlay.caption.textContent, "Saving your page")
  assert.equal(overlay.attrs["data-state"], "shown")
  assert.equal(overlay.attrs["aria-busy"], "true")

  assert.equal(hide(doc), true)
  assert.equal(overlay.hidden, true)
  assert.equal(overlay.attrs["data-state"], undefined)
  assert.equal(overlay.attrs["aria-busy"], undefined)
})

test("without an overlay on the page, show and hide do nothing", () => {
  const doc = fakeDoc(null)
  assert.equal(show("x", doc), false)
  assert.equal(hide(doc), false)
})

test("a load that arrives inside the delay never shows the overlay", async () => {
  const overlay = fakeOverlay("30")
  const doc = fakeDoc(overlay)
  showSoon("", doc)
  hide(doc)
  await new Promise((resolve) => setTimeout(resolve, 60))
  assert.equal(overlay.hidden, true)
})

test("a load that outlasts the delay shows it", async () => {
  const overlay = fakeOverlay("10")
  const doc = fakeDoc(overlay)
  showSoon("", doc)
  await new Promise((resolve) => setTimeout(resolve, 40))
  assert.equal(overlay.hidden, false)
  hide(doc)
})

test("a percent is clamped to 0..100 and junk reads as 0", () => {
  assert.equal(clampPercent(42), 42)
  assert.equal(clampPercent(-5), 0)
  assert.equal(clampPercent(140), 100)
  assert.equal(clampPercent("abc"), 0)
})

test("setPercent marks the loader and sets its percent variable", () => {
  const props = {}
  const attrs = {}
  const loader = {
    classList: { contains: (c) => c === "studio-loader" },
    setAttribute: (k, v) => { attrs[k] = v },
    style: { setProperty: (k, v) => { props[k] = v } }
  }
  setPercent(loader, 250)
  assert.equal(attrs["data-loader-percent"], "")
  assert.equal(props["--studio-loader-percent"], "100")
})

test("only a submitter holding a pending loader counts", () => {
  const withLoader = { querySelector: () => ({}) }
  const without = { querySelector: () => null }
  assert.equal(pendingSubmitter({ submitter: withLoader }), withLoader)
  assert.equal(pendingSubmitter({ submitter: without }), null)
  assert.equal(pendingSubmitter({ detail: { formSubmission: { submitter: withLoader } } }), withLoader)
  assert.equal(pendingSubmitter({}), null)
})
