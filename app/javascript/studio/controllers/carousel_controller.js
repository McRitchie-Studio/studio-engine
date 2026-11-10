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
// A LOOPING row (loop:, data-carousel-loop) of more than one slide is visually
// continuous. connect() copies the last slides before the first and the first slides
// after the last (cloneLayout), so the space beside either end shows the slides
// round the seam. Next at the last slide glides on to the clone of the first;
// once the row rests there (studio/carousel watchRest: scrollend with a backstop, or
// a short quiet spell where the browser has no scrollend) it jumps, with no glide and no transition, to the real first slide,
// whose neighbours look the same. Previous at the first does the same backwards, and
// a swipe that rests on a clone too. Under reduced motion the row goes straight to
// the real slide. Neither arrow is ever aria-disabled.
//
// A clone is aria-hidden and inert, keeps no id, name, test hook or Stimulus wiring
// (CLONE_STRIP), and is no slide target, so a screen reader and Tab meet each real
// slide once, a #fragment finds the real slide, and the dots and the status line
// count real slides. A click on a clone moves the row to it. disconnect() removes
// the clones, and connect() clears any a page snapshot kept.
//
// AUTOPLAY (autoplay: seconds, data-carousel-autoplay) moves the row one stop each
// interval. It holds still while the pointer is over the slides, while keyboard focus
// is in it, while the tab is hidden or the row is off screen, and after a swipe,
// wheel, arrow, dot or key until the reader has left it alone a while (idleDelay).
// The pause button (WCAG 2.2.2) stops it until pressed again; under reduced motion
// the row starts stopped. A move by autoplay writes nothing to the status line
// (APG: a rotating carousel does not announce). Without loop it stops at the end.
//
// A CASCADE row (class carousel-cascade) does not scroll. Its slides share one grid
// cell and each wears data-cascade-step, its place from the open slide (cascadeStep,
// cascadeSlot); engine.css lays the 3D stack out from it and transitions it. The
// open slide carries data-current. Every slide is a stop, so the arrows, dots, keys
// and autoplay move it as they move a spotlight, through the same move() and
// scrollToStop(). A swipe or a drag (pointer events, past DRAG_THRESHOLD) moves it
// too; a click on a side slide brings that slide to the front and follows no link,
// and keyboard focus landing in a side slide in view does the same. TAB: a slide past
// the window is hidden, so Tab skips it. Tab from the track lands on the first slide
// in view and brings it to the front, and each Tab after moves one slide on. A cascade
// that does not loop and opens mid-row (the default :middle) has slides before the
// window that forward Tab never reaches: Shift+Tab from the first slide in view (its
// focus has moved the stack, so the slide before it is in view), Home, the arrow keys,
// the Previous arrow and the dots reach them. A looping cascade takes no clones: the
// steps wrap round the set, and a slide that crosses the stack round the seam
// (cascadeJumps) takes no glide but fades in, every time. A focused slide that leaves
// the window hands focus to the track, so the keys keep working.
//
// THE CHANGE EVENT (studio/carousel CHANGE_EVENT, "studio:carousel:change"): every
// style dispatches it from the region, bubbling, once per change of the open slide,
// after data-current has moved (announceChange). detail: { index, previous, slide,
// total }. A host follows the open slide with it instead of observing data-current.
import { Controller } from "@hotwired/stimulus"
import {
  CHANGE_EVENT, CLONE_STRIP, TOLERANCE, autoplayRunning, changeDetail, clickedSlide, autoplaySeconds, autoplayStop, cascadeJumps, cascadeReach, cascadeSlot,
  cascadeStep, cascadeSteps, cascadeTarget, centerStops, cloneCount, cloneLayout, dragSteps,
  currentStop, hiddenEnds, idleDelay, initialReasons, keyAction, loopPositionText, loopStop, nearestVirtual, ownsKey,
  perPage, positionText, seamJump, startStop, stops, targetStop, toggleLabel, watchRest, withReason, wrapIndex
} from "studio/carousel"

const REDUCE = "(prefers-reduced-motion: reduce)"

export default class extends Controller {
  static targets = ["track", "slide", "prev", "next", "dot", "status", "toggle"]

