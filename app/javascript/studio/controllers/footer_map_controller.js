// footer-map: one live map of an address, on the engine's Stimulus application
// (studio/stimulus, which reads data-studio-controller and registers this
// controller lazily). It sits on the map element studio/site_footer/_map
// renders:
//
//   <div class="ftr-map" data-footer-map data-studio-controller="footer-map"
//        data-lat="..." data-lng="..." data-leaflet-js="..." data-leaflet-css="...">
//
// The mount is studio/footer_map, installed once per document however many maps
// connect. Until Leaflet mounts, and if it never does, the link inside the
// element is the whole map.
import { Controller } from "@hotwired/stimulus"
import { installFooterMaps } from "studio/footer_map"

export default class extends Controller {
  connect() {
    const installed = !window.__studioFooterMapsArmed
    const arm = installFooterMaps(window, document)
    // A map that arrives after the install (a stream, a second map).
    if (!installed) arm()
  }
}
