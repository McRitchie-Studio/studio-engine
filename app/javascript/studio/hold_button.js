// studio/hold_button: the hold-to-confirm button behind studio/_hold_button.
// The hold's timeline, the idle nudge, and the fizz portal.
//
// The partial renders markup only. Its stack carries the controller and its
// button the presses:
//
//   <span class="hold-stack" data-studio-controller="hold-button">
//     <button class="hold-btn" data-hold-id="confirm" data-duration="2000"
//             data-studio-action="mousedown->hold-button#start ...">
//
// studio/controllers/hold_button_controller binds one Hold to the button and
// answers its hooks; studio/stimulus registers that controller lazily.
//
// THE TIMELINE of one press, in ms from the press:
//
//   0            guard: refused, and nothing below happens.
//                started.
//   validateAt   validate: a false or failed answer aborts the hold.
//   earlyAt      early: an answer of true takes the action over, and the hold
//                never completes.
//   duration     completed. The confirm is committed here: a release after
//                this point does not take it back.
//
// A release before `duration` ends the hold and nothing fires. A hook that
// throws never confirms by accident: a throwing guard refuses the hold, and a
// throwing validate aborts it.
//
// It imports nothing; test/javascript/hold_button.test.mjs loads it as a data:
// module.

export const DEFAULT_DURATION_MS = 2000
export const DEFAULT_VALIDATE_AT_MS = 750
export const DEFAULT_EARLY_AT_MS = 1500
// The idle nudge: the first after NUDGE_FIRST_S of rest, then a soft one every
// NUDGE_REPEAT_S. After a release only the soft ones run.
export const NUDGE_FIRST_S = 3
export const NUDGE_REPEAT_S = 10
// Studio::FizzHelper::SLOTS: the --fizz-c-<n> custom properties a stack may
// carry. test/views/hold_button_test.rb holds the two equal.
export const FIZZ_SLOTS = 18
// The nudge ring's circumference, for r=9 in the partial's svg.
const CIRCUMFERENCE = 2 * Math.PI * 9

const number = (value, fallback) => {
  const parsed = parseInt(value, 10)
  return Number.isNaN(parsed) ? fallback : parsed
}

// A button's timing, from the data attributes the partial writes.
export function holdConfig(dataset) {
  const data = dataset || {}
  return {
    id: data.holdId || "hold",
    duration: number(data.duration, DEFAULT_DURATION_MS),
    validateAt: number(data.validateAt, DEFAULT_VALIDATE_AT_MS),
    earlyAt: number(data.earlyActionAt, DEFAULT_EARLY_AT_MS)
  }
}

const systemTimers = () => ({
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (id) => clearTimeout(id),
  setInterval: (fn, ms) => setInterval(fn, ms),
  clearInterval: (id) => clearInterval(id)
})

// Snap the progress ring to empty with no reverse animation, running `change`
// (a class change) while its transition is off.
function snapProgress(button, change) {
  const circle = button.querySelector("svg.progress circle")
  if (!circle) { change(); return }
  circle.style.transition = "none"
  change()
  void circle.offsetWidth
  circle.style.transition = ""
}

// The idle nudge on one button: a countdown ring and a wiggle when it runs out.
export class NudgeCycle {
  constructor(button, timers) {
    this.button = button
    this.timers = timers || systemTimers()
    this.tick = null
  }

  start(softOnly = false) {
    this.stop()
    let total = softOnly ? NUDGE_REPEAT_S : NUDGE_FIRST_S
    let left = total
    let first = !softOnly
    this.ring(left, total)

    this.tick = this.timers.setInterval(() => {
      left -= 1
      if (left <= 0) {
        this.nudge(first ? "nudge" : "nudge-soft")
        first = false
        total = NUDGE_REPEAT_S
        left = NUDGE_REPEAT_S
      }
      this.ring(left, total)
    }, 1000)
  }

  stop() {
    if (this.tick !== null) this.timers.clearInterval(this.tick)
    this.tick = null
  }

  nudge(name) {
    const classes = this.button.classList
    if (classes.contains("process") || classes.contains("success")) return
    classes.remove("nudge", "nudge-soft")
    void this.button.offsetWidth
    classes.add(name)
  }

  ring(left, total) {
    const debug = this.button.querySelector(".nudge-debug")
    if (!debug) return
    debug.querySelector("circle.fill").style.strokeDashoffset = (CIRCUMFERENCE * (left / total)).toFixed(2)
    debug.querySelector(".countdown-num").textContent = left
  }
}

// One button's hold. `hooks` answers the timeline (see the header); each is
// optional:
//
//   guard()      false refuses the press.
//   started()    the hold began.
//   validate()   a boolean or a promise of one; false aborts.
//   early()      true takes the action over.
//   completed()  true when the caller owns the button's state from here;
//                otherwise the button shows `success`.
export class Hold {
  constructor(button, hooks = {}, { timers, report } = {}) {
    this.button = button
    this.hooks = hooks
    this.timers = timers || systemTimers()
    this.report = report || ((what, error) => console.error(`[hold:${this.config().id}] ${what}`, error))
    this.nudge = new NudgeCycle(button, this.timers)
    this.pending = {}
    this.run = 0
  }

