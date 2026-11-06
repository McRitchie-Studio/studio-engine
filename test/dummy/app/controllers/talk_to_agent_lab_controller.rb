# A host page with the talk-to-agent modal on it (studio/agent_chat/_talk_modal),
# rendered the way an app renders it: the modal once, then links marked with
# studio_talk_to_agent_link. e2e/talk_to_agent.spec.js opens it against the
# stand-in hub e2e/boot.rb runs (AgentChatStubHub).
class TalkToAgentLabController < ActionController::Base
  helper E2eLabController::AssetDelivery
  helper Studio::AgentChatHelper
  layout "e2e_lab"

  def show; end
end
