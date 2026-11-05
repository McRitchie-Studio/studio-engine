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

test("a Turbo visit is never capped: a slow page keeps its overlay", async () => {
  const overlay = fakeOverlay("5"); overlay.setAttribute("data-max-wait", "30")
  showSoon("", fakeDoc(overlay))
  await sleep(70)
  assert.equal(overlay.hidden, false, "the cap hid a page that was still loading")
  settle(fakeDoc(overlay))
})

// ---- the pace: 350ms to show, 750ms once shown ------------------------------

const pace = await import(`data:text/javascript,${encodeURIComponent(`${source}\n// the pace`)}`)

function paceDoc(overlay) {
  const root = {}
  return {
    documentElement: root,
    querySelector: () => overlay,
    querySelectorAll: () => [],
    defaultView: { requestAnimationFrame: (fn) => fn(), setTimeout: (fn) => fn() }
  }
}
const htmlResponse = (html = "<html></html>", more = {}) => ({ succeeded: true, isHTML: true, responseHTML: Promise.resolve(html), ...more })
const responseEvent = (doc, fetchResponse, target = doc.documentElement) => ({ target, detail: { fetchResponse } })
const flush = async () => { for (let i = 0; i < 8; i += 1) await Promise.resolve() }

// A visit under a fake clock. It returns the moment the response's HTML reached Turbo,
// or null with the wait not finished, and when the overlay went.
async function visitAt(t, responseAt, { delay = "350", minShow = "750", html } = {}) {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 })
  const overlay = fakeOverlay(delay)
  overlay.setAttribute("data-min-show", minShow)
  const doc = paceDoc(overlay)
  pace.showSoon("", doc)
  t.mock.timers.tick(responseAt)
  const response = htmlResponse(html)
  const held = pace.holdVisitResponse(responseEvent(doc, response), doc)
  let turboGotIt = null
  Promise.resolve(response.responseHTML).then(() => { turboGotIt = Date.now() })
  await flush()
  return { overlay, doc, response, held, shownAtResponse: !overlay.hidden, turboAt: () => turboGotIt, tick: async (ms) => { t.mock.timers.tick(ms); await flush() } }
}

for (const [responseAt, expectedRelease] of [[360, 1100], [400, 1100]]) {
  test(`shown at 350, a response at ${responseAt} reaches Turbo at ${expectedRelease}, with the overlay gone`, async (t) => {
    const visit = await visitAt(t, responseAt)
    assert.equal(visit.held, true)
    assert.equal(visit.overlay.hidden, false)
    assert.equal(visit.turboAt(), null)
    await visit.tick(expectedRelease - responseAt - 1)
    assert.equal(visit.turboAt(), null, "released early")
    assert.equal(visit.overlay.hidden, false, "hidden early")
    await visit.tick(1)
    assert.equal(visit.turboAt(), expectedRelease)
    assert.equal(visit.overlay.hidden, true, "the old picture must not hold the overlay")
    pace.hide(visit.doc)
  })
}

test("shown at 350, a response at 1200 is past the minimum and waits for nothing", async (t) => {
  const visit = await visitAt(t, 1200)
  assert.equal(visit.held, false)
  assert.equal(visit.turboAt(), 1200)
  pace.hide(visit.doc)
})

test("a response before the delay never shows the overlay and is not delayed", async (t) => {
  const visit = await visitAt(t, 200)
  assert.equal(visit.held, false)
  assert.equal(visit.turboAt(), 200)
  await visit.tick(5000)
  assert.equal(visit.overlay.hidden, true, "the overlay showed after its response had come")
})

test("min_show of zero waits for nothing", async (t) => {
  const visit = await visitAt(t, 360, { minShow: "0" })
  assert.equal(visit.held, false)
  pace.hide(visit.doc)
})

