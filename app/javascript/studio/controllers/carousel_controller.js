// carousel: the arrows, dots and keys of studio/_carousel. The track is a native
// scroll-snap row, so a swipe, a trackpad and a focused link move it with no
// script; this controller reads where the row rests and moves it on request.
//
//   <section class="carousel" data-studio-controller="carousel" ...>
//     <div class="carousel-track" data-carousel-target="track">slides</div>
//     <div class="carousel-controls">dots, prev, next</div>
//   </section>
//
// It marks the ends that hide a slide (the edge fade), sets aria-disabled on an
// arrow at its end, hides the dots past the last stop, and says where the row
// went in a polite status line, but only after a press: a swipe announces nothing.
//
// A lazy controller (studio/stimulus): only a page with a carousel fetches it.
// Until it connects the controls stay hidden and the row keeps a thin scrollbar,
// so a carousel whose controller failed is still a row that scrolls.
//
// A SPOTLIGHT row (class carousel-spotlight) snaps each slide to the centre: every
// slide is a stop, an arrow moves one slide, and the slide nearest the centre
// carries data-current, which the CSS styles where scroll-driven animations are
// missing and under reduced motion.
//
// THE START (the partial's start:, data-carousel-start): a row that opens past its
// first slide. The browser lands there before the first paint where it has
// scroll-initial-target (engine.css); elsewhere connect() jumps there, with no glide
// and nothing in the status line. A row already moved (the browser's own start, a
// restored scroll, a #fragment inside it) is left where it is.
//
// A LOOPING row (loop:, data-carousel-loop) wraps: Next at the last stop goes back
// to the first, Previous at the first to the last, and neither arrow is ever
// aria-disabled. There are no cloned slides, so a screen reader reads each once:
// the row glides back across itself.
//
// AUTOPLAY (autoplay: seconds, data-carousel-autoplay) moves the row one stop each
// interval. It holds still while the pointer is over the slides, while keyboard focus
// is in it, while the tab is hidden or the row is off screen, and after a swipe,
// wheel, arrow, dot or key until the reader has left it alone a while (idleDelay).
// The pause button (WCAG 2.2.2) stops it until pressed again; under reduced motion
// the row starts stopped. A move by autoplay writes nothing to the status line
// (APG: a rotating carousel does not announce). Without loop it stops at the end.
import { Controller } from "@hotwired/stimulus"
import {
  TOLERANCE, autoplayRunning, autoplaySeconds, autoplayStop, centerStops, currentStop, hiddenEnds, idleDelay,
  initialReasons, keyAction, ownsKey, perPage, positionText, startStop, stops, targetStop, toggleLabel, withReason
} from "studio/carousel"

const REDUCE = "(prefers-reduced-motion: reduce)"

export default class extends Controller {
  static targets = ["track", "slide", "prev", "next", "dot", "status", "toggle"]

  connect() {
    this.schedule = this.schedule.bind(this)
    this.loop = this.element.hasAttribute("data-carousel-loop")
    this.trackTarget.addEventListener("scroll", this.schedule, { passive: true })
    if (typeof ResizeObserver === "function") {
      this.observer = new ResizeObserver(this.schedule)
      this.observer.observe(this.trackTarget)
    }
    this.element.setAttribute("data-carousel-ready", "")
    this.openAtStart()
    this.sync()
    this.startAutoplay()
  }

  openAtStart() {
    const start = Number(this.element.dataset.carouselStart)
    if (!(start > 0)) return
    const track = this.trackTarget
    if (Math.abs(track.scrollLeft) > TOLERANCE) return
    const hash = window.location?.hash
    if (hash && hash.length > 1) {
      let target = null
      try { target = document.getElementById(decodeURIComponent(hash.slice(1))) } catch { target = null }
      if (target && track.contains(target)) return
    }
    const { positions } = this.measure()
    const left = positions[startStop(start, positions.length)]
    if (left === undefined) return
    track.scrollTo({ left, behavior: "instant" })
  }

