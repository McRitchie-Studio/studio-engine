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
  # NOTHING IS KEPT: the upload is read once, handed to the transcriber, and its
  # tempfile is deleted before the answer; no audio or vector is stored or
  # logged (voice[audio] and voice[embedding] are in the engine's parameter
  # filter).
  class VoiceTakesController < ::ApplicationController
    before_action :require_authentication
    protect_from_forgery with: :exception
    before_action :no_store

    CANT_HEAR = "I couldn't hear any words in that. Check your microphone and try again."
    UNAVAILABLE = "I couldn't transcribe that just now. Try again in a moment."

    def create
      voice = params[:voice]
      audio = voice.respond_to?(:[]) ? voice[:audio] : nil
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

    def capture(error)
      ::ErrorLog.capture!(error) if defined?(::ErrorLog) && ::ErrorLog.respond_to?(:capture!)
    rescue StandardError
      nil
    end
  end
end
