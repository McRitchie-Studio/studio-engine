// studio/page_transitions: the app-to-app page transition (Studio.page_transition_direction and
// Studio.page_transition_style, docs/PAGE_TRANSITIONS.md). Loaded by its own tag in layouts/studio/_head, only with the
// setting on. It names a style on <html>, and engine.css draws it. It imports nothing.
//
// Turbo calls document.startViewTransition BEFORE turbo:before-render, and the browser takes
// the old page's picture before Turbo's callback runs. So what the old picture holds is
// settled ahead of the visit: the held banner stack and the morph names are decided here on
// turbo:visit and from the response, never first at before-render.
//
// A full load is the other path to the same look. The new document draws the motion, so the old
// one only plans it: at pageswap it names what it holds, reads the style here, and leaves it for
// studio/page_transition_reveal, the classic script that applies it at pagereveal.
//
// The effects are from the Codrops Page Transitions demo; the keyframes were written fresh.

// The move each pair of settings plays: the first key is Studio.page_transition_style, the second
// is Studio.page_transition_direction. An unfold is named for the way the new page turns, which
// is the opposite of the way the page leaves.
export const STYLES = Object.freeze({
  slide: Object.freeze({ left: "slide-left", right: "slide-right", top: "slide-top", bottom: "slide-bottom" }),
  unfold: Object.freeze({ left: "unfold-right", right: "unfold-left", top: "unfold-bottom", bottom: "unfold-top" }),
})
// Mirrors the default in lib/studio.rb, for a page with no style meta.
export const DEFAULT_STYLE = "slide"

// A same-page visit (a refresh, a poll, the second half of a redirect): the transition still
// runs, and draws nothing.
export const STILL = "still"
export const READY_CAP_MS = 500
// Read by app/assets/javascripts/studio/page_transition_reveal.js too.
export const FULL_LOAD_STYLE_KEY = "studio-page-transition-style"
const MAX_READY_IMAGES = 12
const REDUCED_MOTION = "(prefers-reduced-motion: reduce)"

export function styleFor(direction, style) {
  const moves = STYLES[Object.hasOwn(STYLES, style) ? style : DEFAULT_STYLE]
  return Object.hasOwn(moves, direction) ? moves[direction] : null
}

// The style for one visit, STILL, or null to leave the swap alone (the engine's fade plays,
// and a morph between two pages stands). An advance visit to the same path can bring a new
// page, as a launch panel does when it gives way to the chat at its own address, so a name
// the two share still morphs. A refresh replaces, and stays silent.
export function planVisit({ direction, style, from, to, transitions, sharedName, advance }) {
  const move = styleFor(direction, style)
  if (!transitions || !from || !to || !move) return null
  if (from === to) return advance && sharedName ? null : STILL
  return sharedName ? null : move
}

// The style a full load should play, or null for a plain load: planVisit's own rule, so the
// two paths cannot differ. No morph, since the old page cannot read the new page's names
// before its picture, and a browser with no activation entry has nothing to compare.
export function planFullLoad({ direction, style, from, activation }) {
  const url = activation && activation.entry && activation.entry.url
  if (!url) return null
  const to = new URL(url).pathname
  const move = planVisit({ direction, style, from, to, transitions: true, sharedName: false })
  return move === STILL ? null : move
}

// Hands the style to the next document. Storage can refuse, and then the load is plain.
export function leaveStyle(win, style) {
  try {
    if (style) win.sessionStorage.setItem(FULL_LOAD_STYLE_KEY, style)
    else win.sessionStorage.removeItem(FULL_LOAD_STYLE_KEY)
    return !!style
  } catch {
    return false
  }
}

// A slow image must not hold a click: past the cap the swap goes ahead.
export function withCap(promise, ms, timer = setTimeout) {
  return Promise.race([promise, new Promise((done) => timer(done, ms))])
}

export function morphNames(root) {
  return new Set([...root.querySelectorAll("[data-vt-morph]")].map((el) => el.getAttribute("data-vt-morph")))
}

export function shareName(here, there) {
  return !!there && [...here].some((name) => there.has(name))
}

// Exactly one element takes the stack's view-transition name, however many a page renders:
// a duplicate name silently cancels the whole transition.
export function markHeld(root) {
  const stack = root.querySelector(".studio-bar-stack")
  if (stack) stack.setAttribute("data-vt-held", "")
}

export function eagerImages(body) {
  return [...body.querySelectorAll("img")]
    .filter((img) => img.getAttribute("loading") !== "lazy" && (img.getAttribute("src") || img.getAttribute("srcset")))
    .slice(0, MAX_READY_IMAGES)
}

// The incoming body is inert, so each image is copied here to load, <picture> and all, so
// the browser chooses the same source. Marked decoding=sync, the real one paints at once.
function loadImage(doc, img) {
  img.decoding = "sync"
  const source = img.closest("picture") || img
  const copy = doc.importNode(source, true)
  const loader = copy.tagName === "IMG" ? copy : copy.querySelector("img")
  return loader.decode().catch(() => {})
}

function readyForSwap(doc, body) {
  const fonts = doc.fonts ? doc.fonts.ready.catch(() => {}) : null
  // At least one tick, so Turf's one-tick hold for its snapshot stays honest.
  const tick = new Promise((done) => setTimeout(done, 0))
  return Promise.all([...eagerImages(body).map((img) => loadImage(doc, img)), fonts, tick])
}