  connect() {
    this.schedule = this.schedule.bind(this)
    this.settle = this.settle.bind(this)
    this.clickClone = this.clickClone.bind(this)
    this.loop = this.element.hasAttribute("data-carousel-loop")
    this.cascade = this.element.classList.contains("carousel-cascade")
    this.cloned = 0
    this.removeClones()
    if (this.cascade) {
      this.connectCascade()
      return
    }
    this.trackTarget.addEventListener("scroll", this.schedule, { passive: true })
    this.rest = watchRest(this.trackTarget, this.settle, { scrollend: "onscrollend" in window })
    this.trackTarget.addEventListener("click", this.clickClone)
    if (typeof ResizeObserver === "function") {
      this.observer = new ResizeObserver(this.schedule)
      this.observer.observe(this.trackTarget)
    }
    this.element.setAttribute("data-carousel-ready", "")
    // The first paint's slide: the change event fires only when the open slide leaves it.
    this.opened = Math.max(0, Number(this.element.dataset.carouselStart) || 0)
    this.openAtStart()
    this.addClones()
    this.sync()
    this.startAutoplay()
  }

  // -- the cascade --------------------------------------------------------------

  connectCascade() {
    const slides = this.slideTargets
    const marked = slides.findIndex((slide) => slide.hasAttribute("data-current"))
    this.active = marked >= 0 ? marked : 0
    this.opened = this.active
    // A #fragment inside a slide opens on that slide.
    const hash = window.location?.hash
    if (hash && hash.length > 1) {
      let target = null
      try { target = document.getElementById(decodeURIComponent(hash.slice(1))) } catch { target = null }
      const index = target ? slides.findIndex((slide) => slide.contains(target)) : -1
      if (index >= 0) this.active = index
    }
    this.cascadeListeners = [
      ["pointerdown", (event) => this.dragStart(event)],
      ["pointermove", (event) => this.dragMove(event)],
      ["pointerup", (event) => this.dragEnd(event)],
      ["pointercancel", () => { this.pressed = null; this.dragCancel() }],
      ["click", (event) => this.clickSide(event), true],
      ["focusin", (event) => this.focusSide(event)],
      ["dragstart", (event) => event.preventDefault()]
    ]
    this.cascadeListeners.forEach(([type, handler, capture]) => this.trackTarget.addEventListener(type, handler, { capture: !!capture }))
    if (typeof ResizeObserver === "function") {
      this.observer = new ResizeObserver(this.schedule)
      this.observer.observe(this.trackTarget)
    }
    this.element.setAttribute("data-carousel-ready", "")
    this.sync()
    this.startAutoplay()
  }

  disconnectCascade() {
    this.cascadeListeners?.forEach(([type, handler, capture]) => this.trackTarget.removeEventListener(type, handler, { capture: !!capture }))
    this.cascadeListeners = null
    this.dragCancel()
  }

  // The reach CSS lays out: 1 on a three-slide cascade or a narrow region, else 2.
  reach() {
    const css = parseFloat(getComputedStyle(this.trackTarget).getPropertyValue("--carousel-cascade-reach"))
    return css > 0 ? css : cascadeReach(this.element.dataset.carouselVisible)
  }

  syncCascade() {
    const total = this.slideTargets.length
    this.page = 1
    this.positions = Array.from({ length: Math.max(1, total) }, (_, index) => index)
    this.full = null
    this.active = Math.min(Math.max(0, this.active || 0), Math.max(0, total - 1))
    this.current = this.virtual = this.active
    this.element.toggleAttribute("data-carousel-static", total < 2)
    const wraps = this.loop && total > 1
    if (this.hasPrevTarget) this.prevTarget.setAttribute("aria-disabled", String(!wraps && this.active === 0))
    if (this.hasNextTarget) this.nextTarget.setAttribute("aria-disabled", String(!wraps && this.active >= total - 1))
    const steps = cascadeSteps(total, this.active, this.loop)
    const jumps = this.laid ? cascadeJumps(this.laid, steps, this.active) : steps.map(() => false)
    // A jumping slide's fade replays only if the style saw it without the mark first.
    // It may still wear the mark from its last jump (Next then Previous round the
    // seam), or have lost it earlier in this same task (move() syncs before it moves),
    // which the style never saw: drop the mark, settle the style, then set it.
    if (jumps.some(Boolean)) {
      this.slideTargets.forEach((slide, index) => { if (jumps[index]) slide.removeAttribute("data-cascade-jump") })
      void this.trackTarget.offsetWidth
    }
    this.slideTargets.forEach((slide, index) => {
      slide.setAttribute("data-cascade-step", cascadeSlot(steps[index]))
      slide.toggleAttribute("data-cascade-jump", jumps[index])
      slide.toggleAttribute("data-current", index === this.active)
    })
    this.laid = steps
    this.dotTargets.forEach((dot, index) => {
      dot.hidden = index >= total
      if (index === this.active) dot.setAttribute("aria-current", "true")
      else dot.removeAttribute("aria-current")
    })
    this.announceChange(this.active)
  }

