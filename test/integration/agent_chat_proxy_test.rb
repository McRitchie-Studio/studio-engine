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
require_relative "../support/agent_chat_stub_hub"

ActionDispatch::IntegrationTest.app = Rails.application
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

# The engine's controllers inherit the HOST's ApplicationController; this one is
# shaped like every consumer's: Studio::ErrorHandling, so current_user and
# require_authentication are the engine's own.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
end

class AgentChatTestSessionsController < ApplicationController
  skip_before_action :require_authentication

  def create
    session[Studio.session_key] = params[:id].to_i
    head :ok
  end
end

Rails.application.routes.append do
  post "agent_chat_test_sign_in/:id", to: "agent_chat_test_sessions#create"
end
Rails.application.reload_routes!

# [integration] The shared agent chat end to end through the dummy host: the
# page a host renders (render "studio/agent_chat/chat", soul:, name:, portrait:),
# and the proxy behind it (Studio::AgentChatsController) forwarding to a stub hub
# on a real socket, signed in and signed out:
#
#   1. the page carries the chat, its two URLs, the card slot and the CSRF token;
#   2. a signed-in visitor's message reaches the hub as their EMAIL, with the IP,
#      and never as anything the browser named;
#   3. a signed-out visitor gets a signed, http-only anon cookie on the first
#      message and the hub sees that token on every later call; a visitor who
#      never sent one is answered without asking the hub;
#   4. the soul comes only from the app's allow-list;
#   5. the hub's refusals and outages map to 422/429/404/503 with a friendly
#      error, and a POST without the authenticity token is refused.
class AgentChatProxyTest < ActionDispatch::IntegrationTest
  TURN = { "id" => "41", "role" => "user", "text" => "Hello", "created_at" => "2026-10-27T10:00:00Z",
           "status" => "pending" }.freeze

  def self.ensure_schema!
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :error_logs, force: true do |t|
        t.string :slug
        t.text :message
        t.text :inspect
        t.text :backtrace
        t.string :target_type
        t.bigint :target_id
        t.string :target_name
        t.string :parent_type
        t.bigint :parent_id
        t.string :parent_name
        t.timestamps
      end
      create_table :users, force: true do |t|
        t.string :email, null: false
        t.string :name
        t.string :role
        t.string :provider
        t.string :uid
        t.string :session_token
        t.datetime :email_verified_at
        t.timestamps
      end
    end
  end

  def setup
    # Rails 8.1 draws routes lazily, and the dummy's routes.rb sets
    # Studio.agent_chat_souls as it draws: pin the draw before setting config.
    Rails.application.routes.url_helpers.studio_agent_chat_turns_path
    self.class.ensure_schema!
    User.delete_all
    # Sam proved his address (a magic link stamps email_verified_at); Eve did
    # not: she typed sam's neighbour's address into her profile.
    @sam = User.create!(email: "sam@example.com", name: "Sam", email_verified_at: Time.current)
    @eve = User.create!(email: "victim@example.com", name: "Eve")
    @hub = AgentChatStubHub.start
    @saved = { url: Studio.agent_chat_hub_url, token: Studio.agent_chat_token, souls: Studio.agent_chat_souls,
               verified: Studio.agent_chat_verified_email }
    Studio.agent_chat_verified_email = nil
    Studio.agent_chat_hub_url = @hub.url
    Studio.agent_chat_token = "app-credential"
    Studio.agent_chat_souls = %w[alex]
    @hub.respond do |request|
      request.method == "POST" ? [201, { "turn" => TURN }] : [200, { "turns" => [TURN], "pending" => true }]
    end
  end

  def teardown
    @hub.stop
    Studio.agent_chat_hub_url = @saved[:url]
    Studio.agent_chat_token = @saved[:token]
    Studio.agent_chat_souls = @saved[:souls]
    Studio.agent_chat_verified_email = @saved[:verified]
    ActionController::Base.allow_forgery_protection = false
  end

  def sign_in(user)
    post "/agent_chat_test_sign_in/#{user.id}"
    assert_response :ok
  end

  def with_voice_hook(hook)
    saved = Studio.voice_chat_allowed
    Studio.voice_chat_allowed = hook
    yield
  ensure
    Studio.voice_chat_allowed = saved
  end

  # ── 1. the page ─────────────────────────────────────────────

  def test_the_host_page_renders_the_chat_with_its_urls_card_slot_and_token
    ActionController::Base.allow_forgery_protection = true
    get "/agent_chat_lab"
    assert_response :success

    chat = css_select('[data-test="agent-chat"]')
    assert_equal 1, chat.size
    assert_equal "agent-chat", chat.first["data-studio-controller"]
    assert_equal "alex", chat.first["data-agent-chat-soul"]
    assert_equal "/agent_chat/messages", chat.first["data-agent-chat-messages-url"]
    assert_equal "/agent_chat/turns", chat.first["data-agent-chat-turns-url"]
    assert_select '[data-test="agent-chat-header"][data-agent-name="Alex"]'
    assert_select '[data-test="agent-chat-caption"]', text: /Alex · Fractional CTO/
    assert_select '[data-test="agent-chat-cards"] [data-test="agent-chat-lab-card"]'
    assert_select 'form[data-test="agent-chat-form"][action="/agent_chat/messages"] input[name="authenticity_token"]'
    assert_select 'form[data-test="agent-chat-form"] input[name="soul"][value="alex"]'
    assert_select 'textarea[name="text"][maxlength="4000"]'
    assert_select '[data-test="agent-chat-offline"][hidden] [data-test="agent-chat-retry"]'
    assert_select 'template[data-agent-chat-template="user"]'
    assert_select 'template[data-agent-chat-template="agent"]'
    assert_empty @hub.requests, "rendering the page never calls the hub; the script loads the thread"
  end

  def test_the_partial_refuses_a_soul_off_the_allow_list
    Studio.agent_chat_souls = %w[ray]
    error = assert_raises(ActionView::Template::Error) { get "/agent_chat_lab" }
    assert_match(/not in Studio.agent_chat_souls/, error.message)
  end

  # ── who may use the chat ────────────────────────────────────

  def with_chat_hook(hook)
    saved = Studio.agent_chat_allowed
    Studio.agent_chat_allowed = hook
    yield
  ensure
    Studio.agent_chat_allowed = saved
  end

  def assert_refused_before_the_hub
    before = @hub.requests.size
    post "/agent_chat/messages", params: { soul: "alex", text: "Hello" }.to_json, headers: json_headers
    assert_response :forbidden
    assert_equal "not_allowed", JSON.parse(response.body)["reason"]
    assert_kind_of String, JSON.parse(response.body)["error"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil cookies[Studio::AgentChatsController::ANON_COOKIE.to_s], "a refused visitor is minted nothing"

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_response :forbidden
    assert_equal "not_allowed", JSON.parse(response.body)["reason"]
    assert_equal before, @hub.requests.size, "the hub is never asked"
  end

  def test_by_default_a_signed_out_visitor_may_chat
    post "/agent_chat/messages", params: { soul: "alex", text: "Hello" }.to_json, headers: json_headers
    assert_response :created
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_response :ok
  end

  def test_a_refused_signed_out_visitor_is_a_403_on_both_calls_before_the_hub
    seen = []
    with_chat_hook(->(user) { seen << user; user&.admin? }) { assert_refused_before_the_hub }
    assert_equal [nil], seen.uniq, "the hook is asked about a signed-out visitor, as nil"
  end

  def test_a_refused_signed_in_user_is_a_403_and_an_allowed_one_reaches_the_hub
    sign_in(@sam)
    with_chat_hook(->(user) { user&.admin? }) do
      assert_refused_before_the_hub

      @sam.update!(role: "admin")
      post "/agent_chat/messages", params: { soul: "alex", text: "Hello" }.to_json, headers: json_headers
      assert_response :created
      get "/agent_chat/turns", params: { soul: "alex" }
      assert_response :ok
    end
  end

  def test_a_chat_hook_that_raises_closes_the_chat
    with_chat_hook(->(user) { user.admin? }) { assert_refused_before_the_hub }
  end

  def test_a_refused_viewer_sees_no_chat_on_the_page
    with_chat_hook(->(_user) { false }) do
      get "/agent_chat_lab"
      assert_response :success
      assert_select '[data-test="agent-chat"]', 0
      assert_select '[data-test="agent-chat-form"]', 0
    end
  end

  def test_a_user_the_chat_refuses_may_not_talk_whatever_the_voice_hook_says
    sign_in(@sam)
    with_chat_hook(->(_user) { false }) do
      with_voice_hook(->(_user) { true }) { assert_equal false, Studio.voice_chat_allowed?(@sam) }
    end
  end

  # ── the mic ─────────────────────────────────────────────────

  PRIVACY = "When you speak to an agent, your recording is sent to OpenAI to turn it into text, then deleted. We never keep the audio."
  MIC = 'form[data-test="agent-chat-form"] [data-test="agent-chat-voice"]'

  def test_voice_chat_allowed_defaults_to_anyone_signed_in_and_never_asks_about_no_user
    assert_equal true, Studio.voice_chat_allowed?(@eve)
    assert_equal false, Studio.voice_chat_allowed?(nil)
    with_voice_hook(->(_user) { flunk "asked about nobody" }) { assert_equal false, Studio.voice_chat_allowed?(nil) }
  end

  def test_voice_chat_allowed_reads_the_hook_and_a_raising_or_false_hook_is_no
    with_voice_hook(->(user) { user == @sam }) do
      assert_equal true, Studio.voice_chat_allowed?(@sam)
      assert_equal false, Studio.voice_chat_allowed?(@eve)
    end
    with_voice_hook(->(_user) { raise "gate broke" }) { assert_equal false, Studio.voice_chat_allowed?(@sam) }
    with_voice_hook(false) { assert_equal false, Studio.voice_chat_allowed?(@sam) }
  end

  def test_the_voice_and_footer_chat_settings_default_off
    assert_nil Studio.site_footer_chat_path
    assert_equal "Chat", Studio.site_footer_chat_label
    assert_nil Studio.site_footer_chat_allowed
    partial = File.read(File.expand_path("../../app/views/studio/agent_chat/_chat.html.erb", __dir__))
    assert_match(/voice: false/, partial[/\A.*?%>/])
  end

  def test_a_chat_with_no_voice_option_has_no_mic_even_signed_in
    sign_in(@sam)
    get "/agent_chat_lab"

    assert_response :success
    assert_select MIC, 0
    assert_select '[data-test="agent-chat-voice-privacy"]', 0
    assert_select "[data-studio-controller~='voice-recorder']", 0
    assert_no_match(/studio-agent-voice/, response.body)
  end

  def test_a_signed_out_visitor_never_sees_the_mic
    get "/agent_chat_voice_lab"

    assert_response :success
    assert_select '[data-test="agent-chat"]', 1
    assert_select MIC, 0
    assert_select '[data-test="agent-chat-voice-privacy"]', 0
  end

  def test_a_hook_that_says_yes_to_everyone_still_shows_a_signed_out_visitor_no_mic
    with_voice_hook(->(_user) { true }) do
      get "/agent_chat_voice_lab"
      assert_select MIC, 0
    end
  end

  def test_a_signed_in_user_gets_the_mic_in_the_composer_with_the_privacy_line
    sign_in(@sam)
    get "/agent_chat_voice_lab"

    assert_response :success
    mic = css_select(MIC)
    assert_equal 1, mic.size
    assert_equal "agent-chat-voice", mic.first["data-studio-controller"]
    assert_equal "/voice/takes", mic.first["data-agent-chat-voice-takes-url"]
    assert_equal "alex", mic.first["data-agent-chat-voice-soul"]
    assert_equal "Alex", mic.first["data-agent-chat-voice-name"]
    assert_nil mic.first["data-agent-chat-voice-embedder"], "no saved voice, no model to download"
    assert_select "#{MIC} [data-studio-controller='voice-recorder'][data-voice-recorder-mode='hold'] button", text: "Hold to talk"
    assert_select "#{MIC} [data-studio-controller='microphone-chip'] .studio-mic-chip", text: /Microphone: hold to talk to allow/
    assert_select "#{MIC} [data-test='agent-chat-voice-status'][role='status']", 1
    assert_select "#{MIC} .studio-agent-voice-failed", 1
    assert_select '[data-test="agent-chat-voice-privacy"]', text: PRIVACY, count: 1
  end

  def test_the_privacy_line_is_overridable_and_blank_is_never_none
    sign_in(@sam)
    get "/agent_chat_voice_lab", params: { copy: "1" }

    assert_select '[data-test="agent-chat-voice-privacy"]', text: "This app's own privacy line.", count: 1
  end

  def test_the_hook_narrows_the_mic
    sign_in(@sam)
    with_voice_hook(->(user) { user.admin? }) do
      get "/agent_chat_voice_lab"
      assert_select MIC, 0

      @sam.update!(role: "admin")
      get "/agent_chat_voice_lab"
      assert_select MIC, 1
    end
  end

  def test_a_hook_that_raises_shows_no_mic_and_the_page_stands
    sign_in(@sam)
    with_voice_hook(->(_user) { raise "gate broke" }) do
      get "/agent_chat_voice_lab"
      assert_response :success
      assert_select MIC, 0
    end
  end

  def test_an_app_with_takes_off_shows_no_mic
    sign_in(@sam)
    Studio.voice_transcription = false
    get "/agent_chat_voice_lab"

    assert_response :success
    assert_select MIC, 0
  ensure
    Studio.voice_transcription = true
  end

  def test_the_page_names_the_embedder_only_for_a_voice_the_apps_own_embedder_saved
    helper = Object.new.extend(Studio::AgentChatHelper)
    person = Struct.new(:voice_embedding, :voice_embedding_model)
    own = Studio::VoiceMatch.model_id(Studio.voice_embedder.to_s)

    assert_equal own, JSON.parse(helper.studio_agent_chat_embedder(person.new([0.1], own)))["id"]
    assert_nil helper.studio_agent_chat_embedder(person.new([0.1], "another-model"))
    assert_nil helper.studio_agent_chat_embedder(person.new(nil, own))
    assert_nil helper.studio_agent_chat_embedder(@sam), "a host with no voice columns"
    assert_nil helper.studio_agent_chat_embedder(nil)
  end

  # ── the page's two tokens, with forgery on ──────────────────

  # Sign in BEFORE turning forgery on: the test door posts with no token.
  def tokens_off_the_voice_lab
    get "/agent_chat_voice_lab"
    assert_response :success
    [css_select("meta[name='csrf-token']").first["content"],
     css_select("form[data-test='agent-chat-form'] input[name='authenticity_token']").first["value"]]
  end

  def post_take_with(token)
    audio = Rack::Test::UploadedFile.new(StringIO.new("\x1A\x45\xDF\xA3audio".b), "audio/webm", true, original_filename: "take")
    post "/voice/takes", params: { voice: { audio: audio, mime_type: "audio/webm", duration_ms: 900 } },
                         headers: { "Accept" => "application/json", "X-CSRF-Token" => token }
    response.status
  rescue ActionController::InvalidAuthenticityToken
    :invalid_token
  end

  def test_with_forgery_on_a_take_passes_on_the_meta_token_and_is_refused_on_the_chat_forms
    sign_in(@sam)
    ActionController::Base.allow_forgery_protection = true
    meta, form = tokens_off_the_voice_lab
    refute_equal meta, form, "the form's token is per-form under load_defaults 8.1"

    assert_equal 200, post_take_with(meta)
    assert_includes [:invalid_token, 422], post_take_with(form), "the reason the script reads the meta tag first"
  end

  def test_with_forgery_on_the_chat_post_passes_on_the_meta_token
    sign_in(@sam)
    ActionController::Base.allow_forgery_protection = true
    meta, = tokens_off_the_voice_lab
    @hub.respond { [201, { "turn" => { "id" => 9 } }] }

    post "/agent_chat/messages", params: { soul: "alex", text: "Spoken", voice: VOICE }.to_json,
                                 headers: json_headers.merge("X-CSRF-Token" => meta)
    assert_response :created
  end

  # ── voice through the proxy ─────────────────────────────────

  VOICE = { check: "matched", score: 0.8731, duration_ms: 2140 }.freeze

  def post_voice(voice, text: "Spoken words")
    post "/agent_chat/messages", params: { soul: "alex", text: text, voice: voice }.to_json, headers: json_headers
  end

  def test_a_spoken_message_reaches_the_hub_with_the_exact_payload_and_answers_what_the_hub_kept
    sign_in(@sam)
    @hub.respond { [201, { "turn" => { "id" => 9, "role" => "user", "text" => "Spoken words", "status" => "pending" },
                           "voice" => { "speaker" => "Sam", "check" => "matched" } }] }
    post_voice(VOICE)

    assert_response :created
    assert_equal({ "check" => "matched", "score" => 0.8731, "duration_ms" => 2140 }, @hub.requests.last.json["voice"])
    assert_equal "sam@example.com", @hub.requests.last.json.dig("person", "email")
    body = JSON.parse(response.body)
    assert_equal "Sam", body.dig("voice", "speaker")
    refute body["turn"].key?("voice"), "the turn stays a turn"
  end

  def test_a_browser_chosen_name_is_never_forwarded
    sign_in(@sam)
    @hub.respond { [201, { "turn" => { "id" => 9 } }] }
    post_voice(VOICE.merge(speaker: "Alex McRitchie", name: "Alex McRitchie", identified: true))

    assert_response :created
    assert_equal %w[check duration_ms score], @hub.requests.last.json["voice"].keys.sort
    assert_no_match(/Alex McRitchie/, @hub.requests.last.body)
  end

  def test_a_typed_message_carries_no_voice_and_answers_no_voice
    sign_in(@sam)
    @hub.respond { [201, { "turn" => { "id" => 9 } }] }
    post "/agent_chat/messages", params: { soul: "alex", text: "Typed" }.to_json, headers: json_headers

    assert_response :created
    refute @hub.requests.last.json.key?("voice")
    refute JSON.parse(response.body).key?("voice")
  end

  def test_a_signed_out_visitor_voice_is_dropped_and_the_words_still_go
    @hub.respond { [201, { "turn" => { "id" => 9 } }] }
    post_voice(VOICE)

    assert_response :created
    refute @hub.requests.last.json.key?("voice")
    assert_equal "Spoken words", @hub.requests.last.json["text"]
  end

  def test_a_user_the_hook_refuses_has_their_voice_dropped
    sign_in(@sam)
    @hub.respond { [201, { "turn" => { "id" => 9 } }] }
    with_voice_hook(->(_user) { false }) { post_voice(VOICE) }

    assert_response :created
    refute @hub.requests.last.json.key?("voice")
  end

  def test_a_malformed_voice_is_a_422_not_a_500_and_the_hub_is_never_asked
    sign_in(@sam)
    before = @hub.requests.size
    ["abc", ["matched"], { check: "trust-me" }, { score: 0.5 }].each do |bad|
      post_voice(bad)
      assert_response :unprocessable_entity, bad.inspect
      assert_kind_of String, JSON.parse(response.body)["error"]
    end
    assert_equal before, @hub.requests.size
  end

  # ── 2. signed in ────────────────────────────────────────────

  def test_a_signed_in_message_reaches_the_hub_as_the_users_email_with_the_ip
    sign_in(@sam)
    post "/agent_chat/messages", params: { soul: "alex", text: "  Hello  ", person: { email: "boss@example.com" },
                                           ip: "1.1.1.1" }.to_json,
                                 headers: json_headers.merge("REMOTE_ADDR" => "203.0.113.9")

    assert_response :created
    assert_equal({ "turn" => TURN }, response.parsed_body)
    sent = @hub.requests.last
    assert_equal "/api/v1/agent_chat/messages", sent.path
    assert_equal "Bearer app-credential", sent.headers["authorization"]
    assert_equal({ "soul" => "alex", "text" => "Hello", "person" => { "email" => "sam@example.com" },
                   "ip" => "203.0.113.9" }, sent.json)
    assert_nil cookies[Studio::AgentChatsController::ANON_COOKIE.to_s], "a signed-in visitor gets no anon cookie"
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  def test_a_signed_in_post_with_an_anon_cookie_sends_both_so_the_hub_folds_the_thread_then_clears_it
    post "/agent_chat/messages", params: { soul: "alex", text: "Before sign-in" }.to_json, headers: json_headers
    assert_response :created
    anon = @hub.requests.last.json.dig("person", "anon_token")
    assert anon.present?
    refute cookies["studio_agent_chat_anon"].blank?

    sign_in(@sam)
    post "/agent_chat/messages", params: { soul: "alex", text: "Signed in now" }.to_json, headers: json_headers

    assert_response :created
    assert_equal({ "email" => "sam@example.com", "anon_token" => anon }, @hub.requests.last.json["person"])
    assert cookies["studio_agent_chat_anon"].blank?, "the anon cookie is spent once the hub has folded the thread"

    post "/agent_chat/messages", params: { soul: "alex", text: "And again" }.to_json, headers: json_headers
    assert_equal({ "email" => "sam@example.com" }, @hub.requests.last.json["person"], "folded once")
  end

  def test_a_signed_in_post_without_an_anon_cookie_sends_the_email_only_and_mints_nothing
    sign_in(@sam)
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_response :created
    assert_equal({ "email" => "sam@example.com" }, @hub.requests.last.json["person"])
    refute_match(/studio_agent_chat_anon=/, Array(response.headers["Set-Cookie"]).join("\n"))
  end

  def test_a_signed_in_post_the_hub_refuses_keeps_the_anon_cookie_for_the_next_try
    post "/agent_chat/messages", params: { soul: "alex", text: "Before sign-in" }.to_json, headers: json_headers
    anon = @hub.requests.last.json.dig("person", "anon_token")
    sign_in(@sam)
    @hub.respond { [502, "<html>Bad gateway</html>"] }
    post "/agent_chat/messages", params: { soul: "alex", text: "Signed in now" }.to_json, headers: json_headers
    assert_response :service_unavailable
    refute cookies["studio_agent_chat_anon"].blank?, "no fold happened, so the thread's token is kept"

    @hub.respond { [201, { "turn" => TURN }] }
    post "/agent_chat/messages", params: { soul: "alex", text: "Retry" }.to_json, headers: json_headers
    assert_equal anon, @hub.requests.last.json.dig("person", "anon_token")
  end

  def test_signed_in_turns_send_the_email_only_even_with_an_anon_cookie
    post "/agent_chat/messages", params: { soul: "alex", text: "Before sign-in" }.to_json, headers: json_headers
    sign_in(@sam)
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal({ "email" => "sam@example.com" }, @hub.requests.last.query["person"])
  end

  # ── an UNVERIFIED email names no one ─────────────────────────
  # The profile page saves a new address directly and clears email_verified_at;
  # password signup saves any address. Such an email is a claim, not a proof:
  # sent to the hub it would open that person's thread on every app.

  def test_an_unverified_signed_in_user_chats_as_anonymous_and_never_sends_the_email
    sign_in(@eve)
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers

    assert_response :created
    person = @hub.requests.last.json["person"]
    assert_equal ["anon_token"], person.keys
    refute_includes @hub.requests.last.body, "victim@example.com"
    refute cookies["studio_agent_chat_anon"].blank?, "an unverified user gets the anon cookie, as signed out"

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal({ "anon_token" => person["anon_token"] }, @hub.requests.last.query["person"])
  end

  def test_an_unverified_signed_in_user_with_no_thread_is_answered_without_the_hub
    sign_in(@eve)
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal({ "turns" => [], "pending" => false }, response.parsed_body)
    assert_empty @hub.requests
  end

  def test_a_user_whose_model_has_no_email_verified_at_is_anonymous
    User.connection.remove_column(:users, :email_verified_at)
    User.reset_column_information
    sign_in(User.create!(email: "nocol@example.com", name: "No Column"))
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_equal ["anon_token"], @hub.requests.last.json["person"].keys
  ensure
    User.connection.add_column(:users, :email_verified_at, :datetime) unless User.column_names.include?("email_verified_at")
    User.reset_column_information
  end

  def test_the_app_hook_decides_the_verified_email_when_set
    Studio.agent_chat_verified_email = ->(user) { user.name == "Eve" ? "eve@proven.example" : nil }
    sign_in(@eve)
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_equal({ "email" => "eve@proven.example" }, @hub.requests.last.json["person"])

    sign_in(@sam)
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_equal ["anon_token"], @hub.requests.last.json["person"].keys, "the hook answered nil: anonymous"
  end

  def test_signed_in_turns_are_asked_for_by_email_with_after_and_limit
    sign_in(@sam)
    get "/agent_chat/turns", params: { soul: "alex", after: "40", limit: "10" }, headers: { "Accept" => "application/json" }

    assert_response :success
    assert_equal({ "turns" => [TURN], "pending" => true }, response.parsed_body)
    assert_equal({ "soul" => "alex", "person" => { "email" => "sam@example.com" }, "after" => "40", "limit" => "10" },
                 @hub.requests.last.query)
  end

  def test_an_after_that_is_not_an_id_is_dropped
    sign_in(@sam)
    get "/agent_chat/turns", params: { soul: "alex", after: "1 OR 1=1" }
    refute @hub.requests.last.query.key?("after")
  end

  # ── 3. signed out ───────────────────────────────────────────

  def test_a_signed_out_visitor_who_never_wrote_is_answered_without_the_hub
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_response :success
    assert_equal({ "turns" => [], "pending" => false }, response.parsed_body)
    assert_empty @hub.requests
  end

  def test_a_signed_out_message_mints_a_signed_httponly_cookie_and_reuses_its_token
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers

    assert_response :created
    first = @hub.requests.last.json["person"]
    assert_equal ["anon_token"], first.keys
    assert_match(/\A[A-Za-z0-9_-]{43}\z/, first["anon_token"])
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    assert_match(/studio_agent_chat_anon=/, set_cookie)
    assert_match(/httponly/i, set_cookie)
    assert_match(/samesite=lax/i, set_cookie)
    refute_includes cookies["studio_agent_chat_anon"].to_s, first["anon_token"], "the cookie is signed, not the bare token"

    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal({ "anon_token" => first["anon_token"] }, @hub.requests.last.query["person"])

    post "/agent_chat/messages", params: { soul: "alex", text: "Again" }.to_json, headers: json_headers
    assert_equal first, @hub.requests.last.json["person"], "one anonymous thread per browser"
  end

  def test_a_forged_anon_cookie_is_not_trusted
    cookies["studio_agent_chat_anon"] = "x" * 43
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_equal({ "turns" => [], "pending" => false }, response.parsed_body)
    assert_empty @hub.requests, "an unsigned cookie is no token"
  end

  # ── 4. the soul ─────────────────────────────────────────────

  def test_a_soul_off_the_allow_list_is_a_404_and_never_reaches_the_hub
    post "/agent_chat/messages", params: { soul: "mason", text: "Hi" }.to_json, headers: json_headers
    assert_response :not_found
    get "/agent_chat/turns", params: { soul: "mason" }
    assert_response :not_found
    assert_empty @hub.requests
  end

  def test_with_one_soul_on_the_list_a_request_naming_none_uses_it
    post "/agent_chat/messages", params: { text: "Hi" }.to_json, headers: json_headers
    assert_response :created
    assert_equal "alex", @hub.requests.last.json["soul"]
  end

  def test_with_several_souls_a_request_must_name_one
    Studio.agent_chat_souls = %w[alex ray]
    post "/agent_chat/messages", params: { text: "Hi" }.to_json, headers: json_headers
    assert_response :not_found
    post "/agent_chat/messages", params: { soul: "ray", text: "Hi" }.to_json, headers: json_headers
    assert_response :created
    assert_equal "ray", @hub.requests.last.json["soul"]
  end

  # ── 5. refusals, outages, CSRF ──────────────────────────────

  def test_a_blank_or_overlong_message_is_refused_before_the_hub
    post "/agent_chat/messages", params: { soul: "alex", text: "   " }.to_json, headers: json_headers
    assert_response :unprocessable_entity
    post "/agent_chat/messages", params: { soul: "alex", text: "x" * 4001 }.to_json, headers: json_headers
    assert_response :unprocessable_entity
    assert_empty @hub.requests
  end

  def test_the_hubs_422_reason_reaches_the_page
    @hub.respond { [422, { "error" => "That message is empty." }] }
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_response :unprocessable_entity
    assert_equal "That message is empty.", response.parsed_body["error"]
  end

  def test_a_capped_visitor_gets_429_with_retry_after
    @hub.respond { [429, { "error" => "capped" }, { "Retry-After" => "60" }] }
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    assert_equal 60, response.parsed_body["retry_after"]
  end

  def test_a_hub_404_is_a_404
    @hub.respond { [404, { "error" => "no web chat" }] }
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_response :not_found
  end

  def test_a_hub_that_is_down_is_a_friendly_503_with_retry
    port = @hub.port
    @hub.stop
    Studio.agent_chat_hub_url = "http://127.0.0.1:#{port}"
    sign_in(@sam)
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_response :service_unavailable
    assert_equal true, response.parsed_body["retry"]
    assert_match(/try again/i, response.parsed_body["error"])
  end

  def test_a_failed_send_is_an_error_log_row_and_a_failed_poll_is_not
    ErrorLog.delete_all
    @hub.respond { [502, "<html>Bad gateway</html>"] }
    sign_in(@sam)
    get "/agent_chat/turns", params: { soul: "alex" }
    assert_response :service_unavailable
    assert_equal 0, ErrorLog.count, "an open page polls every 15s through an outage; no row per poll"

    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_response :service_unavailable
    assert_equal 1, ErrorLog.count
    assert_match(/502/, ErrorLog.last.message)
  end

  def test_a_refused_app_credential_is_a_503_never_a_401_to_the_visitor
    @hub.respond { [401, { "error" => "unauthorized" }] }
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    assert_response :service_unavailable
    refute_includes response.body, "credential"
    assert_match(/credential/, ErrorLog.last.message, "a refused app credential is always an ErrorLog row")
  end

  def test_a_post_without_the_authenticity_token_is_refused
    ActionController::Base.allow_forgery_protection = true
    assert_raises(ActionController::InvalidAuthenticityToken) do
      post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json, headers: json_headers
    end
    assert_empty @hub.requests
  end

  def test_a_post_with_the_pages_token_is_accepted
    ActionController::Base.allow_forgery_protection = true
    get "/agent_chat_lab"
    token = css_select('form[data-test="agent-chat-form"] input[name="authenticity_token"]').first["value"]
    post "/agent_chat/messages", params: { soul: "alex", text: "Hi" }.to_json,
                                 headers: json_headers.merge("X-CSRF-Token" => token)
    assert_response :created
  end

  private

  def json_headers = { "Content-Type" => "application/json", "Accept" => "application/json" }
end
