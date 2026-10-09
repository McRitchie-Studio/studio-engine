// The lab's lazy controller: a page-specific controller nothing imports
// statically, for e2e/lazy_controller_failure.spec.js. e2e/boot.rb copies it to
// /e2e/js/lab_lazy_controller.js, and /lab/lazy_controller names it by a
// dynamic import, as studio/stimulus's LAZY names a real one.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.element.dataset.labLazy = "connected"
  }
}