  // THE CHANGE EVENT (studio/carousel CHANGE_EVENT): once per change of the open
  // slide, after data-current has moved, bubbling from the region.
  announceChange(index) {
    const detail = changeDetail(this.opened, index, this.slideTargets)
    if (!detail) return
    this.opened = index
    this.element.dispatchEvent(new CustomEvent(CHANGE_EVENT, { bubbles: true, detail }))
  }

  // Brings slide `index` to the front. A focused slide that leaves the window hands
  // focus to the track (a hidden slide cannot hold it), so the keys keep working.
  activate(index) {
    const total = this.slideTargets.length
    if (!(total > 0)) return
    this.active = Math.min(total - 1, Math.max(0, index))
    this.sync()
    const focused = this.slideTargets.findIndex((slide) => slide.contains(document.activeElement))
    if (focused >= 0 && Math.abs(cascadeStep(focused, this.active, total, this.loop)) > this.reach()) {
      this.trackTarget.focus({ preventScroll: true })
    }
  }

  slideAt(target) {
    const slide = target?.closest?.(".carousel-slide")
    return slide && this.trackTarget.contains(slide) ? this.slideTargets.indexOf(slide) : -1
  }

  // A press on a side slide: the click that follows brings it to the front and opens
  // nothing. The slide is read at the press, so a link whose focus already moved the
  // stack still counts as a side slide's. A click with no press (event.detail 0:
  // Enter or Space on a focused link) is read where it lands (clickedSlide), so a
  // press released off the track leaves nothing behind for Enter on the open card.
  clickSide(event) {
    if (this.dragged) {
      this.dragged = false
      event.preventDefault()
      event.stopPropagation()
      return
    }
    const index = clickedSlide(this.pressed, event.detail, this.slideAt(event.target))
    this.pressed = null
    if (index < 0 || index === this.active) return
    event.preventDefault()
    event.stopPropagation()
    this.interacted()
    this.scrollToStop(index)
  }

  // Keyboard focus in a side slide brings it to the front, so Tab moves one slide on
  // from the first slide in view (see TAB above for the slides before the window). A
  // mouse press focuses without :focus-visible and leaves the move to its click.
  focusSide(event) {
    const index = this.slideAt(event.target)
    if (index < 0 || index === this.active) return
    let keyboard = true
    try { keyboard = event.target.matches(":focus-visible") } catch { keyboard = true }
    if (!keyboard) return
    this.interacted()
    this.scrollToStop(index, { announce: false })
  }

  // A press released off the track sends no pointerup here, so its record is stale:
  // the next press of the same pointer replaces it. A second finger is ignored.
  dragStart(event) {
    if (event.button > 0 || (this.drag && this.drag.id !== event.pointerId)) return
    const index = this.slideAt(event.target)
    this.pressed = index >= 0 && index !== this.active ? index : null
    this.dragged = false
    this.drag = { id: event.pointerId, x: event.clientX, y: event.clientY, live: false }
  }

  dragMove(event) {
    const drag = this.drag
    if (!drag || event.pointerId !== drag.id) return
    const dx = event.clientX - drag.x
    if (!drag.live) {
      if (Math.abs(dx) < 8 || Math.abs(dx) < Math.abs(event.clientY - drag.y)) return
      drag.live = true
      // Captured only once it is a drag, so a plain click still lands on its link.
      try { this.trackTarget.setPointerCapture(drag.id) } catch { /* the pointer is gone */ }
      this.element.setAttribute("data-carousel-dragging", "")
    }
    this.trackTarget.style.setProperty("--carousel-cascade-drag", `${Math.round(dx * 0.35)}px`)
  }

  dragEnd(event) {
    const drag = this.drag
    if (!drag || event.pointerId !== drag.id) return
    const live = drag.live
    this.dragCancel()
    if (!live) return
    const by = dragSteps(event.clientX - drag.x, this.stepWidth())
    this.pressed = null
    this.dragged = true
    // The click a drag ends in is swallowed by clickSide; a touch drag fires none.
    setTimeout(() => { this.dragged = false }, 0)
    if (by === 0) return
    this.interacted()
    const total = this.slideTargets.length
    const to = cascadeTarget(this.active, by, total, this.loop)
    if (to !== this.active) this.scrollToStop(to)
  }

  dragCancel() {
    this.drag = null
    this.element?.removeAttribute("data-carousel-dragging")
    this.trackTarget?.style.removeProperty("--carousel-cascade-drag")
  }