  disconnect() {
    this.trackTarget.removeEventListener("scroll", this.schedule)
    this.observer?.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
    this.frame = null
    this.stopAutoplay()
  }

  // -- autoplay ---------------------------------------------------------------

  startAutoplay() {
    this.seconds = autoplaySeconds(this.element.dataset.carouselAutoplay)
    if (this.seconds === null) return

    this.motion = window.matchMedia?.(REDUCE)
    this.reasons = initialReasons({ reducedMotion: !!this.motion?.matches, hidden: document.hidden })
    this.listeners = [
      [this.trackTarget, "pointerenter", (event) => { if (event.pointerType !== "touch") this.pause("hover", true) }],
      [this.trackTarget, "pointerleave", (event) => { if (event.pointerType !== "touch") this.pause("hover", false) }],
      [this.element, "focusin", (event) => this.pause("focus", this.keyboardFocus(event.target))],
      [this.element, "focusout", (event) => { if (!this.element.contains(event.relatedTarget)) this.pause("focus", false) }],
      [this.trackTarget, "pointerdown", () => this.interacted()],
      [this.trackTarget, "wheel", () => this.interacted()],
      [this.trackTarget, "touchstart", () => this.interacted()],
      [document, "visibilitychange", () => this.pause("hidden", document.hidden)],
      [this.motion, "change", (event) => { if (event.matches) this.pause("stopped", true) }]
    ].filter(([target]) => target?.addEventListener)
    this.listeners.forEach(([target, type, handler]) => target.addEventListener(type, handler, { passive: true }))

    if (typeof IntersectionObserver === "function") {
      this.viewport = new IntersectionObserver(([entry]) => this.pause("offscreen", !entry.isIntersecting))
      this.viewport.observe(this.element)
    }
    this.refresh()
  }

  stopAutoplay() {
    this.listeners?.forEach(([target, type, handler]) => target.removeEventListener(type, handler))
    this.listeners = null
    this.viewport?.disconnect()
    this.viewport = null
    clearTimeout(this.timer)
    clearTimeout(this.idle)
    this.timer = this.idle = null
  }

  // Focus by keyboard holds the row; a mouse click that focuses an arrow does not.
  // The pause button is the exception: a reader who tabs to it and presses Play
  // means it to play.
  keyboardFocus(target) {
    if (this.hasToggleTarget && this.toggleTarget.contains(target)) return false
    try { return target.matches(":focus-visible") } catch { return true }
  }

  pause(reason, on) {
    if (this.seconds === null || !this.reasons) return
    this.reasons = withReason(this.reasons, reason, on)
    this.refresh()
  }

  // A swipe, a wheel, an arrow, a dot or a key: hold still until the reader has
  // left the row alone for idleDelay.
  interacted() {
    if (this.seconds === null || !this.reasons) return
    clearTimeout(this.idle)
    this.idle = setTimeout(() => { this.idle = null; this.pause("interaction", false) }, idleDelay(this.seconds))
    this.pause("interaction", true)
  }

  // The pause button.
  toggle() {
    if (this.seconds === null || !this.reasons) return
    const stopped = !this.reasons.has("stopped")
    if (!stopped) {
      // Play at the end of a row that does not loop starts it again from the first.
      this.sync()
      if (!this.loop && autoplayStop(this.current, this.positions.length, false) === null && this.current > 0) {
        this.scrollToStop(0, { announce: false })
      }
    }
    this.pause("stopped", stopped)
  }

