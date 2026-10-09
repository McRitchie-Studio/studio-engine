// link-preview-card: the site identity manager's live card, on the engine's
// Stimulus application (studio/stimulus, which reads data-studio-controller and
// registers this controller lazily). It sits on the page's root:
//
//   <div data-link-preview-page data-studio-controller="link-preview-card"
//        data-fallback-title="..." data-fallback-description="...">
//
// The repaint is studio/link_preview_card. One listener on the root takes the
// `input` of every [data-link-preview-input] inside it.
import { Controller } from "@hotwired/stimulus"
import { paintCard } from "studio/link_preview_card"

export default class extends Controller {
  connect() {
    this.repaint = (event) => {
      const input = event.target
      if (input && input.matches && input.matches("[data-link-preview-input]")) paintCard(this.element, input)
    }
    this.element.addEventListener("input", this.repaint)
  }

  disconnect() {
    this.element.removeEventListener("input", this.repaint)
  }
}