  // The width a drag crosses per step: the open slide's, or a fifth of the row.
  stepWidth() {
    const open = this.slideTargets[this.active]
    const width = open ? open.getBoundingClientRect().width : 0
    return width > 0 ? width * 0.6 : this.trackTarget.clientWidth / 5
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
    if (this.cascade) this.disconnectCascade()
    this.trackTarget.removeEventListener("scroll", this.schedule)
    this.rest?.stop()
    this.rest = null
    this.trackTarget.removeEventListener("click", this.clickClone)
    this.observer?.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
    this.frame = null
    this.stopAutoplay()
    this.removeClones()
  }

  // -- the loop's clones ------------------------------------------------------

  // Copies the slides round the seam either side, and holds the row where it was:
  // the scroll moves by the width the clones added before the first slide.
  addClones() {
    this.cloned = 0
    if (!this.loop) return
    const slides = this.slideTargets
    const perView = parseFloat(getComputedStyle(this.element).getPropertyValue("--carousel-per-view"))
    const { before, after } = cloneLayout(slides.length, cloneCount(perView, slides.length))
    if (before.length === 0) return

    const track = this.trackTarget
    const first = slides[0]
    const left = track.scrollLeft
    const was = first.offsetLeft
    first.before(...before.map((index) => this.cloneOf(slides[index])))
    slides[slides.length - 1].after(...after.map((index) => this.cloneOf(slides[index])))
    this.cloned = before.length
    track.scrollTo({ left: left + first.offsetLeft - was, behavior: "instant" })
  }

  cloneOf(slide) {
    const clone = slide.cloneNode(true)
    for (const node of [clone, ...clone.querySelectorAll("*")]) {
      for (const { name } of [...node.attributes]) if (CLONE_STRIP.test(name)) node.removeAttribute(name)
    }
    for (const name of ["role", "aria-roledescription", "aria-label"]) clone.removeAttribute(name)
    clone.setAttribute("aria-hidden", "true")
    clone.setAttribute("inert", "")
    clone.setAttribute("data-carousel-clone", "")
    return clone
  }

  removeClones() {
    this.trackTarget.querySelectorAll(":scope > [data-carousel-clone]").forEach((clone) => clone.remove())
    this.cloned = 0
  }

  // Every slide in row order, the clones included.
  rowSlides() {
    return this.cloned ? [...this.trackTarget.querySelectorAll(":scope > .carousel-slide")] : this.slideTargets
  }

  // The row came to rest. On a clone it jumps to the real slide the clone copies,
  // at the same place in the row, so nothing on screen changes.
  settle() {
    if (!this.cloned) return
    this.sync()
    const real = seamJump(this.virtual, this.positions.length)
    if (real === null) return
    const at = this.full[this.virtual + this.cloned]
    if (Math.abs(this.trackTarget.scrollLeft - at) > TOLERANCE) return
    this.element.setAttribute("data-carousel-wrapping", "")
    this.trackTarget.scrollTo({ left: this.positions[real], behavior: "instant" })
    this.sync()
    void this.trackTarget.offsetWidth
    requestAnimationFrame(() => this.element.removeAttribute("data-carousel-wrapping"))
  }

