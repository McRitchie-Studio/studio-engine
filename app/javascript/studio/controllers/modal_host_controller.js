// modal-host: one modal host's lifetime, on the engine's Stimulus application
// (studio/application, which reads data-studio-controller). It sits on the
// host's outer <template>:
//
//   <template x-if="$store.modals.current()"
//             data-studio-controller="modal-host"
//             data-modal-host-store-value="modals">          (studio/modals/_host)
//
//   <template x-if="$store.labModals.current()"
//             data-studio-controller="modal-host"
//             data-modal-host-store-value="labModals"
//             data-modal-host-scoped-value="true">          (studio/modals/_scoped_host)
//
// The stack, the focus trap and the registries are studio/modal_host, which
// registers each host's store before Alpine starts or before a Turbo render
// (a controller connects too late for that). connect() registers the store
// only for markup that arrived some other way, and binds the bfcache and Turbo
// snapshot cleanup to this host for as long as it is on the page.
// Registered by studio/application.
import { Controller } from "@hotwired/stimulus"
import { registerModalStore, clearStaleModals } from "studio/modal_host"

export default class extends Controller {
  static values = { store: { type: String, default: "modals" }, scoped: Boolean }

  connect() {
    const name = this.storeValue
    registerModalStore(window.Alpine, { store: name, scoped: this.scopedValue }, { doc: document, win: window })

    this.onPageShow = (event) => { if (event.persisted) clearStaleModals(window, name) }
    this.onBeforeCache = () => clearStaleModals(window, name)
    window.addEventListener("pageshow", this.onPageShow)
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
  }

  disconnect() {
    window.removeEventListener("pageshow", this.onPageShow)
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
  }
}
