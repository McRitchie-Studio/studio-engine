// agent-chat-voice: hold to talk in the shared agent chat's composer
// (studio/agent_chat/_voice), on the engine's Stimulus application (studio/stimulus
// registers it lazily, the first time a page renders the mic). The take's journey
// is studio/agent_chat_voice.
import { Controller } from "@hotwired/stimulus"
import { mountAgentChatVoice } from "studio/agent_chat_voice"

export default class extends Controller {
  connect() {
    this.voice = mountAgentChatVoice(this.element)
  }

  disconnect() {
    if (this.voice) this.voice.destroy()
    this.voice = null
  }
}
