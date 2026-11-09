// carousel-captions: one caption under a carousel that follows its open slide (the
// image-only pattern, README "The carousel"). A caption inside each slide would ride
// a cascade's 3D move, so the captions live outside the row: one per item, in item
// order, laid in one grid cell, and this marks the open slide's caption data-current
// and hides the rest from assistive tech (aria-hidden). The page styles the cross-fade.
//
//   <div data-studio-controller="carousel-captions">
//     <%= render layout: "studio/carousel", ... %>
//     <div data-carousel-captions-target="caption" data-current>first</div>
//     <div data-carousel-captions-target="caption" aria-hidden="true">second</div>
//   </div>
//
// It listens for the carousel's change event (studio/carousel CHANGE_EVENT), which
// bubbles from the region inside it, so it needs no observer and no timer. The server
// marks the caption of the slide the row opens on. A lazy controller (studio/stimulus):
// a page with no caption stage fetches nothing; one whose controller failed keeps the
// server's caption.
import { Controller } from "@hotwired/stimulus"
import { CHANGE_EVENT } from "studio/carousel"

export default class extends Controller {
  static targets = ["caption"]

  connect() {
    this.follow = (event) => this.show(event.detail?.index)
    this.element.addEventListener(CHANGE_EVENT, this.follow)
  }

  disconnect() {
    this.element.removeEventListener(CHANGE_EVENT, this.follow)
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
