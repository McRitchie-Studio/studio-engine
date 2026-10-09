// hold-button: one hold-to-confirm button, on the engine's Stimulus application
// (studio/stimulus, which reads data-studio-controller and imports this
// controller statically, so it arrives with the page). It sits on the
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
import { Controller } from "@hotwired/stimulus"
import { Hold, mountPortal } from "studio/hold_button"
import { holdHooks } from "studio/hold_button_hooks"

const NUDGES = ["hold-nudge", "hold-nudge-soft"]

// What a connected stack carries. The guard in the head
// (studio/_hold_button_guard) marks a stack that never gets it as unavailable,
// and takes that mark back here when the controller connects late.
const CONNECTED = "data-hold-button-connected"

export default class extends Controller {
  connect() {
    this.element.setAttribute(CONNECTED, "")
    if (window.studioHoldButtonGuard) window.studioHoldButtonGuard.clear(this.element)

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
    this.element.removeAttribute(CONNECTED)
    if (!this.hold) return
    this.hold.stop()
    this.hold = null
    this.button.removeEventListener("animationend", this.clearNudge)
    // The portal notices its stack leaving by itself (studio/hold_button).
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