// Turbo's resume is a promise's resolve, so the FIRST caller starts the render. Another
// listener's short hold (Turf's turbo_snapshot_cache resumes on a timeout of 0) would cut
// this wait to nothing, so a listener that runs after this one gets a resume that does
// nothing, and this wait releases the render. It always does: cap, failure or success.
export function holdRender(event, wait, cap = READY_CAP_MS) {
  const resume = event.detail && event.detail.resume
  if (typeof resume !== "function") return false
  event.preventDefault()
  event.detail.resume = () => {}
  const release = () => resume()
  withCap(Promise.resolve().then(wait), cap).then(release, release)
  return true
}

function readDirection(doc) {
  const meta = doc.querySelector('meta[name="page-transition-direction"]')
  return meta ? meta.content : null
}

function readStyle(doc) {
  const meta = doc.querySelector('meta[name="page-transition-style"]')
  return meta ? meta.content : null
}

let installed = false

export function installPageTransitions(doc) {
  if (installed || !readDirection(doc)) return false
  installed = true

  const win = doc.defaultView
  const root = doc.documentElement
  const known = new Map()
  let from = win.location.pathname
  let target = null
  let advance = false
  let rendered = false

  const nameTheMorph = (shared) => {
    if (shared) root.dataset.pageTransitionMorph = ""
    else delete root.dataset.pageTransitionMorph
  }
  const predict = (names) => nameTheMorph((target !== from || advance) && shareName(morphNames(doc), names))

  root.dataset.pageTransitionDirection = readDirection(doc)
  markHeld(doc)
  known.set(from, morphNames(doc))

  doc.addEventListener("turbo:visit", (event) => {
    root.dataset.pageTransitionVisit = ""
    // Turbo opens its view transition before it reads turbo-visit-control. A response it will
    // not render gets no turbo:before-render, so this stands, and that transition draws nothing.
    // The full load after it plays the one motion. Left alone while a motion is still running.
    if (!root.dataset.pageTransition) root.dataset.pageTransition = STILL
    target = new URL(event.detail.url).pathname
    // A GET that redirects: Turbo renders the response, then replaces to the final address
    // with that same response, all before turbo:load. The page has landed, so nothing moves.
    const action = event.detail.action
    if (rendered && action === "replace") from = target
    rendered = false
    advance = action === "advance"
    predict(known.get(target))
  })

  // A page never visited: read its names from the response, ahead of the old page's picture.
  // Only a page with names of its own can share one, so every other page skips the parse.
  doc.addEventListener("turbo:before-fetch-response", (event) => {
    if (event.target && event.target.tagName === "TURBO-FRAME") return
    if (!morphNames(doc).size) return
    const { fetchResponse } = event.detail
    Promise.resolve(fetchResponse.responseHTML).then((html) => {
      if (!html) return
      const names = morphNames(new win.DOMParser().parseFromString(html, "text/html"))
      const path = new URL(fetchResponse.response.url).pathname
      known.set(path, names)
      if (target && (path === target || fetchResponse.redirected)) predict(names)
    }).catch(() => {})
  })

  // In capture, so the hold is in place before any other listener takes Turbo's resume.
  doc.addEventListener("turbo:before-render", (event) => {
    const { newBody } = event.detail
    markHeld(newBody)
    const names = morphNames(newBody)
    if (target) known.set(target, names)
    const sharedName = shareName(morphNames(doc), names)
    const style = planVisit({
      direction: readDirection(doc),
      style: readStyle(doc),
      from,
      to: target,
      transitions: !!doc.startViewTransition && !win.matchMedia(REDUCED_MOTION).matches,
      sharedName,
      advance,
    })
    nameTheMorph(sharedName && style !== STILL)
    if (style) root.dataset.pageTransition = style
    else delete root.dataset.pageTransition
    if (style && style !== STILL) holdRender(event, () => readyForSwap(doc, newBody))
  }, { capture: true })

  // A refused form renders with no visit and fires no turbo:load, so only a render inside a
  // visit counts. Otherwise the flag would outlive that render and eat the next page's move.
  doc.addEventListener("turbo:render", () => { rendered = !!target })

  // Turbo fires this after the transition has finished. With no visit, it is this document's
  // own first load, and a full load's motion can still be playing: its script cleans up.
  doc.addEventListener("turbo:load", () => {
    const visited = target !== null
    from = win.location.pathname
    target = null
    advance = false
    rendered = false
    known.set(from, morphNames(doc))
    if (!visited) return
    delete root.dataset.pageTransition
    delete root.dataset.pageTransitionVisit
    nameTheMorph(false)
  })

  // A visit that never renders: the stack must not keep its name at rest.
  for (const name of ["turbo:fetch-request-error", "turbo:reload"]) {
    doc.addEventListener(name, () => {
      delete root.dataset.pageTransitionVisit
      if (name !== "turbo:reload") delete root.dataset.pageTransition
    })
  }

  // The last moment on the old document. The browser takes its picture after this.
  win.addEventListener("pageswap", (event) => {
    const transition = event.viewTransition
    const style = transition && planFullLoad({ direction: readDirection(doc), style: readStyle(doc), from, activation: event.activation })
    const left = leaveStyle(win, style)
    if (!transition) return
    if (!left) {
      transition.skipTransition()
      return
    }
    markHeld(doc)
    root.dataset.pageTransitionVisit = ""
    nameTheMorph(false)
    // The loader settles at pagehide, which comes after the picture.
    if (win.StudioLoader) win.StudioLoader.hide()
  })

  // Back from the back/forward cache: a visit that left by a full load is over.
  win.addEventListener("pageshow", (event) => {
    if (!event.persisted) return
    from = win.location.pathname
    target = null
    advance = false
    rendered = false
  })
  return true
}

if (typeof document !== "undefined") installPageTransitions(document)
