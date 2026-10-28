# frozen_string_literal: true

module Studio
  # The shared agent chat's proxy (docs/AGENT_CHAT.md). The browser talks only
  # to its own app; this controller forwards its two calls to the hub through
  # Studio::AgentChat:
  #
  #   POST /agent_chat/messages  soul, text         -> 201 {turn}
  #   GET  /agent_chat/turns     soul, after, limit -> 200 {turns, pending}
  #
  # Drawn by Studio.routes only for an app that names a soul
  # (Studio.agent_chat_souls).
  #
  # WHAT THE BROWSER MAY CHOOSE, AND WHAT IT MAY NOT:
  #
  #   soul    only from the app's allow-list (Studio.agent_chat_souls); off the
  #           list, or absent when the list holds more than one, is a 404. The
  #           hub re-checks that this app may address it.
  #   person  never. A signed-in visitor is current_user.email; a signed-out
  #           one is a random token in a SIGNED, http-only cookie
  #           (ANON_COOKIE), minted on the first message. A browser cannot name
  #           another person's email or forge another's token. A signed-in POST
  #           that still holds the cookie sends both, so the hub folds the
  #           anonymous thread into the person's; the cookie is then deleted.
  #   ip      never: request.remote_ip, which the hub caps on.
  #
  # The host's ApplicationController is the base, so its session, current_user
  # and CSRF protection hold: the POST must carry the page's authenticity token
  # (the composer's form does; the script sends it as X-CSRF-Token). Sign-in is
  # skipped: a signed-out visitor may chat, as on /build.
  #
  # Every answer is JSON and no-store. A hub that is down, slow or misconfigured
  # is a 503 {error, retry: true}, which the page shows as a friendly retry, and
  # a failed send or a refused app credential is an ErrorLog row (#capture).
  class AgentChatsController < ::ApplicationController
    skip_before_action :require_authentication, raise: false
    protect_from_forgery with: :exception

    ANON_COOKIE = :studio_agent_chat_anon
    ANON_TTL = 1.year
    UNAVAILABLE = "Can't reach the chat right now. Try again in a moment."

    before_action :no_store
    before_action :resolve_soul

    def create
      text = params[:text].to_s.strip
      return render_error("Write a message first.", :unprocessable_entity) if text.empty?
      if text.length > Studio::AgentChat::MAX_TEXT_LENGTH
        return render_error("That message is too long (#{Studio::AgentChat::MAX_TEXT_LENGTH} characters at most).",
                            :unprocessable_entity)
      end

      who = person(mint: true, fold: true)
      turn = Studio::AgentChat.post_message(soul: @soul, text: text, person: who, ip: request.remote_ip)
      # A signed-in post that carried the anon token has folded that thread into
      # the person's: the token is spent. Kept on any failure, for the retry.
      cookies.delete(ANON_COOKIE) if who.key?(:email) && who.key?(:anon_token)
      render json: { turn: turn }, status: :created
    rescue Studio::AgentChat::Error => e
      render_hub_error(e)
    end

    def turns
      who = person(mint: false)
      # A visitor who has never sent a message has no thread; the hub need not be asked.
      return render(json: { turns: [], pending: false }) unless who

      after = params[:after].to_s.presence
      after = nil if after && !after.match?(/\A[\w-]{1,64}\z/)
      limit = params[:limit].presence&.to_i || Studio::AgentChat::MAX_LIMIT
      render json: Studio::AgentChat.turns(soul: @soul, person: who, after: after, limit: limit)
    rescue Studio::AgentChat::Error => e
      render_hub_error(e)
    end

    private

    def no_store
      response.headers["Cache-Control"] = "no-store"
    end

    def resolve_soul
      souls = Studio.agent_chat_soul_list
      asked = params[:soul].to_s.strip
      @soul = if asked.empty? then (souls.one? ? souls.first : nil)
              else souls.find { |soul| soul == asked }
              end
      render_error("No chat here.", :not_found) unless @soul
    end

    # {email:} when signed in, else {anon_token:} from the signed cookie. With
    # mint: false a visitor with no cookie is nil.
    #
    # THE FOLD. With fold: true (the POST) a signed-in visitor who still holds
    # a valid anon cookie is {email:, anon_token:}: the hub folds the anonymous
    # thread into the person's, and #create then deletes the cookie. A
    # signed-in visitor is never minted a token, and GET /turns sends the email
    # alone (the fold is the hub's job on a post).
    def person(mint:, fold: false)
      user = respond_to?(:current_user, true) ? current_user : nil
      email = user.respond_to?(:email) ? user.email.to_s.strip : ""
      token = anon_token
      if email.present?
        return fold && token ? { email: email, anon_token: token } : { email: email }
      end
      return { anon_token: token } if token
      return nil unless mint

      token = SecureRandom.urlsafe_base64(32)
      cookies.signed[ANON_COOKIE] = {
        value: token, expires: ANON_TTL.from_now, httponly: true, same_site: :lax,
        secure: request.ssl?
      }
      { anon_token: token }
    end

    # The token in the signed anon cookie, or nil when there is none or it is
    # not one this app minted.
    def anon_token
      token = cookies.signed[ANON_COOKIE].to_s
      token.match?(/\A[A-Za-z0-9_-]{32,64}\z/) ? token : nil
    end

    def render_hub_error(error)
      case error
      when Studio::AgentChat::Invalid then render_error(error.message, :unprocessable_entity)
      when Studio::AgentChat::Capped
        response.headers["Retry-After"] = error.retry_after.to_s if error.retry_after
        render_error("You've sent a lot of messages. Wait a little, then try again.", :too_many_requests,
                     retry_after: error.retry_after)
      when Studio::AgentChat::UnknownSoul then render_error("No chat here.", :not_found)
      else
        Rails.logger.warn("[studio] agent chat: #{error.class}: #{error.message}")
        capture(error) if error.is_a?(Studio::AgentChat::Unauthorized) || action_name == "create"
        render_error(UNAVAILABLE, :service_unavailable, retry: true)
      end
    end

    # An ErrorLog row for a message that could not be sent, and for every
    # refusal of the app's own credential (a configuration fault). A poll that
    # fails is only logged: an open page polls every 15 seconds while the hub is
    # down, and a row per poll would bury the outage it reports. Never raises.
    def capture(error)
      ::ErrorLog.capture!(error) if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
    rescue StandardError
      nil
    end

    def render_error(message, status, **extra)
      render json: { error: message, **extra }, status: status
    end
  end
end
