// voice-recorder: one record button (studio/voice/_recorder, or a page's own
// markup), on the engine's Stimulus application (studio/stimulus registers it
// lazily, the first time a page renders one):
//
//   <div data-studio-controller="voice-recorder" data-voice-recorder-mode="toggle">
//
// The take, the meter and the events are studio/voice_recorder. A page reads
// the finished audio from the studio:voice-recorder:take event; this
// controller uploads nothing. Pages that drive it from their own controls call
// the actions: data-studio-action="voice-recorder#start" (or #stop, #toggle).
import { Controller } from "@hotwired/stimulus"
import { mountVoiceRecorder } from "studio/voice_recorder"

export default class extends Controller {
  connect() {
    this.recorder = mountVoiceRecorder(this.element)
  }

  disconnect() {
    if (this.recorder) this.recorder.destroy()
    this.recorder = null
  }

  start() { if (this.recorder) this.recorder.start() }

  stop() { if (this.recorder) this.recorder.stop() }

  toggle() { if (this.recorder) this.recorder.toggle() }
}
