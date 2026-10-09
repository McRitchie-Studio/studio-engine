// identity-mini: the compact identity bar's lifetime, on the engine's Stimulus
// application (studio/application, which reads data-studio-controller). It sits
// on the bar studio/profiles/_identity_mini renders:
//
//   <div data-studio-identity-mini data-studio-controller="identity-mini"
//        class="studio-identity-mini" inert>
//
// and watches the page's full card ([data-studio-identity-full]). When the bar
// shows is studio/identity_mini. connect() starts the watch, on a full load
// and on a Turbo visit alike; the bar goes back to hidden and inert before
// Turbo caches the page and when it leaves it.
//
// Registered statically by studio/application: on the edit page the bar
// carries Save and Discard once the card has scrolled away, so it arrives with
// the page.
import { Controller } from "@hotwired/stimulus"
import { IdentityMini, FULL_SELECTOR } from "studio/identity_mini"

export default class extends Controller {
  connect() {
    this.bar = new IdentityMini(this.element, document.querySelector(FULL_SELECTOR), window.IntersectionObserver)
    this.bar.start()
    this.onBeforeCache = () => this.bar.reset()
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
    if (this.bar) this.bar.reset()
    this.bar = null
  }
}