  config() { return holdConfig(this.button.dataset) }

  get holding() { return "main" in this.pending }

  // A press. False when the guard refused it.
  start() {
    if (!this.allowed()) return false

    // A second press without a release starts over: the first press's timers
    // go, so one hold never confirms twice.
    this.clear()
    const run = ++this.run
    const { duration, validateAt, earlyAt } = this.config()

    this.attempt("started", () => this.hooks.started && this.hooks.started())

    this.button.classList.remove("nudge", "nudge-soft")
    this.nudge.start()
    snapProgress(this.button, () => this.button.classList.remove("process", "success"))
    this.button.style.setProperty("--duration", duration + "ms")
    this.button.classList.add("process")

    this.pending.main = this.timers.setTimeout(() => this.complete(run), duration)
    this.pending.early = this.timers.setTimeout(() => this.early(run), earlyAt)
    this.pending.validate = this.timers.setTimeout(() => this.validate(run), validateAt)
    return true
  }

  // A release, or the pointer leaving. A finished button stays finished.
  end() {
    const classes = this.button.classList
    if (classes.contains("success") || classes.contains("error")) return
    this.run += 1
    snapProgress(this.button, () => classes.remove("process"))
    this.clear()
    this.nudge.start(true)
  }

  // The button is leaving the page.
  stop() {
    this.run += 1
    this.clear()
    this.nudge.stop()
  }

  allowed() {
    if (!this.hooks.guard) return true
    try {
      return !!this.hooks.guard()
    } catch (error) {
      this.report("guard threw; the hold is refused", error)
      return false
    }
  }

  complete(run) {
    if (run !== this.run) return
    this.clear()
    const owned = this.attempt("completed", () => this.hooks.completed && this.hooks.completed())
    if (owned === true) return
    this.button.classList.remove("process")
    this.button.classList.add("success")
  }

  early(run) {
    if (run !== this.run) return
    delete this.pending.early
    const taken = this.attempt("early", () => this.hooks.early && this.hooks.early())
    if (taken !== true) return
    this.timers.clearTimeout(this.pending.main)
    delete this.pending.main
  }

  validate(run) {
    if (run !== this.run) return
    delete this.pending.validate
    if (!this.hooks.validate) return

    const refuse = (error) => {
      if (error) this.report("validate failed; the hold is aborted", error)
      // An answer for a press that has since been released, or has already
      // completed, aborts nothing.
      if (run === this.run && this.holding) this.abort()
    }
    try {
      Promise.resolve(this.hooks.validate()).then((ok) => { if (!ok) refuse() }, refuse)
    } catch (error) {
      refuse(error)
    }
  }

  // Validation said no: the hold stops where it is and the ring empties.
  abort() {
    this.clear()
    snapProgress(this.button, () => this.button.classList.remove("process"))
  }

  clear() {
    for (const id of Object.values(this.pending)) this.timers.clearTimeout(id)
    this.pending = {}
  }

  // A hook that throws is reported and answers undefined: it never stops the
  // timeline, and never counts as a yes.
  attempt(what, hook) {
    try {
      return hook()
    } catch (error) {
      this.report(`${what} threw`, error)
      return undefined
    }
  }
}

// ── The fizz portal (fizz_portal: true) ─────────────────────────────────────
// Moves a stack's bubble layers to the document body in one fixed box that
// tracks the stack's rect, so a card's overflow clip cannot cut them off. The
// box mirrors the button's state classes and the stack's palette, because the
// CSS can no longer read either through the stack. engine-motion.css, THE
// PORTAL, holds the other half.
export const PORTAL_STATES = ["process", "loading", "success", "error", "nudge", "nudge-soft"]
let portals = []

// One rung above the highest z-index among the stack's ancestors, so the
// bubbles clear the card, the panel or the modal the button sits in, and never
// below --z-raised.
function portalZ(stack) {
  const floor = parseInt(getComputedStyle(document.documentElement).getPropertyValue("--z-raised"), 10)
  let top = Number.isNaN(floor) ? 20 : floor
  for (let node = stack.parentElement; node && node !== document.body; node = node.parentElement) {
    const z = parseInt(getComputedStyle(node).zIndex, 10)
    if (!Number.isNaN(z) && z + 1 > top) top = z + 1
  }
  return top
}

function syncPortalState(portal) {
  for (const state of PORTAL_STATES) {
    portal.box.classList.toggle("is-" + state, portal.button.classList.contains(state))
  }
}

function syncPortalPalette(portal) {
  const styles = getComputedStyle(portal.stack)
  for (let slot = 1; slot <= FIZZ_SLOTS; slot += 1) {
    const value = styles.getPropertyValue("--fizz-c-" + slot).trim()
    if (value) portal.box.style.setProperty("--fizz-c-" + slot, value)
    else portal.box.style.removeProperty("--fizz-c-" + slot)
  }
}

