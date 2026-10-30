# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

require_relative "../../db/migrate/20261029120000_add_voice_profile_to_users"

# [integration] The voice row on /profile, DISPATCHED: real requests through the
# router, Studio::ProfilesController and the database, in the shape
# test/integration/profile_requests_test.rb established (an inline schema, a
# host ApplicationController with Studio::ErrorHandling, a real sign-in door).
#
# What is pinned here:
#   - the row is off by default, and on only when the host says so
#   - a save carries vectors, never audio, and is averaged on the server
#   - every write is scoped to the signed-in user
#   - a save from the wrong model, the wrong number of takes or a silent take
#     is refused and writes nothing
#   - delete removes the vector, the model and the date
#   - the engine migration adds the three columns and its down drops them
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

# The voice columns come from the ENGINE'S OWN MIGRATION, not from the schema
# above, so this file proves the migration produces what the controller writes.
AddVoiceProfileToUsers.new.migrate(:up)

class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  before_action :verify_session_token
end

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = name.presence || email.to_s.split("@").first.presence || "anon"
  def avatar_initials = display_name.to_s[0].to_s.upcase
  def avatar_color = "#6366f1"

  def regenerate_session_token!
    update_column(:session_token, SecureRandom.hex(8))
  end
end

class TestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    user = User.find(params[:id])
    user.regenerate_session_token! if user.session_token.blank?
    session[Studio.session_key] = user.id
    session[:session_token] = user.session_token
    head :ok
  end
end

Rails.application.routes.append do
  post "test_sign_in/:id", to: "test_sessions#create"
end
Rails.application.reload_routes!

