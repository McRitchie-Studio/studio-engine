// studio--nav-collapse: the scroll-linked navbar collapse on a <header>.
//
//   <header class="nav-shell ..." data-controller="studio--nav-collapse"
//           data-studio--nav-collapse-scrolled-class="shadow-lg is-scrolled">
//
// The behaviour is studio/nav_collapse; this controller binds it to the
// element's lifetime and toggles the `scrolled` classes when the shadow's
// hysteresis flips. Registered by studio/application.
import { Controller } from "@hotwired/stimulus"
import { NavCollapse } from "studio/nav_collapse"

export default class extends Controller {
  static classes = ["scrolled"]

  connect() {
    this.collapse = new NavCollapse(this.element, (lit) => {
      if (!this.hasScrolledClass) return
      for (const name of this.scrolledClasses) this.element.classList.toggle(name, lit)
    })
    this.collapse.start()
  }

  disconnect() {
    if (this.collapse) this.collapse.stop()
    this.collapse = null
  }
}
