# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "json"
require "stringio"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

require_relative "../../db/migrate/20261029120000_add_voice_profile_to_users"

# [integration] POST /voice/takes, DISPATCHED: a take posted the way the hub's
# chat composer will post the recorder's take (multipart: voice[audio],
# voice[mime_type], voice[duration_ms], voice[embedding], voice[model]) through
# the router, Studio::VoiceTakesController and the mock transcriber, answering
# {text, speaker, score, identified, check, duration_ms}.
#
# What is pinned here:
#   - signed-in only, CSRF-protected
#   - the speaker is the signed-in user's own saved voice, or "Someone new"
#   - the caps: size, duration, type
#   - a missing key is a 503 the page can show, not a crash
#   - silence the model made words of is refused
#   - nothing is kept: no row written, and neither the audio nor the vector
#     reaches the request log
ActionDispatch::IntegrationTest.app = Rails.application
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

ActiveRecord::Schema.verbose = false
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :role
    t.string :session_token
    t.timestamps
  end

  create_table :error_logs, force: true do |t|
    t.string :slug
    t.text   :message
    t.text   :inspect
    t.text   :backtrace
    t.string :target_type
    t.bigint :target_id
    t.string :parent_type
    t.bigint :parent_id
    t.timestamps
  end
end
AddVoiceProfileToUsers.new.migrate(:up)

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = name.presence || email.to_s.split("@").first
end

class VoiceTakesTestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    session[Studio.session_key] = params[:id].to_i
    head :ok
  end
end

Rails.application.routes.append do
  post "voice_takes_test_sign_in/:id", to: "voice_takes_test_sessions#create"
end
Rails.application.reload_routes!

