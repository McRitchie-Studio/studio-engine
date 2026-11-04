// studio/transition_snapshot: Turbo's snapshot never keeps an Alpine transition's
// mid-slide state, and a restored page recovers from one that did.
//
// THE DEFECT. Turbo clones the live page one tick after turbo:before-cache. A link
// in a components/_sidebar_panel closes the panel on its click, so a response that
// arrives inside the 200ms leave clones the panel with Alpine's phase classes on it
// (`transition ease-in duration-200 translate-x-full`). A hovered link has a
// prefetched response, so this is ordinary in production as well as on localhost.
// The clone has no running transition to remove them. Back then restores it, and the
// panel sits one width off-screen for good: Alpine's transition removes only the
// classes it added itself, so it never removes a class it found already there, and
// closing and reopening changes nothing. Only a full load clears it.
//
// THE TWO HALVES.
//
//   1. Before the clone, finish every running transition with Alpine's own finish().
//      Alpine removes exactly what it added, and a leave goes on to its display:none.
//      This also covers an x-transition.opacity, which writes inline style and names
//      no class.
//   2. On turbo:before-render, strip the phase classes from the incoming body before
//      Alpine sees it, for a snapshot that holds them anyway.
//
// WHEN "BEFORE THE CLONE" IS. Two handlers, because nothing orders Turbo's clone and
// its swap. turbo:before-cache cannot finish anything itself: the event is what closes
// a panel (link_sidebar's handler, a panel's @turbo:before-cache.window), and that
// close starts its leave in a microtask after the handlers return.
//
//   turbo:before-render  the plain path, measured: the swap runs in microtasks, ahead
//                        of the clone. This is the last moment the panel is connected,
//                        and Alpine skips a finished transition's cleanup on a
//                        disconnected element.
//   a zero timeout set   the path where the clone comes first (a view transition or a
//   in before-cache      held render puts the swap later). It fires ahead of the one
//                        Turbo sets right after the event for its clone: timers of one
//                        delay fire in order.
//
// Neither waits for an animation, so nothing here depends on how long a slide takes.
// The timeout also strips the old body, for a transition something started after
// before-render on a body that has gone. If Turbo ever changes this order, the second
// half still recovers the page.
//
// THE STRIP'S RULE. It removes only classes named in the element's own x-transition
// attributes, and only when the element holds a whole phase: all of a direction's
// `during` classes plus all of its `-start` or all of its `-end`. A panel at rest
// never holds that. The cost: the strip runs on every Turbo render, not only a restore,
// so an element that keeps a whole phase at rest loses those classes. No view in the engine, the
// hub or turf-monster names one (scanned 2026-11-04).
//
// Nothing here sets `display`: studio/link_sidebar's contract stands, and x-show
// still owns it. WHY THIS IS ITS OWN ENTRY POINT. layouts/studio/_head imports it by
// its own nonced module tag as well as through the boot graph, so a failed boot
// leaves a page this. It imports nothing.

const RUNS_A_TRANSITION = "[x-show], [x-transition\\:enter], [x-transition\\:leave]"
const NAMES_CLASSES = "[x-transition\\:enter], [x-transition\\:leave]"
const DIRECTIONS = ["enter", "leave"]

function named(el, part) {
  return (el.getAttribute(`x-transition:${part}`) || "").split(/\s+/).filter(Boolean)
}

function holdsAll(el, classes) {
  return classes.length > 0 && classes.every((name) => el.classList.contains(name))
}

// The classes to remove from `el`: empty unless it holds a whole phase.
export function midSlideClasses(el) {
  const classes = new Set()
  for (const direction of DIRECTIONS) {
    const during = named(el, direction)
    const start = named(el, `${direction}-start`)
    const end = named(el, `${direction}-end`)
    if (holdsAll(el, during) && (holdsAll(el, start) || holdsAll(el, end))) {
      for (const name of [...during, ...start, ...end]) classes.add(name)
    }
  }
  return [...classes]
}

// The second half. Null-safe: turbo:before-render may carry no body.
export function stripMidSlideClasses(root) {
  if (!root || typeof root.querySelectorAll !== "function") return
  root.querySelectorAll(NAMES_CLASSES).forEach((el) => {
    const classes = midSlideClasses(el)
    if (classes.length) el.classList.remove(...classes)
  })
}

// The first half. finish() is what Alpine's own timer calls when a slide ends, and
// it runs once, so that timer does nothing afterward. An Alpine with no such handle
// or no finish() finishes nothing here, and must not throw: the strip runs next.
export function finishTransitions(root) {
  if (!root || typeof root.querySelectorAll !== "function") return
  root.querySelectorAll(RUNS_A_TRANSITION).forEach((el) => {
    if (typeof el._x_transitioning?.finish === "function") el._x_transitioning.finish()
  })
}

const installed = new WeakSet()

// Once per window: a second call adds no second listener.
export function installTransitionSnapshot({ win, doc } = {}) {
  const host = win || globalThis
  const root = doc || host.document
  if (!root || typeof root.addEventListener !== "function") return false
  if (installed.has(host)) return false
  installed.add(host)

  root.addEventListener("turbo:before-cache", () => {
    const body = root.body
    host.setTimeout(() => {
      finishTransitions(body)
      stripMidSlideClasses(body)
    }, 0)
  })
  root.addEventListener("turbo:before-render", (event) => {
    finishTransitions(root.body)
    stripMidSlideClasses(event.detail && event.detail.newBody)
  })
  return true
}

if (typeof window !== "undefined") installTransitionSnapshot({ win: window, doc: document })
