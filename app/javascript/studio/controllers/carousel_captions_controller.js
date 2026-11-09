// carousel-captions: one caption under a carousel that follows its open slide (the
// image-only pattern, README "The carousel"). A caption inside each slide would ride
// a cascade's 3D move, so the captions live outside the row: one per item, in item
// order, laid in one grid cell, and this marks the open slide's caption data-current
// and hides the rest from assistive tech (aria-hidden). The page styles the cross-fade
// (with motion-reduce:transition-none, so reduced motion swaps it at once).
//
//   <div data-studio-controller="carousel-captions">
//     <%= render layout: "studio/carousel", ... %>
//     <div data-carousel-captions-target="caption" data-current>first</div>
//     <div data-carousel-captions-target="caption" aria-hidden="true">second</div>
//   </div>
//
// ONE ROW PER WRAPPER. It follows its own row: the region marked
// data-carousel-captions-target="carousel" (pass it as the partial's data:), else the
// first carousel region inside it. A change event from any other row inside the
// wrapper moves nothing.
//
// It listens for the carousel's change event (studio/carousel CHANGE_EVENT), which
// bubbles from the region inside it, so it needs no observer and no timer. Both
// controllers load lazily (studio/stimulus), so the row may open somewhere else (a
// #fragment) and announce it before this connects: connect() reads the row's open
// slide (studio/carousel markedSlide) first, then follows the event. The server marks
// the caption of the slide the row opens on, so a page with no caption stage fetches
// nothing, and one whose controller failed keeps the server's caption.
import { Controller } from "@hotwired/stimulus"
import { CHANGE_EVENT, markedSlide } from "studio/carousel"

const REGION = ".carousel[data-studio-controller~='carousel']"

export default class extends Controller {
  static targets = ["caption", "carousel"]

  connect() {
    this.follow = (event) => {
      if (event.target === this.region()) this.show(event.detail?.index)
    }
    this.element.addEventListener(CHANGE_EVENT, this.follow)
    const region = this.region()
    if (region) this.show(markedSlide(region.querySelectorAll(":scope > .carousel-track > .carousel-slide")))
  }

  disconnect() {
    this.element.removeEventListener(CHANGE_EVENT, this.follow)
  }

  // The row these captions follow: the carousel target, else the first row inside.
  region() {
    return this.hasCarouselTarget ? this.carouselTarget : this.element.querySelector(REGION)
  }

  show(index) {
    if (!Number.isInteger(index) || index < 0 || index >= this.captionTargets.length) return
    this.captionTargets.forEach((caption, at) => {
      const open = at === index
      caption.toggleAttribute("data-current", open)
      if (open) caption.removeAttribute("aria-hidden")
      else caption.setAttribute("aria-hidden", "true")
    })
  }
}
