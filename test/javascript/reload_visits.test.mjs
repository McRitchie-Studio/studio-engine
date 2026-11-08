// [unit] studio/reload_visits: Turbo opens no view transition for a response it will only
// reload (turf-monster run 42447610386, a "Transition was skipped" pageerror). Loaded from
// source as a data: module, like loader.test.mjs. Outside a browser it installs nothing.
//
// The browser half, with Turbo's real classes and a real skipped transition, is
// e2e/page_transitions_full_load.spec.js ("... opens no view transition, so none is skipped").
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/reload_visits.js", import.meta.url), "utf8")
const boot = readFileSync(new URL("../../app/javascript/studio/application.js", import.meta.url), "utf8")
const { headOf, prefersTransition, rendersAsPage, withoutReloadTransition, guardResponse, installReloadVisits } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const TRANSITION = '<meta name="view-transition" content="same-origin">'
const RELOAD = '<meta name="turbo-visit-control" content="reload">'
const page = (head, body = "<main>Wallet</main>") =>
  `<!DOCTYPE html><html><head><title>t</title>${head}</head><body>${body}</body></html>`

// Turbo's two classes, as far as the guard reads them: the renderer's answer is set per test.
function fakeTurbo(shouldRender, seen = []) {
  return {
    PageSnapshot: {
      fromElement: (element) => ({ from: "page", element }),
      fromHTMLString: (html) => { seen.push(html); return { from: "html", html } },
    },
    PageRenderer: class {
      constructor(current, next, isPreview) { Object.assign(this, { current, next, isPreview }) }
      get shouldRender() { return shouldRender }
    },
  }
}
const doc = { documentElement: { tagName: "HTML" } }

test("the boot imports it, so every page's visits are guarded", () => {
  assert.match(boot, /^import "studio\/reload_visits"$/m)
})

test("the module imports nothing, and outside a browser it binds nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
  assert.equal(installReloadVisits(undefined), false)
})

test("a page that answers with turbo-visit-control reload loses the transition meta, and nothing else", () => {
  const html = page(`${TRANSITION}${RELOAD}<meta name="signing-csp" content="strict">`)
  const out = withoutReloadTransition(html, doc, null)
  assert.equal(out, page(`${RELOAD}<meta name="signing-csp" content="strict">`))
  assert.equal(prefersTransition(out), false)
})

test("a page Turbo will render keeps its transition, byte for byte", () => {
  const html = page(TRANSITION)
  assert.equal(withoutReloadTransition(html, doc, null), html)
  assert.equal(withoutReloadTransition(html, doc, fakeTurbo(true)), html)
})

test("Turbo's own renderer decides, so a changed tracked asset counts as a reload too", () => {
  const seen = []
  const html = page(`${TRANSITION}<link rel="stylesheet" href="/a-new.css" data-turbo-track="reload">`)
  const out = withoutReloadTransition(html, doc, fakeTurbo(false, seen))
  assert.equal(prefersTransition(out), false)
  assert.match(out, /a-new\.css/)
  assert.deepEqual(seen, [headOf(html)], "Turbo parsed the head alone")
})

test("Turbo's renderer overrides the meta check both ways", () => {
  assert.equal(rendersAsPage(page(RELOAD), doc, fakeTurbo(true)), true)
  assert.equal(rendersAsPage(page(""), doc, fakeTurbo(false)), false)
  assert.equal(rendersAsPage(page(RELOAD), doc, null), false)
  assert.equal(rendersAsPage(page('<meta content="reload" name="turbo-visit-control">'), doc, null), false)
  assert.equal(rendersAsPage(page(""), doc, null), true)
})

test("a page with no transition meta is never parsed", () => {
  const html = page(RELOAD)
  const turbo = { PageSnapshot: { fromHTMLString() { throw new Error("parsed") } }, PageRenderer: class {} }
  assert.equal(withoutReloadTransition(html, doc, turbo), html)
})

test("a Turbo that throws leaves the HTML as it came", () => {
  const html = page(`${TRANSITION}${RELOAD}`)
  const turbo = { PageSnapshot: { fromElement() { throw new Error("changed shape") } }, PageRenderer: class {} }
  assert.equal(withoutReloadTransition(html, doc, turbo), html)
})

test("the turbo-view-transition setting goes too, and no other name that starts the same way", () => {
  const html = page(`<meta name="turbo-view-transition" content="true"><meta name="view-transition-direction" content="left">${RELOAD}`)
  assert.equal(withoutReloadTransition(html, doc, null), page(`<meta name="view-transition-direction" content="left">${RELOAD}`))
})

test("only the head changes: a body that quotes the meta keeps it", () => {
  const body = `<pre>${TRANSITION}</pre>`
  const html = page(`${TRANSITION}${RELOAD}`, body)
  assert.equal(withoutReloadTransition(html, doc, null), page(RELOAD, body))
})

test("a body-only response, and a non-string, pass through", () => {
  assert.equal(withoutReloadTransition("<p>hi</p>", doc, null), "<p>hi</p>")
  assert.equal(withoutReloadTransition(undefined, doc, null), undefined)
})

function fetchEvent({ target = { tagName: "HTML" }, html, isHTML = true }) {
  const response = { isHTML }
  let reads = 0
  Object.defineProperty(response, "responseHTML", { configurable: true, get: () => { reads += 1; return html } })
  return { event: { target, detail: { fetchResponse: response } }, response, reads: () => reads }
}

test("Turbo reads the guarded HTML from fetchResponse.responseHTML", async () => {
  const { event, response } = fetchEvent({ html: Promise.resolve(page(`${TRANSITION}${RELOAD}`)) })
  assert.equal(guardResponse(event, doc, null), true)
  assert.equal(await response.responseHTML, page(RELOAD))
  assert.equal(await response.responseHTML, page(RELOAD), "one promise, read as often as Turbo likes")
})

test("a wrapper set after it (studio/loader's hold) reads the guarded HTML", async () => {
  const { event, response } = fetchEvent({ html: Promise.resolve(page(`${TRANSITION}${RELOAD}`)) })
  guardResponse(event, doc, null)
  const held = Promise.resolve(response.responseHTML).then((html) => html)
  Object.defineProperty(response, "responseHTML", { configurable: true, value: held })
  assert.equal(await response.responseHTML, page(RELOAD))
})

test("a wrapper set before it (studio/loader's hold) is what it reads", async () => {
  const { event, response } = fetchEvent({ html: Promise.resolve("never read") })
  Object.defineProperty(response, "responseHTML", { configurable: true, value: Promise.resolve(page(`${TRANSITION}${RELOAD}`)) })
  guardResponse(event, doc, null)
  assert.equal(await response.responseHTML, page(RELOAD))
})

test("a body that fails still fails for Turbo", async () => {
  const failure = new Error("network")
  const { event, response } = fetchEvent({ html: Promise.reject(failure) })
  guardResponse(event, doc, null)
  await assert.rejects(response.responseHTML, failure)
})

test("a frame's response and a non-HTML response are left alone", () => {
  const frame = fetchEvent({ target: { tagName: "TURBO-FRAME" }, html: Promise.resolve("x") })
  assert.equal(guardResponse(frame.event, doc, null), false)
  assert.equal(frame.reads(), 0)
  const json = fetchEvent({ html: Promise.resolve(undefined), isHTML: false })
  assert.equal(guardResponse(json.event, doc, null), false)
  assert.equal(json.reads(), 0)
})
