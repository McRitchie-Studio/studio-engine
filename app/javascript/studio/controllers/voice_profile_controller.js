// voice-profile: the voice row on /profile (studio/profiles/_voice_section), on
// the engine's Stimulus application (studio/stimulus registers it lazily, the
// first time a page renders the row). It sits on the row's wrapper:
//
//   <div data-studio-controller="voice-profile" data-voice-save-url="/profile/voice" ...>
//
// The recording, the meter, the embedding and the save are studio/voice_profile.
import { Controller } from "@hotwired/stimulus"
import { mountVoiceProfile } from "studio/voice_profile"

export default class extends Controller {
  connect() {
    this.voice = mountVoiceProfile(this.element)
  }

  disconnect() {
    if (this.voice) this.voice.destroy()
    this.voice = null
  }
}