test("a frame, a form and a prefetch have their own target, and never wait", async (t) => {
  const visit = await visitAt(t, 1200)
  const again = fakeOverlay("350")
  const doc = paceDoc(again)
  t.mock.timers.setTime(0)
  pace.showSoon("", doc)
  t.mock.timers.tick(360)
  assert.equal(pace.holdVisitResponse(responseEvent(doc, htmlResponse(), { tagName: "TURBO-FRAME" }), doc), false)
  assert.equal(pace.holdVisitResponse(responseEvent(doc, htmlResponse(), { tagName: "FORM" }), doc), false)
  pace.hide(doc)
  pace.hide(visit.doc)
})

test("a failure and a download pass straight through", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 })
  const overlay = fakeOverlay("350")
  const doc = paceDoc(overlay)
  pace.showSoon("", doc)
  t.mock.timers.tick(360)
  assert.equal(pace.holdVisitResponse(responseEvent(doc, htmlResponse("x", { succeeded: false })), doc), false)
  assert.equal(pace.holdVisitResponse(responseEvent(doc, htmlResponse("x", { isHTML: false })), doc), false)
  pace.hide(doc)
})

test("a page that answers with a full load does not wait: its second load is the one that paints", async (t) => {
  for (const html of ['<meta name="turbo-visit-control" content="reload">', '<META content="reload" name="turbo-visit-control">']) {
    const visit = await visitAt(t, 360, { html })
    assert.equal(visit.turboAt(), 360, html)
    pace.hide(visit.doc)
    t.mock.timers.reset()
  }
  assert.equal(pace.answersWithFullLoad('<meta name="turbo-visit-control" content="advance">'), false)
  assert.equal(pace.answersWithFullLoad(undefined), false)
})

test("StudioLoader.hide ends a wait at once", async (t) => {
  const visit = await visitAt(t, 360)
  assert.equal(visit.turboAt(), null)
  pace.hide(visit.doc)
  await flush()
  assert.equal(visit.turboAt(), 360)
  assert.equal(visit.overlay.hidden, true)
})

test("a caller's show has no minimum", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 })
  const overlay = fakeOverlay("350")
  const doc = paceDoc(overlay)
  pace.show("Signing", doc)
  assert.equal(pace.minShowLeft(overlay, 10), 0)
  assert.equal(pace.holdVisitResponse(responseEvent(doc, htmlResponse()), doc), false)
  pace.hide(doc)
})

test("a form's overlay stays up for the rest of its minimum, and hide still cuts that short", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 0 })
  const overlay = fakeOverlay("350")
  const doc = paceDoc(overlay)
  pace.showSoon("Saving", doc)
  t.mock.timers.tick(400)
  pace.hideAfterMinimum(doc)
  t.mock.timers.tick(699)
  assert.equal(overlay.hidden, false)
  t.mock.timers.tick(1)
  assert.equal(overlay.hidden, true)

  pace.showSoon("Saving", doc)
  t.mock.timers.tick(400)
  pace.hideAfterMinimum(doc)
  pace.hide(doc)
  assert.equal(overlay.hidden, true)
})

test("with no overlay in the body, it comes once from the head's template; a host's own wins", () => {
  const added = []
  const made = fakeOverlay("350")
  const doc = {
    body: { appendChild: (node) => { added.push(node) } },
    importNode: (content) => content,
    querySelector: (selector) => {
      if (selector === "[data-studio-loader-overlay]") return added.length ? made : null
      if (selector.startsWith("template[")) return { content: "the overlay" }
      return null
    },
    defaultView: { requestAnimationFrame: (fn) => fn(), setTimeout: (fn) => fn() }
  }
  pace.showSoon("", doc)
  pace.showSoon("", doc)
  assert.deepEqual(added, ["the overlay"])
  pace.hide(doc)

  const own = fakeOverlay("350")
  let imported = 0
  const hostDoc = { body: {}, importNode: () => { imported += 1 }, querySelector: () => own, defaultView: doc.defaultView }
  pace.showSoon("", hostDoc)
  assert.equal(imported, 0)
  pace.hide(hostDoc)
})
