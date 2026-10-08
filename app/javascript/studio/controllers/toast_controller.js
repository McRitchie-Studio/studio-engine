// toast: the toast root's lifetime, on the engine's Stimulus application
// (studio/application, which reads data-studio-controller). It sits on the
// root of layouts/studio/_flash:
//
//   <div x-data data-studio-controller="toast"
//        data-toast-initial-value='[{"type":"notice","message":"Saved"}]'>
//
// The queue is studio/toast ($store.toasts), which also seeds a rendered root
// on a full load and on turbo:load. connect() seeds this root too, for markup
// that arrived any other way; an element is seeded once. disconnect() empties
// the queue when the root leaves the page with no other root left to show it.
// Registered by studio/application.
import { Controller } from "@hotwired/stimulus"
import { seedToasts, TOAST_ROOT } from "studio/toast"

export default class extends Controller {
  connect() {
    seedToasts(this.element, { win: window })
  }

  disconnect() {
    if (document.querySelector(TOAST_ROOT)) return
    const store = window.Alpine && window.Alpine.store("toasts")
    if (store && typeof store.clear === "function") store.clear()
  }
}