  // An inert clone takes no click, so the click lands on the track: a click on a
  // clone's box moves the row to it.
  clickClone(event) {
    if (!this.cloned || event.target !== this.trackTarget) return
    const index = this.rowSlides().findIndex((slide) => {
      if (!slide.hasAttribute("data-carousel-clone")) return false
      const box = slide.getBoundingClientRect()
      return event.clientX >= box.left && event.clientX <= box.right && event.clientY >= box.top && event.clientY <= box.bottom
    })
    if (index < 0) return
    this.interacted()
    this.sync()
    this.scrollToStop(index - this.cloned)
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
    const to = this.cloned ? loopStop("next", this.virtual, 1, count, this.cloned) : autoplayStop(this.current, count, this.loop)
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

  // The stops of every slide in the row. A cloned row measures its clones too, and
  // every slide of it is a stop: the row never ends.
  measure() {
    const track = this.trackTarget
    const slides = this.rowSlides()
    if (this.element.classList.contains("carousel-spotlight")) {
      const max = Math.max(0, track.scrollWidth - track.clientWidth)
      const boxes = slides.map((slide) => ({ left: slide.offsetLeft, width: slide.offsetWidth }))
      return { positions: centerStops(boxes, track.clientWidth, max), page: 1 }
    }
    const origin = slides[0]?.offsetLeft || 0
    const max = Math.max(0, track.scrollWidth - track.clientWidth)
    const gap = parseFloat(getComputedStyle(track).columnGap) || 0
    if (this.cloned) {
      return {
        positions: slides.map((slide) => Math.min(max, Math.max(0, slide.offsetLeft - origin))),
        page: perPage(track.clientWidth, slides[0]?.offsetWidth, gap)
      }
    }
    return {
      positions: stops(slides.map((slide) => slide.offsetLeft - origin), max),
      page: perPage(track.clientWidth, slides[0]?.offsetWidth, gap)
    }
  }

  sync() {
    if (this.cascade) {
      this.syncCascade()
      return
    }
    const track = this.trackTarget
    const { positions, page } = this.measure()
    const ends = hiddenEnds(track)

    this.page = page
    if (this.cloned) {
      // positions holds every slide, clones included; this.positions the real ones.
      const total = this.slideTargets.length
      this.full = positions
      this.virtual = currentStop(track.scrollLeft, positions) - this.cloned
      this.current = wrapIndex(this.virtual, total)
      this.positions = positions.slice(this.cloned, this.cloned + total)
    } else {
      this.full = null
      this.positions = positions
      this.current = currentStop(track.scrollLeft, positions)
      this.virtual = this.current
    }

    this.element.toggleAttribute("data-carousel-static", this.positions.length < 2)
    track.toggleAttribute("data-fade-start", ends.start)
    track.toggleAttribute("data-fade-end", ends.end)
    // A looping row never disables an arrow: each end leads round to the other.
    const wraps = this.loop && this.positions.length > 1
    if (this.hasPrevTarget) this.prevTarget.setAttribute("aria-disabled", String(!wraps && !ends.start))
    if (this.hasNextTarget) this.nextTarget.setAttribute("aria-disabled", String(!wraps && !ends.end))
    if (this.element.classList.contains("carousel-spotlight")) {
      // A clone is marked as a real slide is, so the fallback scales it the same.
      const at = this.virtual + this.cloned
      this.rowSlides().forEach((slide, index) => slide.toggleAttribute("data-current", index === at))
    }
    this.dotTargets.forEach((dot, index) => {
      dot.hidden = index >= this.positions.length
      if (index === this.current) dot.setAttribute("aria-current", "true")
      else dot.removeAttribute("aria-current")
    })
    // A looping row resting on a copy is on its way home (settle): it announces the
    // real slide once it lands there, so the slide the event names carries the mark.
    if (!this.cloned || this.virtual === this.current) this.announceChange(this.current)
  }

  prev() { this.move("prev") }

  next() { this.move("next") }

  goTo(event) {
    this.interacted()
    this.sync()
    const index = Number(event.currentTarget.dataset.carouselIndex)
    this.scrollToStop(this.cloned ? nearestVirtual(index, this.virtual, this.positions.length, this.cloned) : index)
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
    if (this.cloned) {
      const to = loopStop(action, this.virtual, this.page, this.positions.length, this.cloned)
      if (to === this.virtual) return
      this.scrollToStop(to)
      return
    }
    const to = targetStop(action, this.current, this.page, this.positions.length, this.loop)
    if (to === this.current) return
    this.scrollToStop(to)
  }

  // announce: false for autoplay, which moves the row without a word. On a cloned
  // row the index is virtual: a clone's place glides there and settle() jumps home,
  // but under reduced motion the row goes straight to the real slide.
  scrollToStop(index, { announce = true } = {}) {
    if (this.cascade) {
      if (!(index >= 0 && index < this.slideTargets.length)) return
      this.activate(index)
      if (announce && this.hasStatusTarget) this.statusTarget.textContent = positionText(index, 1, this.slideTargets.length)
      return
    }
    const reduce = window.matchMedia?.(REDUCE).matches
    if (this.cloned) {
      const total = this.positions.length
      const real = wrapIndex(index, total)
      const left = reduce ? this.positions[real] : this.full[index + this.cloned]
      if (left === undefined) return
      this.rest?.aimed()
      this.trackTarget.scrollTo({ left, behavior: reduce ? "auto" : "smooth" })
      if (announce && this.hasStatusTarget) this.statusTarget.textContent = loopPositionText(real, this.page, total)
      return
    }

    const left = this.positions[index]
    if (left === undefined) return

    this.trackTarget.scrollTo({ left, behavior: reduce ? "auto" : "smooth" })

    if (!announce || !this.hasStatusTarget) return
    const total = this.slideTargets.length
    const last = index === this.positions.length - 1
    const first = last ? Math.max(0, total - this.page) : index
    this.statusTarget.textContent = positionText(first, this.page, total)
  }
}
