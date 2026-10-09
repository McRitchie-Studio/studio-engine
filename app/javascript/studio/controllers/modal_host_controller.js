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
// registers each host's store on alpine:init (a full load, where a controller
// connects too late) and before a Turbo render. connect() registers it too, for
// a Turbo visit and for markup that arrived any other way. The bfcache and
// Turbo snapshot cleanup is studio/modal_host's own binding, one per document,
// so it holds when this controller never loads; binding it here as well would
// sweep each store twice. Registered by studio/application.
import { Controller } from "@hotwired/stimulus"
import { registerModalStore } from "studio/modal_host"

export default class extends Controller {
  static values = { store: { type: String, default: "modals" }, scoped: Boolean }

  connect() {
    registerModalStore(window.Alpine, { store: this.storeValue, scoped: this.scopedValue }, { doc: document, win: window })
  }
}
