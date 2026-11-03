# frozen_string_literal: true

module Studio
  # POST /voice/takes: one recorded take in, {text, speaker, score} out
  # (docs/VOICE_TRANSCRIPTION.md). Drawn by Studio.routes only when the app
  # sets Studio.voice_transcription.
  #
  # The page posts the recorder's take (studio:voice-recorder:take) as
  # multipart/form-data:
  #
  #   voice[audio]        the blob (required, at most VoiceTranscription::MAX_BYTES)
  #   voice[mime_type]    its mimeType, e.g. "audio/webm;codecs=opus" (else the
  #                       part's own Content-Type)
  #   voice[duration_ms]  durationMs (required, 1..MAX_DURATION_MS)
  #   voice[embedding]    the take's speaker vector, JSON (optional)
  #   voice[model]        the embedder id that made it (optional)
  #
  # SIGNED-IN ONLY (the host's require_authentication: a JSON 401 otherwise),
  # CSRF-protected (send the page's token as X-CSRF-Token), JSON, no-store.
  # The speaker is matched only against the signed-in user's own saved voice.
  #
  # ALLOWED USERS ONLY (Studio.voice_chat_allowed; by default anyone signed in):
  # anyone else is a JSON 403 {error, reason: "not_allowed"}, before the rate
  # limit counts or anything is read. Hiding the microphone is not the gate; each
  # take is a paid call.
  #
  # RATE-LIMITED per user (Studio.voice_takes_rate_limit, 20 takes in 10
  # minutes): over it, a JSON 429 {error, reason: "rate_limited", retry_after}
  # and a Retry-After header, before anything is read or transcribed.
  #
  # NOTHING IS KEPT: the upload is read once, handed to the transcriber, and its
  # tempfile is deleted before the answer; no audio or vector is stored or
  # logged (voice[audio] and voice[embedding] are in the engine's parameter
  # filter).
  class VoiceTakesController < ::ApplicationController
    before_action :require_authentication
    protect_from_forgery with: :exception
    before_action :no_store
    before_action :require_voice_allowed
    before_action :limit_takes

    CANT_HEAR = "I couldn't hear any words in that. Check your microphone and try again."
    UNAVAILABLE = "I couldn't transcribe that just now. Try again in a moment."
    TOO_MANY = "That's a lot of recordings in a short time. Wait a moment, then try again."
    NOT_ALLOWED = "Voice isn't available on your account yet. Type instead for now."

    # The counter's fallback when the app's Rails.cache counts nothing (a
    # NullStore, as many apps run in development): per process, so a limit
    # still holds.
    FALLBACK_STORE = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)

    def create
      voice = params[:voice]
      # A string (voice=abc) or an array is no take: refuse it, never index it.
      voice = nil unless voice.is_a?(ActionController::Parameters)
      audio = voice ? voice[:audio] : nil
      return refuse("Record something first.") unless audio.respond_to?(:read) && audio.respond_to?(:size)

      begin
        return refuse("That recording is too long to send.", 413) if audio.size > VoiceTranscription::MAX_BYTES
        return refuse("That recording was empty.") if audio.size.zero?

        duration = voice[:duration_ms].to_s
        unless duration.match?(/\A\d{1,9}\z/) && duration.to_i.between?(1, VoiceTranscription::MAX_DURATION_MS)
          return refuse("That recording is too long, or has no length.")
        end

        mime = VoiceTranscription.mime_type(voice[:mime_type].presence ||
                                            (audio.content_type if audio.respond_to?(:content_type)))
        return refuse("That kind of recording isn't supported.", 415) if mime.nil?

        heard = VoiceTranscription.hear(audio: audio, mime_type: mime, user: current_user,
                                        embedding: voice[:embedding].presence, model: voice[:model].presence)
        reason = VoiceTranscription.no_speech_reason(heard.text)
        return refuse(CANT_HEAR, :unprocessable_entity, reason: "no_speech") if reason

        render json: heard.to_h.merge("duration_ms" => duration.to_i), status: :ok
      rescue VoiceTranscription::NotConfigured => e
        capture(e)
        refuse(VoiceTranscription::NOT_CONFIGURED_MESSAGE, :service_unavailable, reason: "not_configured")
      rescue VoiceTranscription::HttpError => e
        capture(e)
        refuse(UNAVAILABLE, :service_unavailable, reason: "transcriber_failed", retry: true)
      ensure
        discard(audio)
      end
    end

    private

    def require_voice_allowed
      refuse(NOT_ALLOWED, :forbidden, reason: "not_allowed") unless Studio.voice_chat_allowed?(current_user)
    end

    # The per-user limit, a fixed window: the window's number is in the key, so
    # its end (retry_after) is known exactly. Rails' own rate_limit macro fixes
    # to:/within: when the class loads and counts nothing on a NullStore; this
    # reads the config per request and never goes inert. It instruments the same
    # rate_limit.action_controller event.
    def limit_takes
      limit = Studio.voice_takes_rate_limit
      return unless limit && current_user

      limit = limit.to_h.transform_keys(&:to_sym)

      to = limit[:to].to_i
      within = limit[:within].to_i
      return unless to.positive? && within.positive?

      epoch = Time.now.to_i
      window = epoch / within
      key = "rate-limit:#{controller_path}:#{current_user.id}:#{window}"
      count = rate_limit_store(limit).increment(key, 1, expires_in: within)
      return if count.nil? || count <= to

      retry_after = within - (epoch % within)
      ActiveSupport::Notifications.instrument("rate_limit.action_controller",
                                              request: request, count: count, to: to, within: within,
                                              by: current_user.id, name: nil, scope: controller_path, cache_key: key) do
        response.headers["Retry-After"] = retry_after.to_s
        refuse(TOO_MANY, :too_many_requests, reason: "rate_limited", retry_after: retry_after)
      end
    end

    def rate_limit_store(limit)
      store = limit[:store] || (Rails.cache if defined?(Rails.cache))
      store.nil? || store.is_a?(ActiveSupport::Cache::NullStore) ? FALLBACK_STORE : store
    end

    def refuse(message, status = :unprocessable_entity, **extra)
      render json: { error: message, **extra }, status: status
    end

    def no_store
      response.headers["Cache-Control"] = "no-store"
    end

    # The upload's tempfile goes now, not at the next GC.
    def discard(audio)
      file = audio.respond_to?(:tempfile) ? audio.tempfile : nil
      file.close! if file.respond_to?(:close!)
    rescue StandardError
      nil
    end

    # An ErrorLog row on the user who sent the take. The error's message is the
    # engine's own words (model, status, reason code), never the vendor's.
    def capture(error)
      return unless defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)

      log = ::ErrorLog.capture!(error)
      log.update(target: current_user) if log.respond_to?(:target=) && current_user
    rescue StandardError
      nil
    end
  end
end
