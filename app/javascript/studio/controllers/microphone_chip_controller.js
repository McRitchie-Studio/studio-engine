// microphone-chip: the microphone chip (studio/voice/_microphone_chip), on the
// engine's Stimulus application (studio/stimulus registers it lazily, the
// first time a page renders a chip):
//
//   <div data-studio-controller="microphone-chip" data-microphone-copy='{...}'>
//
// The listing, the pick, the live dot and the help dialog are
// studio/microphone_chip; which device opens is studio/microphone.
import { Controller } from "@hotwired/stimulus"
import { mountMicrophoneChip } from "studio/microphone_chip"

export default class extends Controller {
  connect() {
    this.chip = mountMicrophoneChip(this.element)
  }

  disconnect() {
    if (this.chip) this.chip.destroy()
    this.chip = null
  }
}
