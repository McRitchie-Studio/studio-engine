// knowledge-transcript: a recording beside its transcript on the knowledge
// layer's document page, on the engine's Stimulus application (studio/stimulus,
// which reads data-studio-controller and registers this controller lazily). It
// sits on the transcript's wrapper, which arrives inside a lazy turbo-frame:
//
//   <div data-studio-controller="knowledge-transcript">
//     <video data-knowledge-player ...>   <ol data-knowledge-cues> ...
//
// The seeking, the marking and the following are studio/knowledge_transcript.
import { Controller } from "@hotwired/stimulus"
import { mountTranscript } from "studio/knowledge_transcript"

export default class extends Controller {
  connect() {
    this.transcript = mountTranscript(this.element)
  }

  disconnect() {
    if (this.transcript) this.transcript.destroy()
    this.transcript = null
  }
}
