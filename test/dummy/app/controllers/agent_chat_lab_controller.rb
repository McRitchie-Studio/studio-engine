# A host app's page with the shared agent chat on it, rendered the way an app
# renders it: `render "studio/agent_chat/chat", soul:, name:, portrait:` and a
# card in the card slot, inside the lab's real layout (the engine's head).
# test/integration/agent_chat_proxy_test.rb renders it and drives the proxy
# behind it against a stub hub (test/support/agent_chat_stub_hub.rb).
class AgentChatLabController < ActionController::Base
  helper E2eLabController::AssetDelivery
  layout "e2e_lab"

  def show; end
end
