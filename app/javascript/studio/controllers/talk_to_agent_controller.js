// talk-to-agent: the talk-to-agent modal (studio/agent_chat/_talk_modal), on the
// engine's Stimulus application (studio/stimulus registers it lazily, the first
// time a page renders the modal). It sits on the partial's wrapper:
//
//   <div data-studio-controller="talk-to-agent" data-talk-to-agent-soul="alex" ...>
//
// The click handling and the panel fill are studio/talk_to_agent.
import { Controller } from "@hotwired/stimulus"
import { mountTalkToAgent } from "studio/talk_to_agent"

export default class extends Controller {
  connect() {
    this.talk = mountTalkToAgent(this.element)
  }

  disconnect() {
    if (this.talk) this.talk.destroy()
    this.talk = null
  }
}
