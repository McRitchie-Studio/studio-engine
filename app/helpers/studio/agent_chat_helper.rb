# frozen_string_literal: true

module Studio
  # The agent chat's voice option (docs/AGENT_CHAT.md, "Talking by voice"), and
  # the link that opens the talk-to-agent modal ("Talk to an agent in a modal").
  module AgentChatHelper
    # A link that opens studio/agent_chat/_talk_modal with `soul`, `topic` and
    # an optional `opener` (the visitor's first message; default "I'd like to
    # talk about <topic>."). `href` is where the link goes when the modal is not
    # on the page, did not load, or the click is a modified one (a new tab): a
    # real chat page, so no click is ever lost. A block replaces `label`.
    def studio_talk_to_agent_link(label = nil, href:, soul:, topic: nil, opener: nil, **options, &block)
      data = (options.delete(:data) || {}).merge(studio_talk_to_agent: true, talk_soul: soul.to_s,
                                                  talk_topic: topic.to_s.presence, talk_opener: opener.to_s.presence).compact
      options[:aria] = { haspopup: "dialog" }.merge(options[:aria] || {})
      block ? link_to(href, **options, data: data, &block) : link_to(label, href, **options, data: data)
    end

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
