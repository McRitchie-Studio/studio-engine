# frozen_string_literal: true

module Studio
  # The agent chat's voice option (docs/AGENT_CHAT.md, "Talking by voice").
  module AgentChatHelper
    # The signed-in user on this page, or nil. A page whose controller has no
    # current_user is a signed-out page.
    def studio_agent_chat_viewer
      respond_to?(:current_user) ? current_user : nil
    end

    # Whether this viewer gets the microphone: the app turned takes on (no route
    # otherwise) and Studio.voice_chat_allowed lets them talk. Never a signed-out
    # visitor: POST /voice/takes is sign-in only.
    def studio_agent_chat_voice?
      return false unless Studio.voice_transcription && respond_to?(:studio_voice_takes_path)

      Studio.voice_chat_allowed?(studio_agent_chat_viewer)
    end

    # The embedder the page runs on a take (Studio::VoiceMatch.browser_config),
    # as JSON, or nil. Only for a user whose saved voice came from the app's own
    # embedder: anything else answers embedder_mismatch or no_profile on the
    # server, so downloading the model would buy nothing.
    def studio_agent_chat_embedder(user)
      return nil unless user.respond_to?(:voice_embedding) && user.respond_to?(:voice_embedding_model)
      return nil if user.voice_embedding.blank?

      name = Studio.voice_embedder.to_s
      return nil unless user.voice_embedding_model.to_s == Studio::VoiceMatch.model_id(name)

      Studio::VoiceMatch.browser_config(name).to_json
    rescue ArgumentError, KeyError
      nil
    end
  end
end