class VoiceTakesRequestsTest < ActionDispatch::IntegrationTest
  VT = Studio::VoiceTranscription
  VM = Studio::VoiceMatch
  MODEL = VM.model_id("wespeaker")
  SIZE = VM.size("wespeaker")
  AUDIO = ("\x1A\x45\xDF\xA3".b + ("AUDIOMARKER" * 30).b).freeze
  # A component value that appears nowhere else, so the log check can look for it.
  MARK = 0.7071067811865476

  def setup
    Rails.application.routes.url_helpers.studio_voice_takes_path # pin the lazy draw
    User.delete_all
    ErrorLog.delete_all
    @saved = { transcriber: Studio.voice_transcriber, key: Studio.voice_openai_api_key,
               embedder: Studio.voice_embedder, env_key: ENV.fetch("OPENAI_API_KEY", nil) }
    Studio.voice_transcriber = nil
    Studio.voice_openai_api_key = nil
    Studio.voice_embedder = "wespeaker"
    ENV.delete("OPENAI_API_KEY")
    VT::Mock.reset!
    VT::Mock.reply = ->(**) { "Hey Alex, what's on my calendar today?" }
    @pat = User.create!(email: "pat@example.com", name: "Pat Studio",
                        voice_embedding: saved_voice, voice_embedding_model: MODEL)
  end

  def teardown
    Studio.voice_transcriber = @saved[:transcriber]
    Studio.voice_openai_api_key = @saved[:key]
    Studio.voice_embedder = @saved[:embedder]
    @saved[:env_key] ? ENV["OPENAI_API_KEY"] = @saved[:env_key] : ENV.delete("OPENAI_API_KEY")
    VT::Mock.reset!
    ActionController::Base.allow_forgery_protection = false
  end

  def saved_voice = Array.new(SIZE) { |i| i < 2 ? MARK : 0.0 }

  def sign_in(user)
    post "/voice_takes_test_sign_in/#{user.id}"
    assert_response :ok
  end

  def upload(bytes = AUDIO, type = "audio/webm;codecs=opus")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, true, original_filename: "blob")
  end

  def post_take(audio: upload, mime_type: "audio/webm;codecs=opus", duration_ms: 2400, embedding: saved_voice, model: MODEL)
    voice = { audio: audio, mime_type: mime_type, duration_ms: duration_ms, model: model }
    voice[:embedding] = JSON.generate(embedding) if embedding
    post "/voice/takes", params: { voice: voice.compact }, headers: { "Accept" => "application/json" }
  end

  def json = JSON.parse(response.body)

  # ── the answer ──────────────────────────────────────────────

  test "a signed-in take in the user's own voice comes back as text, their name and the score" do
    sign_in @pat
    post_take

    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "text" => "Hey Alex, what's on my calendar today?", "speaker" => "Pat Studio", "score" => 1.0,
                   "identified" => true, "check" => "matched", "duration_ms" => 2400 }, json)
    assert_equal [{ filename: "take.webm", content_type: "audio/webm", bytes: AUDIO.bytesize }], VT::Mock.calls
  end

  test "a voice that is not theirs, or a user with no saved voice, is Someone new and still answers the text" do
    sign_in @pat
    post_take(embedding: Array.new(SIZE) { |i| i == 5 ? 1.0 : 0.0 })
    assert_response :ok
    assert_equal ["Someone new", false, "below_threshold"], json.values_at("speaker", "identified", "check")

    sam = User.create!(email: "sam@example.com", name: "Sam")
    sign_in sam
    post_take
    assert_response :ok
    assert_equal ["Someone new", nil, "no_profile"], json.values_at("speaker", "score", "check")
    assert_equal "Hey Alex, what's on my calendar today?", json["text"]
  end

  test "a take from another embedder revision is never compared, and a take with no vector still transcribes" do
    sign_in @pat
    post_take(model: "fake-256")
    assert_equal ["Someone new", nil, "embedder_mismatch"], json.values_at("speaker", "score", "check")

    post_take(embedding: nil, model: nil)
    assert_response :ok
    assert_equal ["Someone new", "no_embedding"], json.values_at("speaker", "check")
  end

  test "it matches only the signed-in user, never another account's voice" do
    other = User.create!(email: "sam@example.com", name: "Sam",
                         voice_embedding: Array.new(SIZE) { |i| i == 9 ? 1.0 : 0.0 }, voice_embedding_model: MODEL)
    sign_in @pat
    post_take(embedding: other.voice_embedding)

    assert_equal ["Someone new", "below_threshold"], json.values_at("speaker", "check")
    refute_includes response.body, "Sam"
  end

  # ── nothing is kept ─────────────────────────────────────────

  test "nothing is stored, and neither the audio nor the vector reaches the log" do
    sign_in @pat
    before = @pat.reload.attributes
    log = StringIO.new
    original = Rails.logger
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(log)
    begin
      post_take
    ensure
      Rails.logger = ActionController::Base.logger = original
    end

    assert_response :ok
    assert_equal before, @pat.reload.attributes
    assert_equal 0, ErrorLog.count
    assert_equal 1, User.count
    assert_includes log.string, "Processing by Studio::VoiceTakesController#create"
    assert_includes log.string, "[FILTERED]"
    refute_includes log.string, MARK.to_s
    refute_includes log.string, "AUDIOMARKER"
  end

  # ── refusals ────────────────────────────────────────────────

  test "signed out is a 401 and nothing is transcribed" do
    post_take
    assert_response :unauthorized
    assert_empty VT::Mock.calls
  end

  test "a post without the page's authenticity token is refused" do
    sign_in @pat
    ActionController::Base.allow_forgery_protection = true
    assert_raises(ActionController::InvalidAuthenticityToken) { post_take }
    assert_empty VT::Mock.calls
  end

  test "the caps: no audio, empty audio, too big, no or too long a duration, a type a take cannot be" do
    sign_in @pat
    post "/voice/takes", params: { voice: { duration_ms: 1000 } }, headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    assert_equal "Record something first.", json["error"]

    post_take(audio: upload("".b))
    assert_response :unprocessable_entity

    post_take(audio: upload("a".b * (VT::MAX_BYTES + 1)))
    assert_response 413

    [nil, "0", "-5", "abc", (VT::MAX_DURATION_MS + 1).to_s].each do |duration|
      post_take(duration_ms: duration)
      assert_response :unprocessable_entity, "duration #{duration.inspect}"
    end

    post_take(audio: upload(AUDIO, "text/plain"), mime_type: "text/plain")
    assert_response 415
    assert_empty VT::Mock.calls
  end

  test "the part's own content type is used when the page sends no mime_type" do
    sign_in @pat
    post_take(audio: upload(AUDIO, "audio/ogg"), mime_type: nil)
    assert_response :ok
    assert_equal "take.ogg", VT::Mock.calls.last[:filename]
  end

  test "silence the model made words of is refused with a line the page can show" do
    VT::Mock.reply = ->(**) { "Thank you for watching." }
    sign_in @pat
    post_take

    assert_response :unprocessable_entity
    assert_equal "no_speech", json["reason"]
    assert_match "couldn't hear", json["error"]
  end

  test "a real transcriber without a key is a 503 the page can show, not a crash" do
    Studio.voice_transcriber = "openai"
    sign_in @pat
    post_take

    assert_response :service_unavailable
    assert_equal({ "error" => VT::NOT_CONFIGURED_MESSAGE, "reason" => "not_configured" }, json)
    refute_includes response.body, "OPENAI_API_KEY"
    assert_match "OPENAI_API_KEY", ErrorLog.last.message
  end

  test "with a key, the real transcriber in a test environment trips the no-live-calls trap" do
    Studio.voice_transcriber = "openai"
    Studio.voice_openai_api_key = "test-key"
    sign_in @pat
    assert_raises(VT::LiveCallAttempted) { post_take }
  end
end
