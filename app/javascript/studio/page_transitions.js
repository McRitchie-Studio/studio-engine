// studio/page_transitions: the app-to-app page transition (Studio.page_transition_direction,
// docs/PAGE_TRANSITIONS.md). Loaded by its own tag in layouts/studio/_head, only with the
// setting on. It names a style on <html>, and engine.css draws it. It imports nothing.
//
// Turbo calls document.startViewTransition BEFORE turbo:before-render, and the browser takes
// the old page's picture before Turbo's callback runs. So what the old picture holds is
// settled ahead of the visit: the held banner stack and the morph names are decided here on
// turbo:visit and from the response, never first at before-render.
//
// The effects are from the Codrops Page Transitions demo; the keyframes were written fresh.

export const DIRECTIONS = Object.freeze({
  left: Object.freeze(["fade-left", "unfold-right"]),
  right: Object.freeze(["fade-right", "unfold-left"]),
  top: Object.freeze(["fade-top", "unfold-bottom"]),
  bottom: Object.freeze(["fade-bottom", "unfold-top"]),
})

// A same-page visit (a refresh, a poll): the transition still runs, and draws nothing.
export const STILL = "still"
export const READY_CAP_MS = 500
const MAX_READY_IMAGES = 12
const REDUCED_MOTION = "(prefers-reduced-motion: reduce)"

export function pickStyle(direction, random = Math.random) {
  if (!Object.hasOwn(DIRECTIONS, direction)) return null
  const pair = DIRECTIONS[direction]
  return pair[Math.floor(random() * pair.length)]
}

// The style for one visit, STILL, or null to leave the swap alone (the engine's fade plays,
// and a morph between two pages stands).
export function planVisit({ direction, from, to, transitions, sharedName }, random = Math.random) {
  if (!transitions || !from || !to || !Object.hasOwn(DIRECTIONS, direction)) return null
  if (from === to) return STILL
  return sharedName ? null : pickStyle(direction, random)
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

let installed = false

export function installPageTransitions(doc) {
  if (installed || !readDirection(doc)) return false
  installed = true

  const win = doc.defaultView
  const root = doc.documentElement
  const known = new Map()
  let from = win.location.pathname
  let target = null

  const nameTheMorph = (shared) => {
    if (shared) root.dataset.pageTransitionMorph = ""
    else delete root.dataset.pageTransitionMorph
  }
  const predict = (names) => nameTheMorph(target !== from && shareName(morphNames(doc), names))

  root.dataset.pageTransitionDirection = readDirection(doc)
  markHeld(doc)
  known.set(from, morphNames(doc))

  doc.addEventListener("turbo:visit", (event) => {
    root.dataset.pageTransitionVisit = ""
    target = new URL(event.detail.url).pathname
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
      from,
      to: target,
      transitions: !!doc.startViewTransition && !win.matchMedia(REDUCED_MOTION).matches,
      sharedName,
    })
    nameTheMorph(sharedName && style !== STILL)
    if (style) root.dataset.pageTransition = style
    else delete root.dataset.pageTransition
    if (style && style !== STILL) holdRender(event, () => readyForSwap(doc, newBody))
  }, { capture: true })

  // Turbo fires this after the transition has finished.
  doc.addEventListener("turbo:load", () => {
    from = win.location.pathname
    target = null
    known.set(from, morphNames(doc))
    delete root.dataset.pageTransition
    delete root.dataset.pageTransitionVisit
    nameTheMorph(false)
  })

  // A visit that never renders: the stack must not keep its name at rest.
  for (const name of ["turbo:fetch-request-error", "turbo:reload"]) {
    doc.addEventListener(name, () => { delete root.dataset.pageTransitionVisit })
  }
  return true
}

if (typeof document !== "undefined") installPageTransitions(document)
