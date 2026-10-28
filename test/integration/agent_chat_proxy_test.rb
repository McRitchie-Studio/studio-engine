# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "json"
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
    @sam = User.create!(email: "sam@example.com", name: "Sam")
    @hub = AgentChatStubHub.start
    @saved = { url: Studio.agent_chat_hub_url, token: Studio.agent_chat_token, souls: Studio.agent_chat_souls }
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
    ActionController::Base.allow_forgery_protection = false
  end

  def sign_in(user)
    post "/agent_chat_test_sign_in/#{user.id}"
    assert_response :ok
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
