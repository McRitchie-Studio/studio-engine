# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "securerandom"
require "stringio"
require "timeout"
require "uri"

# Understand: one finished take (the recorder's blob and its mime type, plus the
# speaker embedding the browser made of it) becomes {text, speaker, score}.
#
# The server half of the voice layer (docs/VOICE_TRANSCRIPTION.md). The capture
# half (docs/VOICE_CAPTURE.md) hands the page a take; the page posts it here,
# through Studio::VoiceTakesController (POST /voice/takes) or by calling
# Studio::VoiceTranscription.hear itself.
#
#   heard = Studio::VoiceTranscription.hear(audio: io, mime_type: "audio/webm",
#                                           user: current_user,
#                                           embedding: vector, model: model_id)
#   heard.to_h  # => {"text"=>"...", "speaker"=>"Pat Studio", "score"=>0.88,
#               #     "identified"=>true, "check"=>"matched"}
#
# MOCK-FIRST, as Voicebox runs it (config/initializers/voicebox.rb, Adapters):
# the transcriber is chosen by name, production defaults to the real one and
# everywhere else to the mock, and a real adapter raises LiveCallAttempted
# before it opens a socket while VOICE_NO_LIVE_CALLS is armed (always, in a test
# environment). Ported from Voicebox's Transcription::OpenAI and
# Transcription::Mock.
#
# WHO SPOKE is Studio::VoiceMatch against the SIGNED-IN USER'S OWN saved voice
# (users.voice_embedding), compared only when both vectors came from the same
# embedder revision. Named people without an account are a later card.
#
# NOTHING IS KEPT. The audio is read once, sent to the transcriber and dropped;
# no vector or audio is logged (the engine's parameter filter masks
# voice[embedding] and voice[audio]). Pure Ruby apart from the optional Rails
# logger and environment, so the unit suite runs it without an app.
module Studio
  module VoiceTranscription
    # A transcriber call that failed.
    class Error < StandardError; end

    # The vendor failed. The status rides along (0 when nothing answered) with a
    # reason code, so a caller can tell an auth failure from a model that fell
    # over. The message names only the model, the status and the reason, never
    # the vendor's own words: it reaches ErrorLog, and a vendor's error text can
    # echo what it was sent.
    class HttpError < Error
      # Why, as a code: unauthorized (401/403), rate_limited (429),
      # server_error (5xx), rejected (another non-2xx), timeout (the deadline
      # ran out), unreachable (no answer: refused, reset, DNS, TLS).
      REASONS = %w[unauthorized rate_limited server_error rejected timeout unreachable].freeze

      attr_reader :status, :reason

      def initialize(message, status:, reason: nil)
        super(message)
        @status = status
        @reason = reason || self.class.reason_for(status)
      end

      def self.reason_for(status)
        case status.to_i
        when 401, 403 then "unauthorized"
        when 429 then "rate_limited"
        when 500..599 then "server_error"
        when 0 then "unreachable"
        else "rejected"
        end
      end
    end

    # A real transcriber chosen without its credential, or a name that is no
    # adapter. The page shows NOT_CONFIGURED_MESSAGE; the cause is in the log.
    class NotConfigured < Error; end

    # DELIBERATELY OUTSIDE StandardError (Voicebox's Adapters::LiveCallAttempted):
    # every caller turns a StandardError into a friendly failure, so a trap that
    # was one would be swallowed by the code it guards and a test that reached
    # a real vendor would pass quietly.
    class LiveCallAttempted < Exception; end # rubocop:disable Lint/InheritException

    NO_LIVE_CALLS_ENV = "VOICE_NO_LIVE_CALLS"
    TRANSCRIBER_ENV = "STUDIO_VOICE_TRANSCRIBER"
    # Voice's own key. Deliberately NOT the app's shared OPENAI_API_KEY.
    API_KEY_ENV = "STUDIO_VOICE_OPENAI_API_KEY"

    # What a page shows when the app has no transcriber key. Says what is wrong
    # without naming the variable to a visitor.
    NOT_CONFIGURED_MESSAGE = "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now."

    # The bounds on one take. The recorder stops itself at 60 seconds by default
    # (studio/voice_recorder max_ms); a minute of opus is about half a megabyte,
    # so 10 MB is far above any honest take and well under the vendor's 25 MB.
    MAX_BYTES = 10 * 1024 * 1024
    MAX_DURATION_MS = 120_000

    # The audio types a take may be, as MediaRecorder names them (without the
    # ";codecs=" parameter), and the extension the vendor reads the format from.
    EXTENSIONS = {
      "audio/webm" => "webm",
      "video/webm" => "webm",
      "audio/ogg" => "ogg",
      "audio/mp4" => "mp4",
      "audio/m4a" => "m4a",
      "audio/x-m4a" => "m4a",
      "audio/mpeg" => "mp3",
      "audio/wav" => "wav",
      "audio/x-wav" => "wav"
    }.freeze

    # The label a take gets when it is not the signed-in user's saved voice. The
    # agent is told, and the message still sends (epic default).
    SOMEONE_NEW = "Someone new"

    # Why the speaker is (or is not) named, in Heard#check:
    #   matched            the user's own voice, at or above VoiceMatch::THRESHOLD
    #   below_threshold    compared, and the closest score fell short
    #   no_profile         the user has no saved voice to compare with
    #   embedder_mismatch  the take and the saved voice came from different
    #                      embedders or revisions, so they were not compared
    #   no_embedding       the take carried no usable speaker embedding
    CHECKS = %w[matched below_threshold no_profile embedder_mismatch no_embedding].freeze

    # Languages written in the Latin alphabet (Voicebox's RecordingPipeline).
    LATIN_LANGUAGES = %w[en es fr de it pt nl].freeze
    # What speech models write for silence, whole, lowercased, unpunctuated.
    SILENCE_PHRASES = [
      "thank you", "thanks", "thank you for watching", "thanks for watching",
      "thank you for listening", "thanks for listening", "bye", "bye bye", "you"
    ].freeze
    FILLERS = %w[um umm uh uhh hmm mm mhm ah er erm].freeze

    Heard = Struct.new(:text, :speaker, :score, :identified, :check, keyword_init: true) do
      def identified? = identified

      def to_h
        { "text" => text, "speaker" => speaker, "score" => score, "identified" => identified, "check" => check }
      end
    end

    # The real speech-to-text: OpenAI's POST /v1/audio/transcriptions, one
    # multipart file. Ported from Voicebox's Transcription::OpenAI: the model is
    # told the language (left to guess, a model handed near-silence answers a
    # stock word in any language), and a model that fell over (a 5xx, or a 4xx
    # other than auth and 429) is retried once on the fallback from the start of
    # the audio.
    #
    # ONE DEADLINE for the whole take (Studio.voice_transcribe_deadline, 25 s):
    # both attempts share it, every socket timeout is what is left of it, and a
    # hard Timeout backs it, so a vendor that trickles bytes cannot hold a web
    # thread past it. Nothing is retried after a timeout (the deadline is spent),
    # a 429 (the account is throttled; a second model only spends more), an auth
    # failure, or no answer at all; nor with under MIN_RETRY_SECONDS left.
    class OpenAI
      ENDPOINT = "https://api.openai.com/v1/audio/transcriptions"
      # The cap on connecting, inside the deadline.
      OPEN_TIMEOUT = 10
      NO_RETRY = %w[unauthorized rate_limited timeout unreachable].freeze
      MIN_RETRY_SECONDS = 2

      # The hard backstop's exception; turned into HttpError(reason: "timeout").
      class DeadlineExceeded < Timeout::Error; end

      attr_reader :model, :fallback_model, :language, :endpoint, :deadline

      def initialize(api_key: VoiceTranscription.api_key, model: Studio.voice_transcribe_model,
                     fallback_model: Studio.voice_transcribe_fallback_model,
                     language: Studio.voice_transcribe_language, endpoint: ENDPOINT,
                     deadline: Studio.voice_transcribe_deadline)
        @api_key = api_key
        @model = model.to_s
        @fallback_model = fallback_model.to_s.strip.empty? ? nil : fallback_model.to_s
        @language = language.to_s.strip.empty? ? nil : language.to_s
        @endpoint = endpoint
        @deadline = deadline.to_f.positive? ? deadline.to_f : 25.0
      end

      def configured? = !@api_key.to_s.strip.empty?

      # io: the audio, at its start. Returns the transcript, stripped.
      def transcribe(io:, filename:, content_type:)
        raise NotConfigured, "#{API_KEY_ENV} is not set, so this app cannot transcribe voice" unless configured?

        ends_at = now + deadline
        begin
          request_text(model, io, filename, content_type, ends_at)
        rescue HttpError => e
          raise unless retry?(e, ends_at)

          VoiceTranscription.log_warn("#{model} transcription failed (HTTP #{e.status}, #{e.reason}); " \
                                      "retrying on #{fallback_model}")
          io.rewind
          request_text(fallback_model, io, filename, content_type, ends_at)
        end
      end

      def retry?(error, ends_at)
        return false if fallback_model.nil? || fallback_model == model
        return false if NO_RETRY.include?(error.reason)

        ends_at - now >= MIN_RETRY_SECONDS
      end

      # The multipart fields, apart from the socket so a test reads them.
      def form_fields(model_name, io, filename, content_type)
        fields = [
          ["file", io, { filename: filename, content_type: content_type }],
          ["model", model_name],
          ["response_format", "json"]
        ]
        fields << ["language", language] if language
        fields
      end

      # The request, built but not sent: a multipart body with a Content-Length
      # (not chunked), the bearer key, JSON accepted.
      def build_request(model_name, io, filename, content_type)
        uri = URI.parse(endpoint)
        boundary = "studio-voice-#{SecureRandom.hex(12)}"
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Accept"] = "application/json"
        request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        request.body = VoiceTranscription.multipart(form_fields(model_name, io, filename, content_type), boundary)
        request
      end

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def request_text(model_name, io, filename, content_type, ends_at)
        perform(model_name, io, filename, content_type, ends_at).fetch("text", "").to_s.strip
      end

      # The only place a socket opens, so the only place the trap sits.
      # uri.hostname, not uri.host: an IPv6 literal's host keeps its brackets
      # ("[::1]"), which neither the loopback check nor the connect reads.
      def perform(model_name, io, filename, content_type, ends_at)
        uri = URI.parse(endpoint)
        VoiceTranscription.guard_live_call!("OpenAI", host: uri.hostname)

        left = ends_at - now
        raise HttpError.new("OpenAI #{model_name} was not tried: the take's deadline ran out", status: 0, reason: "timeout") if left <= 0

        request = build_request(model_name, io, filename, content_type)
        response = Timeout.timeout(left, DeadlineExceeded) do
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: [OPEN_TIMEOUT, left].min,
                                                  read_timeout: left, write_timeout: left) do |http|
            http.request(request)
          end
        end
        interpret(response, model_name)
      rescue Timeout::Error => e
        raise HttpError.new("OpenAI #{model_name} did not answer within the take's #{deadline.round(1)} s deadline (#{e.class})",
                            status: 0, reason: "timeout")
      rescue SystemCallError, IOError, OpenSSL::SSL::SSLError, SocketError => e
        raise HttpError.new("OpenAI #{model_name} could not be reached (#{e.class})", status: 0, reason: "unreachable")
      end

      # A failure carries the status and its reason code, never the vendor's
      # words (HttpError).
      def interpret(response, model_name)
        status = response.code.to_i
        unless response.is_a?(Net::HTTPSuccess)
          reason = HttpError.reason_for(status)
          raise HttpError.new("OpenAI #{model_name} answered HTTP #{status} (#{reason})", status: status, reason: reason)
        end

        parsed = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          {}
        end
        parsed.is_a?(Hash) ? parsed : {}
      end
    end

    # The default everywhere but production: no network, a fixed sentence. A
    # test swaps the answer with Mock.reply = ->(**) { "..." } and resets with
    # Mock.reset!. It records what it was handed (sizes, never the bytes).
    class Mock
      DEFAULT_TEXT = "This is a mock transcript of your voice."

      class << self
        attr_accessor :reply
        attr_writer :calls

        def calls = (@calls ||= [])

        def reset!
          self.reply = nil
          self.calls = []
        end
      end

      def configured? = true

      def transcribe(io:, filename:, content_type:)
        bytes = io.read.to_s.bytesize
        self.class.calls << { filename: filename, content_type: content_type, bytes: bytes }
        reply = self.class.reply
        reply.nil? ? DEFAULT_TEXT : reply.call(filename: filename, content_type: content_type, bytes: bytes).to_s
      end
    end

    ADAPTERS = { "openai" => OpenAI, "mock" => Mock }.freeze

    module_function

    # The transcriber's name: Studio.voice_transcriber when the host set one,
    # else STUDIO_VOICE_TRANSCRIBER, else "openai" in production and "mock"
    # everywhere else.
    def adapter_name
      configured = Studio.voice_transcriber.to_s.strip
      return configured unless configured.empty?

      from_env = ENV[TRANSCRIBER_ENV].to_s.strip
      return from_env unless from_env.empty?

      rails_env == "production" ? "openai" : "mock"
    end

    def transcriber(name = adapter_name)
      klass = ADAPTERS.fetch(name.to_s) do
        raise NotConfigured, "Studio.voice_transcriber=#{name.inspect} names no adapter; one of: #{ADAPTERS.keys.join(', ')}"
      end
      klass.new
    end

    # Studio.voice_openai_api_key, else STUDIO_VOICE_OPENAI_API_KEY. Never the
    # app's shared OPENAI_API_KEY: voice spends on its own key and budget.
    def api_key
      key = Studio.voice_openai_api_key.to_s.strip
      key.empty? ? ENV[API_KEY_ENV].to_s.strip : key
    end

    # Armed when VOICE_NO_LIVE_CALLS=1, and in any Rails test environment unless
    # it is set to 0. A call to this machine (a stub server) is not live.
    def live_calls_blocked?
      flag = ENV[NO_LIVE_CALLS_ENV].to_s.strip
      return true if flag == "1"
      return false if flag == "0"

      rails_env == "test"
    end

    # This machine. host is URI#hostname, so IPv6 arrives unbracketed.
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze

    def guard_live_call!(vendor, host:)
      return unless live_calls_blocked?
      return if LOOPBACK_HOSTS.include?(host.to_s)

      raise LiveCallAttempted, "A live #{vendor} call was attempted with #{NO_LIVE_CALLS_ENV} armed. " \
                               "Tests drive the mock transcriber (Studio.voice_transcriber = \"mock\")."
    end

    # "audio/webm;codecs=opus" -> "audio/webm"; nil for a type a take cannot be.
    def mime_type(raw)
      base = raw.to_s.split(";").first.to_s.strip.downcase
      EXTENSIONS.key?(base) ? base : nil
    end

    def filename_for(mime)
      "take.#{EXTENSIONS.fetch(mime_type(mime) || 'audio/webm')}"
    end

    # Why `text` cannot be what someone said, or nil when it can (Voicebox's
    # RecordingPipeline.no_speech_reason): a model handed near-silence writes a
    # stock phrase, a filler, or a word in another alphabet.
    def no_speech_reason(text, language: Studio.voice_transcribe_language)
      text = text.to_s.strip
      return "the transcript was empty" if text.empty?
      if LATIN_LANGUAGES.include?(language.to_s) && !text.match?(/\p{Latin}/)
        return "the transcript has no #{language} letters, so the model was guessing"
      end

      words = text.scan(/[\p{L}\p{N}']+/)
      return "the transcript has no words" if words.empty?
      return "the transcript is a stock phrase speech models write for silence" if SILENCE_PHRASES.include?(words.join(" ").downcase)
      return "the transcript is only a filler (#{words.first})" if words.size == 1 && FILLERS.include?(words.first.downcase)

      nil
    end

    # One take, understood. audio: an IO (or String) of the take's bytes;
    # mime_type: the recorder's mimeType; user: the signed-in user (or nil);
    # embedding: the take's speaker vector from the browser (Array or JSON
    # String), model: the embedder id that made it. Raises NotConfigured,
    # HttpError, ArgumentError (a type a take cannot be); never logs the audio
    # or the vector.
    def hear(audio:, mime_type:, user:, embedding: nil, model: nil, transcriber: self.transcriber)
      mime = self.mime_type(mime_type)
      raise ArgumentError, "unsupported audio type #{mime_type.to_s[0, 60].inspect}" if mime.nil?

      io = audio.is_a?(String) ? StringIO.new(audio) : audio
      text = transcriber.transcribe(io: io, filename: filename_for(mime), content_type: mime).to_s.strip
      speaker, score, check = who_spoke(user, embedding, model)
      Heard.new(text: text, speaker: speaker, score: score, identified: check == "matched", check: check)
    end

    # [speaker label, score or nil, check] for one take against the user's own
    # saved voice. Same embedder revision only: the take's model must be the
    # app's embedder (Studio.voice_embedder) AND the one the user's voice was
    # saved with.
    def who_spoke(user, embedding, model)
      embedder = Studio.voice_embedder.to_s
      probe = embedding.nil? ? nil : Studio::VoiceMatch.parse(embedding, size: Studio::VoiceMatch.size(embedder))
      probe = nil if probe && Studio::VoiceMatch.normalize(probe).nil?
      return [SOMEONE_NEW, nil, "no_embedding"] if probe.nil?

      saved_model = user.respond_to?(:voice_embedding_model) ? user.voice_embedding_model.to_s : ""
      saved = user.respond_to?(:voice_embedding) ? Studio::VoiceMatch.vector(user.voice_embedding) : nil
      return [SOMEONE_NEW, nil, "no_profile"] if saved.nil? || saved_model.empty?

      app_model = Studio::VoiceMatch.model_id(embedder)
      return [SOMEONE_NEW, nil, "embedder_mismatch"] unless model.to_s == app_model && saved_model == app_model

      result = Studio::VoiceMatch.match(probe, among: [user], model: app_model)
      return [SOMEONE_NEW, nil, "embedder_mismatch"] if result.score.nil?
      return [SOMEONE_NEW, result.score, "below_threshold"] if result.unknown?

      [speaker_name(user), result.score, "matched"]
    end

    def speaker_name(user)
      %i[display_name name email].each do |attr|
        next unless user.respond_to?(attr)

        value = user.public_send(attr).to_s.strip
        return value unless value.empty?
      end
      "You"
    end

    # A multipart/form-data body. fields: [name, value] or [name, io, {filename:, content_type:}].
    def multipart(fields, boundary)
      body = +"".b
      fields.each do |name, value, file|
        body << "--#{boundary}\r\n".b
        if file
          body << %(Content-Disposition: form-data; name="#{name}"; filename="#{file[:filename]}"\r\n).b
          body << "Content-Type: #{file[:content_type]}\r\n\r\n".b
          body << value.read.to_s.b
        else
          body << %(Content-Disposition: form-data; name="#{name}"\r\n\r\n).b
          body << value.to_s.b
        end
        body << "\r\n".b
      end
      body << "--#{boundary}--\r\n".b
      body
    end

    def rails_env
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:env)

      ::Rails.env.to_s
    end

    def log_warn(message)
      logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
      logger&.warn("[studio][voice] #{message}")
    end
  end
end
