// style-modals: the living style guide's Modals section, on the engine's
// Stimulus application (studio/stimulus, which reads data-studio-controller).
// It sits on the section style/_modals renders:
//
//   <section id="modals" data-studio-controller="style-modals" x-data="{}">
//     <button data-studio-action="click->style-modals#demo"
//             data-style-modals-name-param="stackTwo">Open two</button>
//
// The demos and the simulator's controls are studio/style_modals. connect()
// installs the wallet stubs, publishes the drivers as window.dsModalDemos (for
// the console) and builds the simulator's controls from the live animation
// registry; they are built again on turbo:load, so a key registered since then
// grows a control.
//
// Registered by studio/style_guide, which the section loads by its own module
// tag, so only the style guide fetches it.
import { Controller } from "@hotwired/stimulus"
import { createModalDemos, installWalletStubs } from "studio/style_modals"

export default class extends Controller {
  static values = { store: { type: String, default: "dsModals" } }

  connect() {
    installWalletStubs(window)
    this.demos = createModalDemos({ win: window, doc: document, store: this.storeValue })
    window.dsModalDemos = this.demos
    this.build = () => this.demos.buildAnimControls()
    this.build()
    document.addEventListener("turbo:load", this.build)
  }

  disconnect() {
    document.removeEventListener("turbo:load", this.build)
  }

  // click->style-modals#demo, with the driver's name as the action's param.
  demo(event) {
    const run = this.demos && this.demos[event.params.name]
    if (typeof run === "function") run()
  }
}