  refresh() {
    const running = autoplayRunning(this.seconds, this.reasons)
    const stopped = this.reasons.has("stopped")
    this.element.toggleAttribute("data-carousel-playing", running)
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-label", toggleLabel(stopped))
      this.toggleTarget.toggleAttribute("data-carousel-stopped", stopped)
    }
    if (!running) {
      clearTimeout(this.timer)
      this.timer = null
    } else if (!this.timer) {
      this.timer = setTimeout(() => this.tick(), this.seconds * 1000)
    }
  }

  tick() {
    this.timer = null
    this.sync()
    const count = this.positions.length
    const to = autoplayStop(this.current, count, this.loop)
    if (to === null && count > 1) {
      // The end of a row that does not loop: autoplay is done until Play.
      this.pause("stopped", true)
      return
    }
    if (to !== null) this.scrollToStop(to, { announce: false })
    this.refresh()
  }

  schedule() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.sync()
    })
  }

  measure() {
    const track = this.trackTarget
    const slides = this.slideTargets
    if (this.element.classList.contains("carousel-spotlight")) {
      const max = Math.max(0, track.scrollWidth - track.clientWidth)
      const boxes = slides.map((slide) => ({ left: slide.offsetLeft, width: slide.offsetWidth }))
      return { positions: centerStops(boxes, track.clientWidth, max), page: 1 }
    }
    const origin = slides[0]?.offsetLeft || 0
    const max = Math.max(0, track.scrollWidth - track.clientWidth)
    const gap = parseFloat(getComputedStyle(track).columnGap) || 0
    return {
      positions: stops(slides.map((slide) => slide.offsetLeft - origin), max),
      page: perPage(track.clientWidth, slides[0]?.offsetWidth, gap)
    }
  }

  sync() {
    const track = this.trackTarget
    const { positions, page } = this.measure()
    const ends = hiddenEnds(track)

    this.positions = positions
    this.page = page
    this.current = currentStop(track.scrollLeft, positions)

    this.element.toggleAttribute("data-carousel-static", positions.length < 2)
    track.toggleAttribute("data-fade-start", ends.start)
    track.toggleAttribute("data-fade-end", ends.end)
    // A looping row never disables an arrow: each end leads round to the other.
    const wraps = this.loop && positions.length > 1
    if (this.hasPrevTarget) this.prevTarget.setAttribute("aria-disabled", String(!wraps && !ends.start))
    if (this.hasNextTarget) this.nextTarget.setAttribute("aria-disabled", String(!wraps && !ends.end))
    if (this.element.classList.contains("carousel-spotlight")) {
      this.slideTargets.forEach((slide, index) => slide.toggleAttribute("data-current", index === this.current))
    }
    this.dotTargets.forEach((dot, index) => {
      dot.hidden = index >= positions.length
      if (index === this.current) dot.setAttribute("aria-current", "true")
      else dot.removeAttribute("aria-current")
    })
  }

  prev() { this.move("prev") }

  next() { this.move("next") }

  goTo(event) {
    this.interacted()
    this.sync()
    this.scrollToStop(Number(event.currentTarget.dataset.carouselIndex))
  }

  key(event) {
    // A form field, a widget that owns the arrow keys, or a nested carousel keeps them.
    if (!ownsKey(event.target, this.element)) return
    // Alt+Left is Back, Cmd+Left a line start: a held modifier leaves the key alone.
    if (event.altKey || event.metaKey || event.ctrlKey || event.shiftKey) return
    const action = keyAction(event.key)
    if (!action) return
    event.preventDefault()
    this.move(action)
  }

  // A press that goes nowhere (an arrow at its end, Home at the start) scrolls
  // nothing and says nothing: the status line speaks only when the row moves.
  move(action) {
    this.interacted()
    this.sync()
    const to = targetStop(action, this.current, this.page, this.positions.length, this.loop)
    if (to === this.current) return
    this.scrollToStop(to)
  }

  // announce: false for autoplay, which moves the row without a word.
  scrollToStop(index, { announce = true } = {}) {
    const left = this.positions[index]
    if (left === undefined) return

    const reduce = window.matchMedia?.(REDUCE).matches
    this.trackTarget.scrollTo({ left, behavior: reduce ? "auto" : "smooth" })

    if (!announce || !this.hasStatusTarget) return
    const total = this.slideTargets.length
    const last = index === this.positions.length - 1
    const first = last ? Math.max(0, total - this.page) : index
    this.statusTarget.textContent = positionText(first, this.page, total)
  }
}
