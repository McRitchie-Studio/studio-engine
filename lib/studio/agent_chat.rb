# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "zlib"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/to_query"

module Studio
  # The hub client behind the shared agent chat (docs/AGENT_CHAT.md). An app
  # never stores a chat message: the McRitchie Studio hub holds every thread,
  # one per (person, soul), and this client is the app's server talking to it.
  # The browser only ever talks to its own app (Studio::AgentChatsController).
  #
  # THE CONTRACT (.agents/epics/agent-chat-primitive.md, "Contract"):
  #
  #   POST /api/v1/agent_chat/messages  soul, text, person, ip, voice (optional)
  #        201 {turn, voice} · 422 {error} · 429 capped · 404 soul has no web chat
  #   GET  /api/v1/agent_chat/turns     soul, person, after, limit (<= 50)
  #        200 {turns: [...], pending: bool}
  #
  # `person` is {email:} for a signed-in user, else {anon_token:}; a signed-in
  # POST that still holds the visitor's anon token sends {email:, anon_token:},
  # and the hub folds the anonymous thread into the person's. A turn is
  # {id, role: "user"|"agent", text, created_at, status} with status
  # pending|typing|answered|failed.
  #
  # `voice` marks a spoken message: {check, score, duration_ms}, what POST
  # /voice/takes answered for the take (voice_param). NEVER A NAME: the hub
  # names the speaker itself (the verified person's own name when check is
  # "matched", else "Someone new") and may answer what it kept as `voice`.
  #
  # AUTHENTICATION is the APP's own bearer credential (Studio.agent_chat_token,
  # else ENV["AGENT_CHAT_TOKEN"]), never a user's. It is sent only over TLS: a
  # plain-http hub URL is refused unless its host is this machine (a developer
  # pointing at a local hub).
  #
  # EVERY CALL IS BOUNDED: OPEN_TIMEOUT to connect and finish TLS, then
  # READ_TIMEOUT (and WRITE_TIMEOUT) per socket operation; Net::HTTP's silent
  # retry of an idempotent request is off, so a GET costs at most one wait.
  #
  # ERRORS. Every failure is a Studio::AgentChat::Error, so a caller rescues one
  # class; the subclasses say what the visitor is told:
  #
  #   Unavailable   the hub could not be reached or answered 5xx / garbage, or
  #                 the app is not configured (no token, a bad URL). "Try again."
  #   Unauthorized  401/403: the hub refused THIS APP's credential. A
  #                 configuration fault, shown to the visitor as Unavailable.
  #   UnknownSoul   404: the hub has no web chat for that soul for this app.
  #   Invalid       422: the hub refused the message; #message is its reason.
  #   Capped        429: too many messages; #retry_after is seconds, or nil.
  module AgentChat
    class Error < StandardError
      attr_reader :status

      def initialize(message = nil, status: nil)
        super(message)
        @status = status
      end
    end

    class Unavailable < Error; end
    class Unauthorized < Error; end
    class UnknownSoul < Error; end
    class Invalid < Error; end

    class Capped < Error
      attr_reader :retry_after

      def initialize(message = nil, status: 429, retry_after: nil)
        super(message, status: status)
        @retry_after = retry_after
      end
    end

    MESSAGES_PATH = "/api/v1/agent_chat/messages"
    TURNS_PATH = "/api/v1/agent_chat/turns"
    # Seconds to open the connection and finish TLS.
    OPEN_TIMEOUT = 3
    # Seconds for any one read or write once connected. A post returns as soon
    # as the hub has stored the message; the agent's answer arrives by polling.
    READ_TIMEOUT = 8
    WRITE_TIMEOUT = 8
    MAX_LIMIT = 50
    # The longest message the app forwards; the hub may refuse a shorter one.
    MAX_TEXT_LENGTH = 4_000
    # A hub answer larger than this is not a chat answer.
    MAX_BODY_BYTES = 1_048_576
    # The words beside the microphone, approved by Alex McRitchie on 2026-11-01.
    # Verbatim here and on an app's privacy page, from this one constant.
    VOICE_PRIVACY = "When you speak to an agent, your recording is sent to OpenAI to turn it " \
                    "into text, then deleted. We never keep the audio."

    # The hold-to-talk button's words per recorder state (merged over
    # Studio::VoiceCapture::RECORDER_COPY). The recorder says nothing while it
    # records: the chat's own status line says "Listening...", so the button does
    # not move under a held finger when the line appears.
    VOICE_RECORDER_COPY = {
      "idle" => { "button" => "Hold to talk" },
      "recording" => { "button" => "Let go to send", "status" => "" },
      "captured" => { "button" => "Hold to talk", "status" => "" },
      "silent" => { "button" => "Hold to talk" },
      "failed" => { "button" => "Hold to try again" },
      "denied" => { "button" => "Hold to talk" },
      "unsupported" => { "button" => "Hold to talk" }
    }.freeze

    # The microphone chip's first words (the engine's say "tap Record").
    VOICE_CHIP_COPY = {
      "prompt" => { "chip" => "Microphone: hold to talk to allow",
                    "note" => "Hold the talk button once and allow the microphone. Then you can pick one here." }
    }.freeze

    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze
    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error,
      SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error
    ].freeze

    class << self
      # Stores one message from `person` to `soul` and answers its turn (a Hash
      # with string keys). Raises a Studio::AgentChat::Error.
      #
      # `voice` marks it as spoken (voice_param). When the hub answers what it
      # kept, the returned Hash also carries it under "voice".
      def post_message(soul:, text:, person:, ip: nil, voice: nil)
        body = { soul: soul.to_s, text: text.to_s, person: person_param(person), ip: ip.to_s.presence,
                 voice: voice_param(voice) }.compact
        payload = request(:post, MESSAGES_PATH, body: body)
        turn = payload.is_a?(Hash) && payload["turn"].is_a?(Hash) ? payload["turn"] : payload
        raise Unavailable.new("the hub answered with no turn", status: 201) unless turn.is_a?(Hash)

        kept = payload["voice"] if payload.is_a?(Hash)
        kept.is_a?(Hash) ? turn.merge("voice" => kept) : turn
      end

      # The words of the chat's voice option: {"privacy", "recorder", "chip"},
      # the `overrides` (voice_copy: on studio/agent_chat/chat) over the defaults.
      # A blank privacy line is the default one: the line is never just dropped.
      def voice_copy(overrides = nil)
        words = (overrides || {}).to_h.transform_keys(&:to_s)
        {
          "privacy" => words["privacy"].presence || VOICE_PRIVACY,
          "recorder" => Studio::VoiceCapture.merge(VOICE_RECORDER_COPY, words["recorder"]),
          "chip" => Studio::VoiceCapture.merge(VOICE_CHIP_COPY, words["chip"])
        }
      end

      # What a message's `voice` may say to the hub, as the hub reads it: `check`
      # is one of the engine's own (else Invalid), `score` a cosine (-1..1, 4
      # places) or nil, `duration_ms` 1..MAX_DURATION_MS or nil. Everything else,
      # a browser-chosen name above all, stops here. nil or "" is a typed message.
      def voice_param(voice)
        return nil if voice.nil? || voice == ""

        voice = voice.to_unsafe_h if voice.respond_to?(:to_unsafe_h)
        raise Invalid.new("voice must be {check, score, duration_ms}", status: 422) unless voice.is_a?(Hash)

        voice = voice.transform_keys(&:to_s)
        check = voice["check"].to_s
        unless Studio::VoiceTranscription::CHECKS.include?(check)
          raise Invalid.new("voice.check is not one the engine answers", status: 422)
        end

        { check: check, score: voice_score(voice["score"]), duration_ms: voice_duration(voice["duration_ms"]) }
      end

      # The thread's turns after `after` (a turn id; nil for the latest), and
      # whether an answer is still pending: {"turns" => [...], "pending" => bool}.
      def turns(soul:, person:, after: nil, limit: MAX_LIMIT)
        query = { soul: soul.to_s, person: person_param(person), limit: limit.to_i.clamp(1, MAX_LIMIT) }
        query[:after] = after.to_s if after.present?
        payload = request(:get, TURNS_PATH, query: query)
        raise Unavailable.new("the hub answered with no turns", status: 200) unless payload.is_a?(Hash) && payload["turns"].is_a?(Array)

        { "turns" => payload["turns"].select { |turn| turn.is_a?(Hash) }, "pending" => payload["pending"] == true }
      end

      def hub_url = Studio.agent_chat_hub_url.to_s
      def token = Studio.agent_chat_token.presence || ENV["AGENT_CHAT_TOKEN"].presence

      private

      def voice_score(raw)
        return nil unless raw.is_a?(Numeric) || raw.is_a?(String)

        value = Float(raw, exception: false)
        value&.finite? ? value.clamp(-1.0, 1.0).round(4) : nil
      end

      def voice_duration(raw)
        value = raw.to_s.match?(/\A\d{1,9}\z/) ? raw.to_s.to_i : nil
        value&.between?(1, Studio::VoiceTranscription::MAX_DURATION_MS) ? value : nil
      end

      # {email:}, {anon_token:}, or both: a signed-in post that still holds the
      # visitor's anon token sends both, and the hub folds that anonymous thread
      # into the person's.
      def person_param(person)
        person = person.to_h.transform_keys(&:to_s)
        email = person["email"].to_s.strip
        token = person["anon_token"].to_s.strip
        raise ArgumentError, "person needs an email or an anon_token" if email.empty? && token.empty?

        { email: email.presence, anon_token: token.presence }.compact
      end

      def request(verb, path, body: nil, query: nil)
        uri = endpoint(path)
        uri.query = query.to_query if query
        credential = token || raise(Unavailable, "no AGENT_CHAT_TOKEN: the app has no agent chat credential")

        req = verb == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{credential}"
        req["Accept"] = "application/json"
        req["User-Agent"] = "studio-engine/#{Studio::VERSION} agent-chat"
        if body
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end

        response = http_for(uri).start { |http| http.request(req) }
        interpret(response)
      rescue *NETWORK_ERRORS => e
        raise Unavailable, "the hub could not be reached (#{e.class})"
      end

      def endpoint(path)
        base = URI.parse(hub_url)
        raise Unavailable, "agent_chat_hub_url is not an http(s) URL" unless base.is_a?(URI::HTTP) && base.host.present?
        if base.scheme != "https" && !LOOPBACK_HOSTS.include?(base.host)
          raise Unavailable, "agent_chat_hub_url must be https (plain http only to this machine)"
        end

        URI.join(base.to_s.end_with?("/") ? base.to_s : "#{base}/", path.delete_prefix("/"))
      rescue URI::InvalidURIError
        raise Unavailable, "agent_chat_hub_url is not a URL"
      end

      def http_for(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.write_timeout = WRITE_TIMEOUT
        http.ssl_timeout = OPEN_TIMEOUT if http.use_ssl?
        http.max_retries = 0
        http
      end

      def interpret(response)
        status = response.code.to_i
        success = status.between?(200, 299)
        payload = success ? parse(response.body) : parse_reason(response.body)
        reason = payload.is_a?(Hash) ? payload["error"].presence : nil

        case status
        when 200..299 then payload
        when 401, 403 then raise Unauthorized.new("the hub refused this app's credential (#{status})", status: status)
        when 404 then raise UnknownSoul.new(reason || "no web chat for that soul", status: status)
        when 422 then raise Invalid.new(reason || "the hub refused that message", status: status)
        when 429 then raise Capped.new(reason || "too many messages", retry_after: retry_after(response))
        else raise Unavailable.new("the hub answered #{status}", status: status)
        end
      end

      def parse(body)
        return nil if body.nil? || body.empty?
        raise Unavailable, "the hub's answer is too large" if body.bytesize > MAX_BODY_BYTES

        JSON.parse(body)
      rescue JSON::ParserError
        raise Unavailable, "the hub's answer is not JSON"
      end

      # A refusal's body, read only for its {"error"} reason; a body that is not
      # JSON (a proxy's HTML error page) is no reason.
      def parse_reason(body)
        parse(body)
      rescue Unavailable
        nil
      end

      def retry_after(response)
        value = response["Retry-After"].to_s
        value.match?(/\A\d+\z/) ? value.to_i : nil
      end
    end
  end
end
