// hold-button: one hold-to-confirm button, on the engine's Stimulus application
// (studio/stimulus, which reads data-studio-controller and registers this
// controller lazily, the first time a page renders the button). It sits on the
// stack studio/_hold_button renders, and the button carries the presses:
//
//   <span class="hold-stack" data-studio-controller="hold-button">
//     <button class="hold-btn" data-hold-id="confirm" data-duration="2000"
//             data-studio-action="mousedown->hold-button#start mouseup->hold-button#end
//                                 mouseleave->hold-button#end touchstart->hold-button#press
//                                 touchend->hold-button#end touchcancel->hold-button#end">
//
// The timeline, the idle nudge and the fizz portal are studio/hold_button; the
// events and string locals the timeline asks are studio/hold_button_hooks.
// Until this controller registers, a press does nothing.
import { Controller } from "@hotwired/stimulus"
import { Hold, mountPortal, unmountPortal } from "studio/hold_button"
import { holdHooks } from "studio/hold_button_hooks"

const NUDGES = ["hold-nudge", "hold-nudge-soft"]

export default class extends Controller {
  connect() {
    this.button = this.element.querySelector(":scope > .hold-btn")
    if (!this.button) return

    this.hold = new Hold(this.button, holdHooks(this.button, { win: window }))
    this.clearNudge = (event) => {
      if (NUDGES.includes(event.animationName)) this.button.classList.remove("nudge", "nudge-soft")
    }
    this.button.addEventListener("animationend", this.clearNudge)
    this.hold.nudge.start()
    if (this.element.hasAttribute("data-fizz-portal")) mountPortal(this.element)
  }

  disconnect() {
    if (!this.hold) return
    this.hold.stop()
    this.hold = null
    this.button.removeEventListener("animationend", this.clearNudge)
    // A stack Turbo is about to cache has already put its box back.
    unmountPortal(this.element._fizzPortal, false)
  }

  start() {
    if (this.hold) this.hold.start()
  }

  // A touch: no synthetic mouse events, no long-press menu.
  press(event) {
    event.preventDefault()
    this.start()
  }

  end() {
    if (this.hold) this.hold.end()
  }
}
