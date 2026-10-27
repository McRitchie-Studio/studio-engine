/*
  studio/studio_confetti — two zero-dependency celebration effects built on the
  vendored canvas-confetti (app/assets/javascripts/studio/canvas_confetti.js,
  pinned as "canvas-confetti", no CDN).

  An ES module (the head loads it with a type="module" tag after the import
  map). It imports canvas-confetti for its side effect, which defines the
  library's global `confetti`, and exports:

    import { burst, cannons, confetti } from "studio/studio_confetti"
    burst(cardEl)    // radial burst behind a card/modal
    cannons()        // side-cannons full-screen celebration
    confetti(opts)   // the canvas-confetti call itself, a no-op if it failed to load

  Ported faithfully from turf-monster:
    - burst(target)  → the radial card-burst that explodes from BEHIND a card or
      modal, emanating from its center (TM solana_utils.js fireConfettiFromModal /
      shared/_alpine_factories fireQuestBadgeConfetti). Pass the DOM element (or a
      selector, or an {x,y} origin in 0..1 viewport space) to aim it; defaults to
      screen center.
    - cannons(opts)  → the full-screen "you joined a contest" celebration: a center
      burst plus left + right side-cannons firing inward and a top shell (the same
      choreography as the engine head's window.fireSuccessConfetti).

  Both honor prefers-reduced-motion: reduce (no-op, and disableForReducedMotion is
  also passed through to canvas-confetti as a second belt). Colors come from
  window.CONFETTI_COLORS when a host sets it, else a neutral festive default.

  DEPRECATED COMPATIBILITY GLOBALS (CHANGELOG, "Deprecated"): window.studioConfetti
  ({ burst, cannons }) and the library's own window.confetti stay, because hosts
  call them from classic code (turf-monster's solana_utils and _alpine_factories).
  New code imports from this module. Both now exist once the head's modules have
  run (deferred, before Alpine starts), no longer during the body's parse.
*/
import "canvas-confetti"

const DEFAULT_COLORS = [
  "#4BAF50", "#8E82FE", "#06D6A0", "#FF7C47",
  "#FFD700", "#00BFFF", "#FF6B9D", "#C084FC"
]

function colors(opts) {
  return (opts && opts.colors) || window.CONFETTI_COLORS || DEFAULT_COLORS
}

function reducedMotion() {
  return !!(window.matchMedia &&
            window.matchMedia("(prefers-reduced-motion: reduce)").matches)
}

// The canvas-confetti call. Read off the window on every call, not captured at
// import: the vendored build assigns the global when it is evaluated, and a
// failed load leaves it undefined, which makes every effect a no-op.
export function confetti(opts) {
  if (typeof window.confetti !== "function") return null
  return window.confetti(opts)
}

function available() {
  return typeof window.confetti === "function" && !reducedMotion()
}

// Resolve a burst origin ({x,y} in 0..1 viewport space) from an element, a
// selector, or a literal {x,y}. Falls back to screen center when the target is
// missing or not laid out (e.g. a card that just unmounted).
function originFor(target) {
  const el = (typeof target === "string") ? document.querySelector(target) : target
  if (el && el.nodeType === 1) {
    const r = el.getBoundingClientRect()
    if (r.width || r.height) {
      return {
        x: (r.left + r.width / 2) / window.innerWidth,
        y: (r.top + r.height / 2) / window.innerHeight
      }
    }
  }
  if (target && typeof target.x === "number" && typeof target.y === "number") {
    return { x: target.x, y: target.y }
  }
  return { x: 0.5, y: 0.5 }
}

// Radial burst from behind a card/modal — spread:360 fires in every direction
// from the card center, low velocity + gravity keep it clustered around the
// card rather than blasting off-screen. A smaller follow-shell layers texture,
// and two bottom-corner sweeps give the moment theatre.
export function burst(target, opts) {
  if (!available()) return
  opts = opts || {}
  const origin = originFor(target)
  const c = colors(opts)
  const z = opts.zIndex || 9999
  confetti({ particleCount: 140, angle: 90, spread: 360, origin: origin, colors: c, zIndex: z, startVelocity: 30, gravity: 0.7, ticks: 220, scalar: 1.0, disableForReducedMotion: true })
  setTimeout(() => {
    confetti({ particleCount: 60, angle: 60, spread: 70, origin: { x: Math.max(0, origin.x - 0.18), y: Math.min(1, origin.y + 0.05) }, colors: c, zIndex: z, startVelocity: 40, gravity: 0.9, ticks: 200, scalar: 0.9, disableForReducedMotion: true })
    confetti({ particleCount: 60, angle: 120, spread: 70, origin: { x: Math.min(1, origin.x + 0.18), y: Math.min(1, origin.y + 0.05) }, colors: c, zIndex: z, startVelocity: 40, gravity: 0.9, ticks: 200, scalar: 0.9, disableForReducedMotion: true })
  }, 180)
}

// Full-screen side-cannon celebration: center burst, then left + right cannons
// firing inward, then a wide top shell. Mirrors window.fireSuccessConfetti.
export function cannons(opts) {
  if (!available()) return
  opts = opts || {}
  const c = colors(opts)
  const z = opts.zIndex || 9999
  confetti({ particleCount: 150, spread: 100, origin: { x: 0.5, y: 0.5 }, colors: c, zIndex: z, startVelocity: 45, gravity: 0.8, ticks: 300, scalar: 1.2, disableForReducedMotion: true })
  setTimeout(() => { confetti({ particleCount: 80, angle: 60,  spread: 60,  origin: { x: 0,   y: 0.6 }, colors: c, zIndex: z, startVelocity: 55, gravity: 1,   ticks: 250, disableForReducedMotion: true }) }, 150)
  setTimeout(() => { confetti({ particleCount: 80, angle: 120, spread: 60,  origin: { x: 1,   y: 0.6 }, colors: c, zIndex: z, startVelocity: 55, gravity: 1,   ticks: 250, disableForReducedMotion: true }) }, 150)
  setTimeout(() => { confetti({ particleCount: 100, spread: 160, origin: { x: 0.5, y: 0.3 }, colors: c, zIndex: z, startVelocity: 30, gravity: 1.2, ticks: 200, scalar: 0.8, disableForReducedMotion: true }) }, 400)
}

const studioConfetti = { burst, cannons }
export default studioConfetti

// DEPRECATED: the compatibility global for classic callers. Import the module.
window.studioConfetti = studioConfetti
