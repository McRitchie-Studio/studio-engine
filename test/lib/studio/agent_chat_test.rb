# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/studio/agent_chat"
require_relative "../../support/agent_chat_stub_hub"

# [unit] Studio::AgentChat, the app's client for the hub's agent chat API
# (.agents/epics/agent-chat-primitive.md, "Contract"), against a stub hub on a
# real local socket: both calls and what each sends, the bearer credential,
# the bounded timeouts, and the mapping of every refusal to one error class.
class StudioAgentChatTest < Minitest::Test
  Chat = Studio::AgentChat
  TOKEN = "app-agent-chat-credential"
  TURN = { "id" => "41", "role" => "user", "text" => "Hello", "created_at" => "2026-10-27T10:00:00Z",
           "status" => "pending" }.freeze

  def setup
    @hub = AgentChatStubHub.start
    @saved = { url: Studio.agent_chat_hub_url, token: Studio.agent_chat_token, env: ENV.fetch("AGENT_CHAT_TOKEN", nil) }
    Studio.agent_chat_hub_url = @hub.url
    Studio.agent_chat_token = TOKEN
    ENV.delete("AGENT_CHAT_TOKEN")
  end

  def teardown
    @hub.stop
    Studio.agent_chat_hub_url = @saved[:url]
    Studio.agent_chat_token = @saved[:token]
    @saved[:env] ? ENV["AGENT_CHAT_TOKEN"] = @saved[:env] : ENV.delete("AGENT_CHAT_TOKEN")
  end

  # ── POST /api/v1/agent_chat/messages ─────────────────────────

  def test_post_message_sends_the_contract_body_and_answers_the_turn
    @hub.respond { [201, { "turn" => TURN }] }

    turn = Chat.post_message(soul: "alex", text: "Hello", person: { email: "sam@example.com" }, ip: "203.0.113.9")

    assert_equal TURN, turn
    request = @hub.requests.last
    assert_equal "POST", request.method
    assert_equal "/api/v1/agent_chat/messages", request.path
    assert_equal "Bearer #{TOKEN}", request.headers["authorization"]
    assert_equal "application/json", request.headers["content-type"]
    assert_equal({ "soul" => "alex", "text" => "Hello", "person" => { "email" => "sam@example.com" },
                   "ip" => "203.0.113.9" }, request.json)
  end

  def test_post_message_sends_an_anon_token_for_a_signed_out_person
    @hub.respond { [201, { "turn" => TURN }] }
    Chat.post_message(soul: "alex", text: "Hi", person: { anon_token: "a" * 43 }, ip: "203.0.113.9")

    assert_equal({ "anon_token" => "a" * 43 }, @hub.requests.last.json["person"])
  end

  def test_post_message_sends_both_email_and_anon_token_when_given_both_so_the_hub_can_fold
    @hub.respond { [201, { "turn" => TURN }] }
    Chat.post_message(soul: "alex", text: "Hi", person: { email: "sam@example.com", anon_token: "a" * 43 })

    assert_equal({ "email" => "sam@example.com", "anon_token" => "a" * 43 }, @hub.requests.last.json["person"])
  end

  def test_the_stand_in_hub_folds_an_anon_thread_into_the_persons_on_a_post_naming_both
    @hub.converse!(answer_after: 0)
    anon = { anon_token: "a" * 43 }
    Chat.post_message(soul: "alex", text: "Before sign-in", person: anon)
    Chat.post_message(soul: "alex", text: "Signed in now", person: anon.merge(email: "sam@example.com"))
    sleep 0.1

    texts = Chat.turns(soul: "alex", person: { email: "sam@example.com" })["turns"].select { |t| t["role"] == "user" }.map { |t| t["text"] }
    assert_equal ["Before sign-in", "Signed in now"], texts
    assert_empty Chat.turns(soul: "alex", person: anon)["turns"]
  end

  def test_a_person_with_neither_email_nor_token_is_refused_before_any_request
    assert_raises(ArgumentError) { Chat.post_message(soul: "alex", text: "Hi", person: {}) }
    assert_empty @hub.requests
  end

  # ── GET /api/v1/agent_chat/turns ─────────────────────────────

  def test_turns_sends_soul_person_after_and_limit_and_answers_turns_and_pending
    @hub.respond { [200, { "turns" => [TURN], "pending" => true }] }

    answer = Chat.turns(soul: "alex", person: { email: "sam@example.com" }, after: "40", limit: 20)

    assert_equal({ "turns" => [TURN], "pending" => true }, answer)
    request = @hub.requests.last
    assert_equal "GET", request.method
    assert_equal "/api/v1/agent_chat/turns", request.path
    assert_equal "Bearer #{TOKEN}", request.headers["authorization"]
    assert_equal({ "soul" => "alex", "person" => { "email" => "sam@example.com" }, "after" => "40", "limit" => "20" },
                 request.query)
  end

  def test_turns_omits_after_when_none_and_clamps_the_limit_to_fifty
    Chat.turns(soul: "alex", person: { anon_token: "t" * 43 }, limit: 500)
    query = @hub.requests.last.query
    refute query.key?("after")
    assert_equal "50", query["limit"]

    Chat.turns(soul: "alex", person: { anon_token: "t" * 43 }, limit: 0)
    assert_equal "1", @hub.requests.last.query["limit"]
  end

  def test_turns_reads_pending_as_true_only_when_the_hub_says_true
    @hub.respond { [200, { "turns" => [TURN, "junk"], "pending" => "yes" }] }
    answer = Chat.turns(soul: "alex", person: { email: "sam@example.com" })

    assert_equal false, answer["pending"]
    assert_equal [TURN], answer["turns"], "a turn that is not an object is dropped"
  end

  def test_a_turns_answer_with_no_turns_array_is_unavailable
    @hub.respond { [200, { "pending" => false }] }
    assert_raises(Chat::Unavailable) { Chat.turns(soul: "alex", person: { email: "sam@example.com" }) }
  end

  # ── Error mapping ────────────────────────────────────────────

  def test_401_is_unauthorized
    @hub.respond { [401, { "error" => "unauthorized" }] }
    error = assert_raises(Chat::Unauthorized) { post }
    assert_equal 401, error.status
    assert_kind_of Chat::Error, error
  end

  def test_404_is_unknown_soul
    @hub.respond { [404, { "error" => "no web chat for nobody" }] }
    error = assert_raises(Chat::UnknownSoul) { post }
    assert_equal 404, error.status
  end

  def test_422_is_invalid_and_carries_the_hubs_reason
    @hub.respond { [422, { "error" => "Message is too long" }] }
    error = assert_raises(Chat::Invalid) { post }
    assert_equal "Message is too long", error.message
  end

  def test_429_is_capped_with_retry_after
    @hub.respond { [429, { "error" => "capped" }, { "Retry-After" => "30" }] }
    error = assert_raises(Chat::Capped) { post }
    assert_equal 30, error.retry_after
    assert_equal 429, error.status
  end

  def test_429_without_a_numeric_retry_after_has_none
    @hub.respond { [429, "<html>slow down</html>"] }
    assert_nil assert_raises(Chat::Capped) { post }.retry_after
  end

  def test_a_5xx_with_an_html_page_is_unavailable
    @hub.respond { [502, "<html>Bad gateway</html>"] }
    error = assert_raises(Chat::Unavailable) { post }
    assert_equal 502, error.status
  end

  def test_a_2xx_that_is_not_json_is_unavailable
    @hub.respond { [201, "<html>login</html>"] }
    assert_raises(Chat::Unavailable) { post }
  end

  # ── Bounds and configuration ─────────────────────────────────

  def test_a_hub_slower_than_the_read_timeout_is_unavailable_and_asked_once
    @hub.respond { sleep 1.5; [200, { "turns" => [], "pending" => false }] }
    with_const(:READ_TIMEOUT, 0.3) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Chat::Unavailable) { Chat.turns(soul: "alex", person: { email: "sam@example.com" }) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.2
    end
    sleep 1.4
    assert_equal 1, @hub.requests.size, "no silent retry of the GET"
  end

  def test_every_connection_is_bounded
    http = Chat.send(:http_for, URI("https://mcritchie.studio/api/v1/agent_chat/turns"))
    assert_equal Chat::OPEN_TIMEOUT, http.open_timeout
    assert_equal Chat::READ_TIMEOUT, http.read_timeout
    assert_equal Chat::WRITE_TIMEOUT, http.write_timeout
    assert_equal 0, http.max_retries
    assert http.use_ssl?
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_operator Chat::OPEN_TIMEOUT, :<=, 5
    assert_operator Chat::READ_TIMEOUT, :<=, 10
  end

  def test_a_refused_connection_is_unavailable
    port = @hub.port
    @hub.stop
    Studio.agent_chat_hub_url = "http://127.0.0.1:#{port}"
    assert_raises(Chat::Unavailable) { post }
  end

  def test_no_token_is_unavailable_and_sends_nothing
    Studio.agent_chat_token = nil
    assert_raises(Chat::Unavailable) { post }
    assert_empty @hub.requests
  end

  def test_the_token_falls_back_to_the_env
    Studio.agent_chat_token = nil
    ENV["AGENT_CHAT_TOKEN"] = "from-env"
    @hub.respond { [201, { "turn" => TURN }] }
    post
    assert_equal "Bearer from-env", @hub.requests.last.headers["authorization"]
  end

  def test_plain_http_to_another_host_is_refused_so_the_credential_never_leaves_unencrypted
    Studio.agent_chat_hub_url = "http://mcritchie.studio"
    assert_raises(Chat::Unavailable) { post }
    Studio.agent_chat_hub_url = "not a url"
    assert_raises(Chat::Unavailable) { post }
  end

  def test_the_default_hub_is_the_studio_over_https
    source = File.read(File.expand_path("../../../lib/studio.rb", __dir__))
    assert_match(/mattr_accessor :agent_chat_hub_url, default: "https:\/\/mcritchie\.studio"/, source)
  end

  private

  def post
    Chat.post_message(soul: "alex", text: "Hello", person: { email: "sam@example.com" }, ip: "203.0.113.9")
  end

  def with_const(name, value)
    original = Chat.const_get(name)
    Chat.send(:remove_const, name)
    Chat.const_set(name, value)
    yield
  ensure
    Chat.send(:remove_const, name)
    Chat.const_set(name, original)
  end
end
