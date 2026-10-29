// [unit] studio/loader: when the page-load overlay shows and hides, the percent
// a loader takes, and which submitter counts as carrying a pending loader.
// Loaded from source as a data: module, like head_chrome.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/loader.js", import.meta.url), "utf8")
const { overlayDelay, maxWait, userVisit, clampPercent, show, hide, showSoon, settle, markBusy, setPercent, pendingSubmitter, DEFAULT_DELAY_MS, MAX_WAIT_MS } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

function fakeOverlay(delay) {
  const attrs = { "data-delay": delay }
  const caption = { textContent: "" }
  return {
    hidden: true,
    getAttribute: (k) => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v) },
    removeAttribute: (k) => { delete attrs[k] },
    querySelector: (selector) => (selector === "[data-studio-loader-caption]" ? caption : null),
    attrs,
    caption
  }
}
const fakeDoc = (overlay, busy = []) => ({
  querySelector: () => overlay,
  querySelectorAll: () => busy,
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
  assert.equal(overlay.attrs["aria-busy"], undefined, "aria-busy would mute the overlay's own Loading status")

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
  settle(doc)
})

test("a load that outlasts the delay shows it", async () => {
  const overlay = fakeOverlay("10")
  const doc = fakeDoc(overlay)
  showSoon("", doc)
  await new Promise((resolve) => setTimeout(resolve, 40))
  assert.equal(overlay.hidden, false)
  settle(doc)
})

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
function fakeButton() {
  const attrs = {}
  return { attrs, setAttribute: (k, v) => { attrs[k] = String(v) }, removeAttribute: (k) => { delete attrs[k] } }
}

test("a wait that never ends in a page (a download) clears at the cap: overlay and busy button", async () => {
  const overlay = fakeOverlay("5")
  overlay.setAttribute("data-max-wait", "40")
  const button = fakeButton()
  const doc = fakeDoc(overlay, [button])
  markBusy(button, doc)
  showSoon("", doc)
  await sleep(20)
  assert.equal(overlay.hidden, false)
  assert.equal(button.attrs["aria-busy"], "true")
  await sleep(60)
  assert.equal(overlay.hidden, true, "the cap hid the overlay")
  assert.equal(button.attrs["aria-busy"], undefined, "the cap cleared the button")
  assert.equal(button.attrs["data-studio-loader-busy"], undefined)
})

test("the cap never hides an overlay a caller showed through the API", async () => {
  const overlay = fakeOverlay("5")
  overlay.setAttribute("data-max-wait", "30")
  const doc = fakeDoc(overlay)
  showSoon("", doc)
  hide(doc)
  show("Building", doc)
  await sleep(60)
  assert.equal(overlay.hidden, false)
  settle(doc)
})

test("only a visit the user started earns the overlay", () => {
  assert.equal(userVisit({ detail: { action: "advance" } }), true)
  assert.equal(userVisit({ detail: { action: "restore" } }), true)
  assert.equal(userVisit({ detail: { action: "replace" } }), false)
  assert.equal(userVisit({ detail: {} }), false)
  assert.equal(userVisit(null), false)
})

test("the cap is read from data-max-wait, else the default", () => {
  assert.equal(maxWait(fakeOverlay("0")), MAX_WAIT_MS)
  const overlay = fakeOverlay("0")
  overlay.setAttribute("data-max-wait", "2500")
  assert.equal(maxWait(overlay), 2500)
  assert.equal(maxWait(null), MAX_WAIT_MS)
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

test("two shows inside the announce gap keep the Loading label", async () => {
  const overlay = fakeOverlay("0")
  const attrs = {}
  const label = { textContent: "Loading", getAttribute: (k) => (k in attrs ? attrs[k] : null), setAttribute: (k, v) => { attrs[k] = String(v) } }
  const base = overlay.querySelector
  overlay.querySelector = (selector) => (selector === '[role="status"] .sr-only' ? label : base(selector))
  const doc = fakeDoc(overlay)
  show("Uploading", doc)
  show("Processing", doc)
  await new Promise((resolve) => setTimeout(resolve, 80))
  assert.equal(label.textContent, "Loading", "the second show restored the emptied text")
  settle(doc)
})