function placePortal(portal) {
  if (!portal.stack.isConnected) { unmountPortal(portal, false); return }
  const rect = portal.stack.getBoundingClientRect()
  const shown = portal.visible && rect.width > 0 && rect.height > 0
  portal.box.style.visibility = shown ? "" : "hidden"
  if (shown) {
    portal.box.style.transform = "translate(" + rect.left + "px, " + rect.top + "px)"
    portal.box.style.width = rect.width + "px"
    portal.box.style.height = rect.height + "px"
    if (portal.parked) { clearInterval(portal.parked); portal.parked = null }
    portal.frame = requestAnimationFrame(() => placePortal(portal))
  } else {
    portal.frame = null
    // Parked: no frames run, so nothing would notice the stack leaving the DOM
    // (an x-if, a Turbo stream, a closed modal). A slow check tears the box and
    // its observers down when it does.
    if (!portal.parked) {
      portal.parked = setInterval(() => {
        if (!portal.stack.isConnected) unmountPortal(portal, false)
      }, 1000)
    }
  }
}

// `restore` puts the box back where the server rendered it, with nothing the
// script added, so a cached snapshot restores to the markup it came from.
export function unmountPortal(portal, restore) {
  if (!portal || !portals.includes(portal)) return
  if (portal.frame) cancelAnimationFrame(portal.frame)
  if (portal.parked) clearInterval(portal.parked)
  portal.observers.forEach((observer) => observer.disconnect())
  portal.button.removeEventListener("mouseenter", portal.enter)
  portal.button.removeEventListener("mouseleave", portal.leave)
  if (restore && portal.stack.isConnected) {
    portal.box.className = portal.box.className.replace(/\s*\bis-[\w-]+/g, "")
    portal.box.removeAttribute("style")
    portal.box.removeAttribute("data-fizz-portal-for")
    portal.stack.insertBefore(portal.box, portal.stack.firstChild)
  } else {
    portal.box.remove()
  }
  delete portal.stack._fizzPortal
  portals = portals.filter((other) => other !== portal)
}

export function mountPortal(stack) {
  if (stack._fizzPortal) return stack._fizzPortal
  const box = stack.querySelector(":scope > .hold-fizz-portal")
  const button = stack.querySelector(":scope > .hold-btn")
  if (!box || !button) return null

  const portal = { stack, box, button, visible: true, frame: null, parked: null, observers: [] }
  stack._fizzPortal = portal
  portals.push(portal)

  document.body.appendChild(box)
  box.classList.add("is-portaled")
  box.setAttribute("data-fizz-portal-for", button.dataset.holdId || "hold")
  box.style.zIndex = portalZ(stack)
  syncPortalState(portal)
  syncPortalPalette(portal)

  portal.enter = () => box.classList.add("is-hover")
  portal.leave = () => box.classList.remove("is-hover")
  button.addEventListener("mouseenter", portal.enter)
  button.addEventListener("mouseleave", portal.leave)

  const states = new MutationObserver(() => syncPortalState(portal))
  states.observe(button, { attributes: true, attributeFilter: ["class"] })
  const palette = new MutationObserver(() => syncPortalPalette(portal))
  palette.observe(stack, { attributes: true, attributeFilter: ["style"] })
  portal.observers.push(states, palette)

  // Track the rect every frame while the stack is on screen. Park the box while
  // it is not (scrolled away, inside a closed panel, clipped out of a scroll
  // container): no frames, only a once-a-second check that the stack is still
  // in the DOM.
  if ("IntersectionObserver" in window) {
    const seen = new IntersectionObserver((entries) => {
      portal.visible = entries[entries.length - 1].isIntersecting
      if (!portal.stack.isConnected) { unmountPortal(portal, false); return }
      if (portal.visible && !portal.frame) placePortal(portal)
      if (!portal.visible) placePortal(portal)
    })
    seen.observe(stack)
    portal.observers.push(seen)
  }
  placePortal(portal)
  return portal
}

export function mountAllPortals() {
  portals.slice().forEach((portal) => { if (!portal.stack.isConnected) unmountPortal(portal, false) })
  document.querySelectorAll(".hold-stack[data-fizz-portal]").forEach(mountPortal)
}

export function restoreAllPortals() {
  portals.slice().forEach((portal) => unmountPortal(portal, true))
}

export const portalCount = () => portals.length

const installed = new WeakSet()

// Once per window. window.studioFizzPortal is the portal's handle for a page
// that inserts a stack by hand and for the engine's own browser specs.
export function installHoldButton({ win, doc } = {}) {
  const host = win || globalThis
  const root = doc || host.document
  if (!root || typeof root.addEventListener !== "function") return false
  if (installed.has(host)) return false
  installed.add(host)

  host.studioFizzPortal = { mount: mountPortal, mountAll: mountAllPortals, count: portalCount }
  // Before Turbo caches the page every box goes back into its stack.
  root.addEventListener("turbo:before-cache", restoreAllPortals)
  return true
}

if (typeof window !== "undefined") installHoldButton({ win: window, doc: document })
