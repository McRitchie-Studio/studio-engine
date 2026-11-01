# frozen_string_literal: true

require "test_helper"
require_relative "../../support/agent_chat_stub_hub"

# [unit] Studio::VoiceTranscription: adapter selection, the mock, the
# no-live-calls trap, the OpenAI adapter's request against a stub server on a
# real local socket (no outside network), its retry and refusals, the
# no-speech rule, and who spoke (Studio::VoiceMatch against the user's own
# saved voice, same embedder revision only).
class StudioVoiceTranscriptionTest < Minitest::Test
  VT = Studio::VoiceTranscription
  VM = Studio::VoiceMatch
  MODEL = VM.model_id("wespeaker")
  SIZE = VM.size("wespeaker")
  AUDIO = ("\x1A\x45\xDF\xA3".b + ("opus-frame" * 40).b).freeze

  User = Struct.new(:display_name, :voice_embedding, :voice_embedding_model, keyword_init: true)

  def setup
    @saved = {
      transcriber: Studio.voice_transcriber, key: Studio.voice_openai_api_key, embedder: Studio.voice_embedder,
      env_key: ENV.fetch("OPENAI_API_KEY", nil), env_name: ENV.fetch("STUDIO_VOICE_TRANSCRIBER", nil),
      guard: ENV.fetch("VOICE_NO_LIVE_CALLS", nil)
    }
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("STUDIO_VOICE_TRANSCRIBER")
    Studio.voice_transcriber = nil
    Studio.voice_openai_api_key = nil
    Studio.voice_embedder = "wespeaker"
    VT::Mock.reset!
  end

  def teardown
    @server&.stop
    Studio.voice_transcriber = @saved[:transcriber]
    Studio.voice_openai_api_key = @saved[:key]
    Studio.voice_embedder = @saved[:embedder]
    { "OPENAI_API_KEY" => :env_key, "STUDIO_VOICE_TRANSCRIBER" => :env_name, "VOICE_NO_LIVE_CALLS" => :guard }.each do |name, key|
      @saved[key] ? ENV[name] = @saved[key] : ENV.delete(name)
    end
    VT::Mock.reset!
  end

  def with_rails_env(env)
    original = VT.method(:rails_env)
    VT.define_singleton_method(:rails_env) { env }
    yield
  ensure
    VT.define_singleton_method(:rails_env, original)
  end

  def stub_openai
    @server = AgentChatStubHub.start
  end

  def client(**options)
    VT::OpenAI.new(api_key: "test-key", model: "gpt-4o-transcribe", fallback_model: "whisper-1", language: "en",
                   endpoint: "#{@server.url}/v1/audio/transcriptions", **options)
  end

  def take(io = StringIO.new(AUDIO))
    { io: io, filename: "take.webm", content_type: "audio/webm" }
  end

  def unit(index, size = SIZE)
    Array.new(size) { |i| i == index ? 1.0 : 0.0 }
  end

  # ── adapter selection ───────────────────────────────────────

  def test_outside_production_the_default_is_the_mock_and_production_defaults_to_openai
    with_rails_env(nil) { assert_equal "mock", VT.adapter_name }
    with_rails_env("development") { assert_equal "mock", VT.adapter_name }
    with_rails_env("test") { assert_equal "mock", VT.adapter_name }
    with_rails_env("production") { assert_equal "openai", VT.adapter_name }
    assert_instance_of VT::Mock, VT.transcriber
  end

  def test_the_env_then_the_host_config_choose_the_adapter
    ENV["STUDIO_VOICE_TRANSCRIBER"] = "openai"
    assert_equal "openai", VT.adapter_name
    with_rails_env("production") do
      ENV["STUDIO_VOICE_TRANSCRIBER"] = "mock"
      assert_equal "mock", VT.adapter_name, "a desk can run the mock even with production defaults"
    end
    Studio.voice_transcriber = "mock"
    ENV["STUDIO_VOICE_TRANSCRIBER"] = "openai"
    assert_equal "mock", VT.adapter_name, "the host's own setting wins"
    assert_instance_of VT::OpenAI, VT.transcriber("openai")
  end

  def test_an_unknown_adapter_name_is_not_configured
    error = assert_raises(VT::NotConfigured) { VT.transcriber("whisper-local") }
    assert_match "openai, mock", error.message
  end

  def test_the_key_comes_from_host_config_then_openai_api_key
    assert_equal "", VT.api_key
    ENV["OPENAI_API_KEY"] = "env-key"
    assert_equal "env-key", VT.api_key
    Studio.voice_openai_api_key = "config-key"
    assert_equal "config-key", VT.api_key
    refute VT::OpenAI.new(api_key: " ").configured?
  end

  # ── the mock ────────────────────────────────────────────────

  def test_the_mock_answers_its_sentence_records_sizes_not_bytes_and_takes_a_reply
    mock = VT::Mock.new
    assert_equal VT::Mock::DEFAULT_TEXT, mock.transcribe(**take)
    assert_equal({ filename: "take.webm", content_type: "audio/webm", bytes: AUDIO.bytesize }, VT::Mock.calls.last)
    refute VT::Mock.calls.last.values.any? { |v| v.is_a?(String) && v.include?("opus-frame") }

    VT::Mock.reply = ->(bytes:, **) { "heard #{bytes} bytes" }
    assert_equal "heard 3 bytes", mock.transcribe(io: StringIO.new("abc"), filename: "t.ogg", content_type: "audio/ogg")
  end

  # ── the no-live-calls trap ──────────────────────────────────

  def test_the_real_adapter_never_reaches_the_vendor_while_armed
    assert_equal "1", ENV["VOICE_NO_LIVE_CALLS"], "test_helper arms the trap for the whole suite"
    stt = VT::OpenAI.new(api_key: "test-key")
    assert_equal "https://api.openai.com/v1/audio/transcriptions", stt.endpoint
    error = assert_raises(VT::LiveCallAttempted) { stt.transcribe(**take) }
    assert_match "VOICE_NO_LIVE_CALLS", error.message
    refute_kind_of StandardError, error, "outside StandardError so no caller's rescue can swallow it"
  end

  def test_the_trap_is_armed_by_the_flag_or_a_rails_test_env_and_lets_this_machine_through
    ENV["VOICE_NO_LIVE_CALLS"] = "0"
    with_rails_env("test") { refute VT.live_calls_blocked?, "0 disarms it explicitly" }
    ENV.delete("VOICE_NO_LIVE_CALLS")
    with_rails_env("test") { assert VT.live_calls_blocked?, "a host's test suite is armed without setting anything" }
    with_rails_env("production") { refute VT.live_calls_blocked? }
    ENV["VOICE_NO_LIVE_CALLS"] = "1"
    assert_nil VT.guard_live_call!("OpenAI", host: "127.0.0.1")
    assert_raises(VT::LiveCallAttempted) { VT.guard_live_call!("OpenAI", host: "api.openai.com") }
  end

  # ── the OpenAI adapter, against a stub on 127.0.0.1 ──────────

  def test_it_posts_the_take_as_multipart_with_the_model_language_and_key_and_strips_the_text
    stub_openai
    @server.respond { [200, { "text" => "  hello alex \n" }] }

    assert_equal "hello alex", client.transcribe(**take)

    request = @server.requests.last
    assert_equal "POST", request.method
    assert_equal "/v1/audio/transcriptions", request.path
    assert_equal "Bearer test-key", request.headers["authorization"]
    assert_match %r{\Amultipart/form-data; boundary=studio-voice-\h+\z}, request.headers["content-type"]
    body = request.body.b
    assert_includes body, %(name="file"; filename="take.webm"\r\nContent-Type: audio/webm\r\n\r\n#{AUDIO}\r\n).b
    assert_includes body, %(name="model"\r\n\r\ngpt-4o-transcribe\r\n)
    assert_includes body, %(name="response_format"\r\n\r\njson\r\n)
    assert_includes body, %(name="language"\r\n\r\nen\r\n)
  end

  def test_a_blank_language_is_left_out
    fields = client_for_fields(language: nil).form_fields("whisper-1", StringIO.new("x"), "take.webm", "audio/webm")
    assert_nil fields.assoc("language")
    assert_equal ["model", "whisper-1"], fields.assoc("model")
  end

  def test_a_failure_is_retried_once_on_the_fallback_from_the_start_of_the_audio
    stub_openai
    @server.respond { |req| req.body.include?("gpt-4o-transcribe") ? [500, { "error" => { "message" => "overloaded" } }] : [200, { "text" => "heard it" }] }

    assert_equal "heard it", client.transcribe(**take)
    bodies = @server.requests.map(&:body)
    assert_equal 2, bodies.size
    assert_includes bodies.last, %(name="model"\r\n\r\nwhisper-1\r\n)
    assert_includes bodies.last.b, AUDIO, "the retry re-sent the whole take"
  end

  def test_an_auth_failure_is_not_retried_and_no_fallback_means_no_retry
    stub_openai
    [401, 403].each do |status|
      @server.respond { [status, { "error" => { "message" => "Incorrect API key provided" } }] }
      before = @server.requests.size
      error = assert_raises(VT::HttpError) { client.transcribe(**take) }
      assert_equal status, error.status
      assert_match "Incorrect API key provided", error.message
      assert_equal before + 1, @server.requests.size
    end

    @server.respond { [500, "<html>down</html>"] }
    before = @server.requests.size
    assert_raises(VT::HttpError) { client(fallback_model: "").transcribe(**take) }
    assert_equal before + 1, @server.requests.size
  end

  def test_a_missing_key_is_not_configured_before_any_request
    stub_openai
    error = assert_raises(VT::NotConfigured) { client(api_key: nil).transcribe(**take) }
    assert_match "OPENAI_API_KEY", error.message
    assert_empty @server.requests
    assert_kind_of StandardError, error
  end

  def test_an_unreachable_vendor_is_an_http_error_not_a_crash
    stub_openai
    url = "#{@server.url}/v1/audio/transcriptions"
    @server.stop
    error = assert_raises(VT::HttpError) { client(endpoint: url, fallback_model: nil).transcribe(**take) }
    assert_equal 0, error.status
  end

  # ── types and the no-speech rule ────────────────────────────

  def test_mime_types_drop_codecs_and_refuse_what_a_take_cannot_be
    assert_equal "audio/webm", VT.mime_type("audio/webm;codecs=opus")
    assert_equal "audio/mp4", VT.mime_type(" Audio/MP4 ")
    assert_nil VT.mime_type("text/plain")
    assert_nil VT.mime_type(nil)
    assert_equal "take.ogg", VT.filename_for("audio/ogg;codecs=opus")
    assert_equal "take.m4a", VT.filename_for("audio/x-m4a")
    # What the recorder actually emits (studio/voice_recorder pickMimeType).
    assert_equal "take.mp4", VT.filename_for("audio/mp4;codecs=mp4a.40.2")
    assert_equal "take.webm", VT.filename_for("audio/webm;codecs=opus")
  end

  def test_no_speech_catches_what_models_write_for_silence
    assert_nil VT.no_speech_reason("Hey Alex, what's on today?")
    assert_nil VT.no_speech_reason("Dinosaurs!")
    assert_match "empty", VT.no_speech_reason("  ")
    assert_match "stock phrase", VT.no_speech_reason("Thank you for watching.")
    assert_match "filler", VT.no_speech_reason("Um.")
    assert_match "no en letters", VT.no_speech_reason("Тревога")
    assert_nil VT.no_speech_reason("Тревога", language: "ru")
  end

  # ── who spoke ───────────────────────────────────────────────

  def test_a_take_close_to_the_users_own_voice_names_them
    user = User.new(display_name: "Pat Studio", voice_embedding: unit(0), voice_embedding_model: MODEL)
    probe = unit(0).each_with_index.map { |x, i| i == 1 ? 0.3 : x }

    heard = VT.hear(audio: AUDIO, mime_type: "audio/webm;codecs=opus", user: user, embedding: JSON.generate(probe), model: MODEL)

    assert_equal VT::Mock::DEFAULT_TEXT, heard.text
    assert_equal "Pat Studio", heard.speaker
    assert_equal "matched", heard.check
    assert heard.identified?
    assert_in_delta 0.9578, heard.score, 0.0001
    assert_equal %w[text speaker score identified check], heard.to_h.keys
    assert_equal({ filename: "take.webm", content_type: "audio/webm", bytes: AUDIO.bytesize }, VT::Mock.calls.last)
  end

  def test_a_take_below_the_threshold_is_someone_new_with_its_score
    user = User.new(display_name: "Pat", voice_embedding: unit(0), voice_embedding_model: MODEL)
    probe = unit(0).each_with_index.map { |x, i| i == 1 ? 1.5 : x } # cosine 0.5547

    heard = VT.hear(audio: AUDIO, mime_type: "audio/webm", user: user, embedding: probe, model: MODEL)

    assert_equal "Someone new", heard.speaker
    assert_equal "below_threshold", heard.check
    refute heard.identified?
    assert_in_delta 0.5547, heard.score, 0.0001
    assert_operator heard.score, :<, VM::THRESHOLD
  end

  def test_vectors_from_another_embedder_revision_are_never_compared
    same = unit(0)
    saved_elsewhere = User.new(display_name: "Pat", voice_embedding: same, voice_embedding_model: "wespeaker-voxceleb-resnet34-LM@0000000")
    current = User.new(display_name: "Pat", voice_embedding: same, voice_embedding_model: MODEL)

    [[saved_elsewhere, MODEL], [current, "fake-256"], [current, nil]].each do |user, model|
      heard = VT.hear(audio: AUDIO, mime_type: "audio/webm", user: user, embedding: same, model: model)
      assert_equal ["Someone new", nil, "embedder_mismatch"], [heard.speaker, heard.score, heard.check],
                   "saved #{user.voice_embedding_model} vs take #{model.inspect}"
    end
  end

  def test_a_user_with_no_saved_voice_is_someone_new_without_a_score
    [User.new(display_name: "Pat"), Struct.new(:display_name).new("Pat"), nil].each do |user|
      heard = VT.hear(audio: AUDIO, mime_type: "audio/webm", user: user, embedding: unit(0), model: MODEL)
      assert_equal ["Someone new", nil, "no_profile", false], [heard.speaker, heard.score, heard.check, heard.identified]
    end
  end

  def test_a_take_without_a_usable_embedding_still_transcribes
    user = User.new(display_name: "Pat", voice_embedding: unit(0), voice_embedding_model: MODEL)
    [nil, "not json", unit(0, 12), Array.new(SIZE, 0.0), Array.new(SIZE, "1")].each do |embedding|
      heard = VT.hear(audio: AUDIO, mime_type: "audio/webm", user: user, embedding: embedding, model: MODEL)
      assert_equal [VT::Mock::DEFAULT_TEXT, "Someone new", nil, "no_embedding"],
                   [heard.text, heard.speaker, heard.score, heard.check]
    end
  end

  def test_hear_refuses_a_type_a_take_cannot_be_before_transcribing
    assert_raises(ArgumentError) { VT.hear(audio: AUDIO, mime_type: "image/png", user: nil) }
    assert_empty VT::Mock.calls
  end

  def test_every_check_is_listed
    assert_equal %w[matched below_threshold no_profile embedder_mismatch no_embedding], VT::CHECKS
  end

  private

  def client_for_fields(**options)
    VT::OpenAI.new(api_key: "k", model: "gpt-4o-transcribe", fallback_model: "whisper-1", language: "en", **options)
  end
end
