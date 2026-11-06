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
import { Controller } from "@hotwired/stimulus"
import { currentStop, hiddenEnds, keyAction, perPage, positionText, stops, targetStop } from "studio/carousel"

// Keys inside these belong to the field, not the row.
const TYPING = "input, textarea, select, [contenteditable]"

export default class extends Controller {
  static targets = ["track", "slide", "prev", "next", "dot", "status"]

  connect() {
    this.schedule = this.schedule.bind(this)
    this.trackTarget.addEventListener("scroll", this.schedule, { passive: true })
    if (typeof ResizeObserver === "function") {
      this.observer = new ResizeObserver(this.schedule)
      this.observer.observe(this.trackTarget)
    }
    this.element.setAttribute("data-carousel-ready", "")
    this.sync()
  }

  disconnect() {
    this.trackTarget.removeEventListener("scroll", this.schedule)
    this.observer?.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
    this.frame = null
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
    if (this.hasPrevTarget) this.prevTarget.setAttribute("aria-disabled", String(!ends.start))
    if (this.hasNextTarget) this.nextTarget.setAttribute("aria-disabled", String(!ends.end))
    this.dotTargets.forEach((dot, index) => {
      dot.hidden = index >= positions.length
      if (index === this.current) dot.setAttribute("aria-current", "true")
      else dot.removeAttribute("aria-current")
    })
  }

  prev() { this.move("prev") }

  next() { this.move("next") }

  goTo(event) {
    this.sync()
    this.scrollToStop(Number(event.currentTarget.dataset.carouselIndex))
  }

  key(event) {
    if (event.target.closest?.(TYPING)) return
    // Alt+Left is Back, Cmd+Left a line start: a held modifier leaves the key alone.
    if (event.altKey || event.metaKey || event.ctrlKey || event.shiftKey) return
    const action = keyAction(event.key)
    if (!action) return
    event.preventDefault()
    this.move(action)
  }

  move(action) {
    this.sync()
    this.scrollToStop(targetStop(action, this.current, this.page, this.positions.length))
  }

  scrollToStop(index) {
    const left = this.positions[index]
    if (left === undefined) return

    const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches
    this.trackTarget.scrollTo({ left, behavior: reduce ? "auto" : "smooth" })

    if (!this.hasStatusTarget) return
    const total = this.slideTargets.length
    const last = index === this.positions.length - 1
    const first = last ? Math.max(0, total - this.page) : index
    this.statusTarget.textContent = positionText(first, this.page, total)
  }
}
