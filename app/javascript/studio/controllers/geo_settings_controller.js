// geo-settings: the geo manager's live preview, on the engine's Stimulus
// application (studio/stimulus, which reads data-studio-controller and
// registers this controller lazily). It sits on the page's root:
//
//   <div data-geo-page data-studio-controller="geo-settings"
//        data-geo-home="US" data-geo-country="US" data-geo-subdivision="CO"
//        data-geo-fail-closed="true">
//
// The rules and the painting are studio/geo_settings. Any change inside the
// page repaints.
import { Controller } from "@hotwired/stimulus"
import { paintGeo } from "studio/geo_settings"

export default class extends Controller {
  connect() {
    this.paint = () => paintGeo(this.element, document)
    this.element.addEventListener("change", this.paint)
    this.paint()
  }

  disconnect() {
    this.element.removeEventListener("change", this.paint)
  }
}
