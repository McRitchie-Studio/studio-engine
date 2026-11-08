// studio/reload_visits: Turbo opens no view transition for a visit it will only reload.
//
// THE DEFECT. Smooth load (layouts/studio/_smooth_load) turns on Turbo's same-document view
// transitions. Turbo starts the transition BEFORE it reads the response's head: its render
// callback is what finds turbo-visit-control reload (turf-monster's /wallet and /account) or a
// changed data-turbo-track="reload" asset, and then navigates by a full load. That navigation
// can skip the transition while its `ready` promise is still pending. Turbo awaits only
// `finished` (turbo-rails 2.0.23, turbo.js ViewTransitioner#renderChange), so `ready` rejects
// with nobody listening: an unhandled "Transition was skipped" error on every such visit that
// loses the race (turf-monster CI run 42447610386).
//
// THE FIX, AT THE CAUSE. Turbo starts a transition only when both the current page and the new
// snapshot carry the view-transition meta (PageView#shouldTransitionTo). So when Turbo's own
// renderer says it will not render a response, this takes that meta out of the HTML Turbo
// parses. Turbo then swaps nothing in a transition and goes straight to its full load, which
// plays the page transition once (docs/PAGE_TRANSITIONS.md, "Full page loads"). Only a page
// Turbo was going to throw away is changed, and the page the full load brings is the server's
// own. No promise is marked handled, so a real failure (a duplicate view-transition-name, a
// render that throws) still surfaces.
//
// THE SEAM. turbo:before-fetch-response, the moment studio/loader also uses: Turbo awaits
// fetchResponse.responseHTML right after it, so a promise put there is what Turbo parses. The
// two compose in either order, since each reads the other's promise. A frame's response is left
// alone: a frame never transitions, and its reload is a new fetch.
//
// It imports nothing; test/javascript/reload_visits.test.mjs loads it as a data: module.

// The meta Turbo reads for a same-document transition: `view-transition` (same-origin), or
// the `turbo-view-transition` setting. Not `view-transition-*` names of anything else.
const TRANSITION_META = /<meta\b[^>]*\bname\s*=\s*["']?(?:turbo-)?view-transition(?![\w-])[^>]*>/gi
const VISIT_CONTROL_RELOAD = /<meta[^>]*(turbo-visit-control[^>]*reload|reload[^>]*turbo-visit-control)/i

// The head alone: Turbo's decision reads only the head, and the body is most of the bytes.
export function headOf(html) {
  const end = html.search(/<\/head\s*>/i)
  return end < 0 ? html : html.slice(0, end)
}

export function prefersTransition(html) {
  TRANSITION_META.lastIndex = 0
  return TRANSITION_META.test(headOf(html))
}

// Whether Turbo would render this HTML as the next page. Asked of Turbo's own PageRenderer, so
// the answer cannot drift from Turbo's (visit control, then the tracked assets). Without
// Turbo's classes, the visit-control meta alone, the case a host sets on purpose.
export function rendersAsPage(html, doc, turbo) {
  const head = headOf(html)
  if (turbo && turbo.PageRenderer && turbo.PageSnapshot) {
    const current = turbo.PageSnapshot.fromElement(doc.documentElement)
    const next = turbo.PageSnapshot.fromHTMLString(head)
    return new turbo.PageRenderer(current, next, false).shouldRender
  }
  return !VISIT_CONTROL_RELOAD.test(head)
}

// The HTML Turbo should parse: unchanged, unless it carries the transition meta and Turbo will
// not render it, and then the same HTML with that meta out of its head.
export function withoutReloadTransition(html, doc, turbo) {
  if (typeof html !== "string" || !prefersTransition(html)) return html
  // A Turbo whose classes changed shape leaves the HTML as it came: the old behaviour, not a
  // failed visit.
  try {
    if (rendersAsPage(html, doc, turbo)) return html
  } catch {
    return html
  }
  const head = headOf(html)
  return head.replace(TRANSITION_META, "") + html.slice(head.length)
}

export function guardResponse(event, doc, turbo) {
  if (event.target && event.target.tagName === "TURBO-FRAME") return false
  const response = event.detail && event.detail.fetchResponse
  if (!response || !response.isHTML) return false
  const html = Promise.resolve(response.responseHTML).then((text) => withoutReloadTransition(text, doc, turbo))
  Object.defineProperty(response, "responseHTML", { configurable: true, value: html })
  return true
}

let installed = false

export function installReloadVisits(doc) {
  if (installed || !doc || !doc.addEventListener) return false
  installed = true
  doc.addEventListener("turbo:before-fetch-response", (event) => {
    const win = doc.defaultView
    guardResponse(event, doc, win && win.Turbo)
  })
  return true
}

if (typeof document !== "undefined") installReloadVisits(document)
