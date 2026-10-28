// agent-chat: the shared agent chat (studio/agent_chat/_chat), on the engine's
// Stimulus application (studio/stimulus registers it lazily, the first time a
// page renders a chat). It sits on the chat's section:
//
//   <section data-studio-controller="agent-chat" data-agent-chat-soul="alex" ...>
//
// The loading, polling, sending and following are studio/agent_chat.
import { Controller } from "@hotwired/stimulus"
import { mountAgentChat } from "studio/agent_chat"

export default class extends Controller {
  connect() {
    this.chat = mountAgentChat(this.element)
  }

  disconnect() {
    if (this.chat) this.chat.destroy()
    this.chat = null
  }
}