class VoiceProfileRequestsTest < ActionDispatch::IntegrationTest
  VM = Studio::VoiceMatch
  MODEL = VM.model_id("wespeaker")
  SIZE = VM.size("wespeaker")

  def setup
    User.delete_all
    Studio.voice_profile = true
    Studio.voice_embedder = "wespeaker"
  end

  def teardown
    Studio.voice_profile = false
    Studio.voice_embedder = "wespeaker"
  end

  def sign_in(user)
    post "/test_sign_in/#{user.id}"
    assert_response :ok
  end

  def create_user(**attrs)
    User.create!({ email: "pat@example.com", name: "Pat Studio", role: "viewer" }.merge(attrs))
  end

  # Three takes along nearby directions, so their average is predictable.
  def takes(size = SIZE)
    Array.new(VM::TAKES) { |i| Array.new(size) { |j| j == i ? 2.0 : 1.0 } }
  end

  def save_voice(embeddings: takes, model: MODEL)
    post "/profile/voice", params: { voice: { model: model, embeddings: embeddings } }.to_json,
                           headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
  end

  # --- the page ------------------------------------------------------------------

  test "off by default: no voice row, even with the columns" do
    Studio.voice_profile = false
    sign_in create_user
    get "/profile"

    assert_response :success
    refute_includes response.body, 'data-profile-section="voice"'
    refute_includes response.body, "voice pattern"
  end

  test "on: the read page carries the row, the consent line and the setup" do
    sign_in create_user
    get "/profile"

    assert_response :success
    assert_includes response.body, 'data-profile-section="voice"'
    assert_includes response.body, 'data-studio-controller="voice-profile"'
    assert_includes response.body, "This saves a voice pattern, not a recording."
    assert_includes response.body, "Set up your voice"
    VM::PHRASES.each { |phrase| assert_includes response.body, ERB::Util.html_escape(phrase) }
    assert_includes response.body, 'data-voice-save-url="/profile/voice"'
    refute_includes response.body, ">Delete<", "nothing to delete yet"
  end

  test "the page names the embedder the server will accept" do
    sign_in create_user
    get "/profile"

    config = JSON.parse(Nokogiri::HTML(response.body).at_css("[data-voice-embedder]")["data-voice-embedder"])
    assert_equal "wespeaker", config["name"]
    assert_equal MODEL, config["id"]
  end

  test "a saved voice shows its state with Re-record and Delete" do
    sign_in create_user(voice_embedding: VM.average(takes), voice_embedding_model: MODEL,
                        voice_embedding_updated_at: Time.utc(2026, 10, 29, 12))
    get "/profile"

    assert_includes response.body, "Your voice is set up (October 29, 2026)."
    assert_includes response.body, "Re-record"
    assert_includes response.body, ">Delete<"
  end

  test "a voice from another model asks to be recorded again" do
    sign_in create_user(voice_embedding: VM.average(takes), voice_embedding_model: "wespeaker@older")
    get "/profile"

    assert_includes response.body, 'data-voice-saved="stale"'
    assert_includes response.body, "older model"
  end

  # --- POST /profile/voice -------------------------------------------------------

  test "a save averages the three takes onto the signed-in user" do
    user = create_user
    sign_in user

    save_voice

    assert_response :ok
    assert_equal({ "url" => "/profile" }, JSON.parse(response.body))
    user.reload
    assert_equal MODEL, user.voice_embedding_model
    assert_not_nil user.voice_embedding_updated_at
    expected = VM.average(takes)
    assert_equal SIZE, user.voice_embedding.size
    user.voice_embedding.each_with_index { |x, i| assert_in_delta expected[i], x, 1e-9 }
  end

  test "a save replaces the voice already there" do
    user = create_user(voice_embedding: Array.new(SIZE, 0.5), voice_embedding_model: MODEL,
                       voice_embedding_updated_at: 1.year.ago)
    sign_in user

    save_voice

    assert_response :ok
    user.reload
    refute_in_delta 0.5, user.voice_embedding.first, 1e-6
    assert_operator user.voice_embedding_updated_at, :>, 1.minute.ago
  end

  test "a save touches nobody but the signed-in user" do
    other = create_user(email: "other@example.com")
    user = create_user
    sign_in user

    save_voice

    assert_nil other.reload.voice_embedding
    assert_not_nil user.reload.voice_embedding
  end

  test "a voice from another embedder is refused and writes nothing" do
    user = create_user
    sign_in user

    save_voice(model: VM.model_id("fake"))

    assert_response :unprocessable_entity
    assert_match "different model", JSON.parse(response.body)["error"]
    assert_nil user.reload.voice_embedding
  end

  test "the test embedder saves only where the app runs it" do
    Studio.voice_embedder = "fake"
    user = create_user
    sign_in user

    save_voice(model: VM.model_id("fake"), embeddings: takes(VM.size("fake")))

    assert_response :ok
    assert_equal VM.model_id("fake"), user.reload.voice_embedding_model
  end

  test "the wrong number of takes, a wrong size, or a silent take is refused" do
    user = create_user
    sign_in user

    bad = {
      "two takes" => takes.first(2),
      "four takes" => takes + [takes.first],
      "short take" => takes.tap { |t| t[0] = [1.0, 2.0] },
      "silent take" => takes.tap { |t| t[2] = Array.new(SIZE, 0.0) },
      "not numbers" => takes.tap { |t| t[1] = Array.new(SIZE, "x") },
      "nothing" => nil
    }
    bad.each do |label, embeddings|
      save_voice(embeddings: embeddings)

      assert_response :unprocessable_entity, label
      assert_nil user.reload.voice_embedding, "#{label} wrote a voice"
    end
  end

  test "an audio upload is not a voice" do
    user = create_user
    sign_in user

    post "/profile/voice", params: { voice: { model: MODEL, audio: "RIFF....WAVEfmt" } },
                           headers: { "ACCEPT" => "application/json" }

    assert_response :unprocessable_entity
    assert_nil user.reload.voice_embedding
  end

  test "a save while the row is off is refused" do
    Studio.voice_profile = false
    user = create_user
    sign_in user

    save_voice

    assert_response :not_found
    assert_nil user.reload.voice_embedding
  end

  test "signed out, a save is a 401 and writes nothing" do
    user = create_user

    save_voice

    assert_response :unauthorized
    assert_nil user.reload.voice_embedding
  end

  test "a form post redirects back to the profile" do
    user = create_user
    sign_in user

    post "/profile/voice", params: { voice: { model: MODEL, embeddings: takes.to_json } }

    assert_redirected_to "/profile"
    assert_equal MODEL, user.reload.voice_embedding_model
  end

  # --- DELETE /profile/voice -----------------------------------------------------

  test "delete removes the vector, the model and the date" do
    other = create_user(email: "other@example.com", voice_embedding: VM.average(takes), voice_embedding_model: MODEL)
    user = create_user(voice_embedding: VM.average(takes), voice_embedding_model: MODEL,
                       voice_embedding_updated_at: Time.current)
    sign_in user

    delete "/profile/voice"

    assert_redirected_to "/profile"
    user.reload
    assert_nil user.voice_embedding
    assert_nil user.voice_embedding_model
    assert_nil user.voice_embedding_updated_at
    assert_not_nil other.reload.voice_embedding, "someone else's voice is not this user's to delete"
  end

  test "delete while the row is off is refused" do
    user = create_user(voice_embedding: VM.average(takes), voice_embedding_model: MODEL)
    sign_in user
    Studio.voice_profile = false

    delete "/profile/voice"

    assert_redirected_to "/profile"
    assert_not_nil user.reload.voice_embedding
  end

  # --- the matcher against the real table ------------------------------------------

  test "identify finds the speaker among users, by the saved model" do
    voice = VM.average(takes)
    pat = create_user(voice_embedding: voice, voice_embedding_model: MODEL)
    create_user(email: "old@example.com", voice_embedding: voice, voice_embedding_model: "wespeaker@older")
    create_user(email: "none@example.com")

    assert_equal pat, VM.identify(voice, among: User.all, model: MODEL)
    assert_equal pat, VM.identify(voice, among: User, model: MODEL)
    assert_nil VM.identify(Array.new(SIZE) { |i| i.even? ? 1.0 : -1.0 }, among: User.all, model: MODEL)
  end

  # --- the migration ---------------------------------------------------------------

  test "the migration's down drops exactly its three columns, and up is idempotent" do
    columns = -> { ActiveRecord::Base.connection.columns(:users).map(&:name) }
    AddVoiceProfileToUsers.new.migrate(:up) # a second up: if_not_exists

    AddVoiceProfileToUsers.new.migrate(:down)
    VM::USER_COLUMNS.each { |c| refute_includes columns.call, c.to_s }
    assert_includes columns.call, "email", "the host's own columns are left alone"
  ensure
    AddVoiceProfileToUsers.new.migrate(:up)
    User.reset_column_information
  end

  test "the engine keeps voice vectors out of the request log and User#inspect" do
    sign_in create_user
    save_voice
    assert_response :ok

    logged = request.filtered_parameters
    assert_equal "[FILTERED]", logged.dig("voice", "embeddings")
    assert_equal MODEL, logged.dig("voice", "model"), "the model id stays readable"
    assert_equal "[FILTERED]", logged.dig("profile", "voice", "embeddings"), "the JSON param wrapper copy too"
    assert_includes User.last.inspect, "voice_embedding: [FILTERED]", "User#inspect masks voice_embedding"
  end
end
