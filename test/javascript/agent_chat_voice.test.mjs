// [unit] studio/agent_chat_voice: hold to talk in the shared agent chat's
// composer. The refusal lines for every answer POST /voice/takes can give, the
// take's multipart body, the message's `voice` (never a name), and whole takes
// against a stand-in composer and fetch: embed when a saved voice is named,
// transcribe, send, hand the turn to the chat, and say the speaker the SERVER
// kept. Plus the two lines the hub's first version got wrong: the old "Sent." on
// a new hold, and a take recorded during transcription.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/agent_chat_voice.js", import.meta.url), "utf8")
const {
  MESSAGES, EMBED_WAIT_MS, csrfToken, mountAgentChatVoice, parseEmbedder, refusalFor, retryHint, takeForm, tokenRefused, voiceMetadata, wordsInBox, within
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

class StubFormData {
  constructor() { this.entries = [] }
  append(name, value, filename) { this.entries.push([name, value, filename]) }
  get(name) { const hit = this.entries.find(([n]) => n === name); return hit ? hit[1] : null }
  has(name) { return this.entries.some(([n]) => n === name) }
}

class StubEvent {
  constructor(type, init = {}) { this.type = type; this.detail = init.detail }
}

test("nothing is imported at load, and no line is written as HTML", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
  assert.doesNotMatch(source, /innerHTML|insertAdjacentHTML|outerHTML/)
})

test("refusals: each answer from /voice/takes has its own state and line", () => {
  assert.deepEqual(refusalFor(503, { error: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now.", reason: "not_configured" }),
    { state: "not_configured", message: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now." })
  assert.equal(refusalFor(503, { reason: "not_configured" }).message, MESSAGES.notConfigured, "an empty error still says voice is not set up")
  assert.deepEqual(refusalFor(422, { error: "I couldn't hear any words in that.", reason: "no_speech" }),
    { state: "no_speech", message: "I couldn't hear any words in that." })
  assert.deepEqual(refusalFor(503, { reason: "transcriber_failed", retry: true }), { state: "failed", message: MESSAGES.unavailable })
  assert.deepEqual(refusalFor(401, {}), { state: "refused", message: MESSAGES.signedOut })
  assert.deepEqual(refusalFor(403, { error: "Voice isn't available on your account yet.", reason: "not_allowed" }),
    { state: "refused", message: "Voice isn't available on your account yet." })
  assert.equal(refusalFor(413, { error: "That recording is too long to send." }).message, "That recording is too long to send.")
  assert.equal(refusalFor(500, { error: "<b>stack</b>" }).message, MESSAGES.failed, "an unexpected status never shows the server's words")
})

test("a refused CSRF token reads as a reload hint, from the engine's answer or Rails' own", () => {
  const expired = { state: "refused", message: MESSAGES.expired }
  assert.match(MESSAGES.expired, /reload/i)
  assert.deepEqual(refusalFor(422, { error: "This page has expired. Reload it, then try again.", reason: "invalid_token" }), expired)
  assert.deepEqual(refusalFor(422, { status: 422, error: "Unprocessable Content" }), expired, "never Rails' words")
  assert.equal(tokenRefused(422, { error: "That recording was empty." }), false, "the take's own 422s keep their words")
  assert.equal(tokenRefused(500, { reason: "invalid_token" }), false)
  assert.equal(tokenRefused(422, null), false)
})

test("429: rate limited, with the wait from Retry-After or retry_after", () => {
  assert.deepEqual(refusalFor(429, {}, "40"), { state: "rate_limited", message: `${MESSAGES.rateLimited} Try again in 40 seconds.` })
  assert.equal(refusalFor(429, { retry_after: 600 }).message, `${MESSAGES.rateLimited} Try again in 10 minutes.`)
  assert.equal(refusalFor(429, {}).message, MESSAGES.rateLimited)
  assert.equal(retryHint(1), " Try again in 1 second.")
  assert.equal(retryHint(61), " Try again in 2 minutes.")
  assert.equal(retryHint("soon"), "")
})

test("voice: what the take measured, with safe defaults, and never a name", () => {
  assert.deepEqual(voiceMetadata({ text: "hi", speaker: "Alex", score: 0.91, identified: true, check: "matched", duration_ms: 2100 }),
    { check: "matched", score: 0.91, duration_ms: 2100 })
  assert.deepEqual(voiceMetadata({ text: "hi" }), { check: "no_embedding", score: null, duration_ms: null })
})

test("the take's body: audio, type and length always; the vector and model only together", () => {
  const blob = { size: 10 }
  const plain = takeForm({ blob, mimeType: "audio/webm;codecs=opus", durationMs: 1234.6 }, {}, StubFormData)
  assert.deepEqual(plain.entries, [["voice[audio]", blob, "take"], ["voice[mime_type]", "audio/webm;codecs=opus", undefined], ["voice[duration_ms]", "1235", undefined]])

  const embedded = takeForm({ blob, durationMs: 900 }, { embedding: [0.1, 0.2], model: "fake-256" }, StubFormData)
  assert.equal(embedded.get("voice[embedding]"), "[0.1,0.2]")
  assert.equal(embedded.get("voice[model]"), "fake-256")
  assert.equal(takeForm({ blob, durationMs: 0 }, { embedding: [0.1] }, StubFormData).has("voice[embedding]"), false, "no model, no vector")
  assert.equal(takeForm({ blob, durationMs: 0 }, {}, StubFormData).get("voice[duration_ms]"), "1")
})

test("the embedder config is read only when it names an embedder and its id", () => {
  assert.deepEqual(parseEmbedder('{"name":"fake","id":"fake-256","size":256}'), { name: "fake", id: "fake-256", size: 256 })
  assert.equal(parseEmbedder('{"name":"fake"}'), null)
  assert.equal(parseEmbedder("not json"), null)
  assert.equal(parseEmbedder(null), null)
})

test("the words go after a draft, never over it", () => {
  assert.equal(wordsInBox("", "spoken"), "spoken")
  assert.equal(wordsInBox("   ", "spoken"), "spoken")
  assert.equal(wordsInBox("my draft", "spoken"), "my draft\nspoken")
})

test("the CSRF token: the meta tag first, because the form's is bound to its own action", () => {
  const form = { querySelector: () => ({ value: "form-token" }) }
  const doc = { querySelector: () => ({ getAttribute: () => "meta-token" }) }
  const noMeta = { querySelector: () => null }
  assert.equal(csrfToken(form, doc), "meta-token")
  assert.equal(csrfToken(form, { querySelector: () => ({ getAttribute: () => "" }) }), "form-token", "an empty meta is no token")
  assert.equal(csrfToken(form, noMeta), "form-token")
  assert.equal(csrfToken({ querySelector: () => null }, noMeta), null)
  assert.equal(csrfToken(null, noMeta), null)
})

test("within: the promise's value, else the fallback once the wait is over", async () => {
  assert.equal(await within(Promise.resolve("yes"), 10, "no", () => {}), "yes")
  assert.equal(await within(new Promise(() => {}), 10, "no", (fn) => fn()), "no")
})

// A stand-in composer: the voice section inside the chat's form.
function composer({ embedder = null, draft = "" } = {}) {
  const status = { textContent: "", offsetHeight: 40, style: {} }
  const input = { value: draft }
  const refreshes = []
  const form = {
    getAttribute: () => "/agent_chat/messages",
    querySelector: (s) => (s === "[data-agent-chat-input]" ? input : s.includes("authenticity_token") ? { value: "form-token" } : null)
  }
  const chatListeners = {}
  const chat = {
    dispatchEvent: (event) => refreshes.push(event),
    addEventListener: (type, fn) => { chatListeners[type] = fn },
    removeEventListener: (type) => { delete chatListeners[type] }
  }
  const listeners = {}
  const root = {
    dataset: { agentChatVoiceSoul: "alex", agentChatVoiceName: "Alex", agentChatVoiceTakesUrl: "/voice/takes", agentChatVoiceState: "idle" },
    getAttribute: (name) => (name === "data-agent-chat-voice-embedder" ? embedder : null),
    querySelector: (s) => (s === "[data-agent-chat-voice-status]" ? status : null),
    closest: (s) => (s === "[data-agent-chat-form]" ? form : s === "[data-agent-chat-soul]" ? chat : null),
    addEventListener: (type, fn) => { listeners[type] = fn },
    removeEventListener: (type) => { delete listeners[type] }
  }
  return { root, status, input, refreshes, listeners, chatListeners, state: () => root.dataset.agentChatVoiceState }
}

function answer(status, body, headers = {}) {
  return { status, ok: status >= 200 && status < 300, json: async () => body, headers: { get: (name) => headers[name] ?? null } }
}

const HEARD = { text: "Hello Alex", speaker: "Pat", score: 0.91, identified: true, check: "matched", duration_ms: 2100 }
const TURN = { id: 7, role: "user", text: "Hello Alex", status: "pending" }
const take = (over = {}) => ({ blob: { size: 10 }, mimeType: "audio/webm", durationMs: 2100, ...over })

function mount(page, fetcher, extra = {}) {
  return mountAgentChatVoice(page.root, { fetch: fetcher, doc: { querySelector: () => null }, FormDataClass: StubFormData, CustomEventClass: StubEvent, setTimer: () => 0, ...extra })
}

function scripted(...answers) {
  const calls = []
  const fetcher = async (url, init) => {
    calls.push({ url, init })
    const next = answers.shift()
    if (next instanceof Error) throw next
    return typeof next === "function" ? next() : next
  }
  return { calls, fetcher }
}

test("a take with a saved voice: embedded, transcribed, sent with voice, handed to the chat; the line names who the server kept", async () => {
  const page = composer({ embedder: '{"name":"fake","id":"fake-256"}' })
  const { calls, fetcher } = scripted(answer(200, HEARD), answer(201, { turn: TURN, voice: { speaker: "Pat Kept" } }))
  const doc = { querySelector: (s) => (s.includes("csrf-token") ? { getAttribute: () => "meta-token" } : null) }
  const voice = mount(page, fetcher, { doc, loadEmbedder: async () => ({ id: "fake-256", embed: async () => [0.5, 0.5] }) })

  await voice.takeArrived(take())

  assert.equal(calls[0].url, "/voice/takes")
  assert.equal(calls[0].init.headers["X-CSRF-Token"], "meta-token", "POST /voice/takes refuses the chat form's own token")
  assert.equal(calls[0].init.body.get("voice[model]"), "fake-256")
  assert.equal(calls[0].init.body.get("voice[embedding]"), "[0.5,0.5]")
  assert.equal(calls[1].url, "/agent_chat/messages")
  assert.equal(calls[1].init.headers["X-CSRF-Token"], "meta-token")
  assert.deepEqual(JSON.parse(calls[1].init.body), { soul: "alex", text: "Hello Alex", voice: { check: "matched", score: 0.91, duration_ms: 2100 } })
  assert.equal(page.state(), "sent")
  assert.equal(page.status.textContent, "Sent. Spoken by Pat Kept.")
  assert.equal(page.input.value, "", "nothing left in the box")
  assert.equal(page.refreshes.length, 1, "the chat is told once")
  assert.equal(page.refreshes[0].type, "studio:agent-chat:refresh")
  assert.deepEqual(page.refreshes[0].detail, { turn: TURN })
})

test("a server that names nobody: plain Sent., and never the name the take answered", async () => {
  const page = composer()
  const { fetcher } = scripted(answer(200, HEARD), answer(201, { turn: TURN }))
  await mount(page, fetcher).takeArrived(take())
  assert.equal(page.status.textContent, MESSAGES.sentPlain)
})

test("no saved voice: no embedder loads and the take goes without a vector", async () => {
  const page = composer()
  let loads = 0
  const { calls, fetcher } = scripted(answer(200, HEARD), answer(201, { turn: TURN }))
  await mount(page, fetcher, { loadEmbedder: async () => { loads += 1 } }).takeArrived(take())
  assert.equal(loads, 0)
  assert.equal(calls[0].init.body.has("voice[embedding]"), false)
})

test("an embedder that fails, or is slower than the wait, still transcribes without a vector", async () => {
  for (const loadEmbedder of [async () => { throw new Error("no model") }, () => new Promise(() => {})]) {
    const page = composer({ embedder: '{"name":"fake","id":"fake-256"}' })
    const { calls, fetcher } = scripted(answer(200, HEARD), answer(201, { turn: TURN }))
    const waits = []
    const setTimer = (fn, ms) => { waits.push(ms); fn(); return 0 }
    await mount(page, fetcher, { loadEmbedder, setTimer }).takeArrived(take())
    assert.equal(calls[0].init.body.has("voice[embedding]"), false)
    assert.equal(page.state(), "sent")
    assert.ok(waits.includes(EMBED_WAIT_MS))
  }
})

test("every refused take sends nothing, says why, and leaves the box alone", async () => {
  const cases = [
    [answer(422, { error: "I couldn't hear any words in that.", reason: "no_speech" }), "no_speech", "I couldn't hear any words in that."],
    [answer(503, { error: "Voice isn't set up.", reason: "not_configured" }), "not_configured", "Voice isn't set up."],
    [answer(503, { error: "I couldn't transcribe that just now.", reason: "transcriber_failed", retry: true }), "failed", "I couldn't transcribe that just now."],
    [answer(429, { retry_after: 60 }, { "Retry-After": "60" }), "rate_limited", `${MESSAGES.rateLimited} Try again in 1 minute.`],
    [answer(401, { error: "unauthenticated" }), "refused", MESSAGES.signedOut],
    [answer(200, { text: "   " }), "no_speech", MESSAGES.noSpeech]
  ]
  for (const [reply, state, line] of cases) {
    const page = composer()
    const { calls, fetcher } = scripted(reply)
    await mount(page, fetcher).takeArrived(take())
    assert.equal(calls.length, 1, `${state}: nothing is sent to the chat`)
    assert.equal(page.state(), state)
    assert.equal(page.status.textContent, line)
    assert.equal(page.input.value, "")
    assert.equal(page.refreshes.length, 0)
  }
})

test("a network failure on the take says the server can't be reached", async () => {
  const page = composer()
  const { fetcher } = scripted(new Error("offline"))
  await mount(page, fetcher).takeArrived(take())
  assert.equal(page.state(), "failed")
  assert.equal(page.status.textContent, MESSAGES.offline)
})

test("a send that fails puts the words in the box and says so: refused, capped, or no network", async () => {
  const cases = [
    [answer(503, { error: "Can't reach the chat right now.", retry: true }), "failed", `Can't reach the chat right now. ${MESSAGES.notSent("Alex")}`],
    [answer(429, { error: "You've sent a lot of messages." }), "rate_limited", `You've sent a lot of messages. ${MESSAGES.notSent("Alex")}`],
    [new Error("offline"), "failed", MESSAGES.notSent("Alex")]
  ]
  for (const [reply, state, line] of cases) {
    const page = composer()
    const { fetcher } = scripted(answer(200, HEARD), reply)
    await mount(page, fetcher).takeArrived(take())
    assert.equal(page.input.value, "Hello Alex")
    assert.equal(page.state(), state)
    assert.equal(page.status.textContent, line)
    assert.equal(page.refreshes.length, 0)
  }
})

test("a send refused for its token keeps the words and says to reload, never to press send", async () => {
  const page = composer()
  const { fetcher } = scripted(answer(200, HEARD), answer(422, { error: "This page has expired. Reload it, then try again.", reason: "invalid_token" }))
  await mount(page, fetcher).takeArrived(take())
  assert.equal(page.input.value, "Hello Alex")
  assert.equal(page.state(), "refused")
  assert.equal(page.status.textContent, MESSAGES.expiredSend)
  assert.doesNotMatch(page.status.textContent, /press send/)
})

test("a take refused for its token says to copy first when the box holds words a reload would clear", async () => {
  const refused = answer(422, { error: "This page has expired. Reload it, then try again.", reason: "invalid_token" })
  const page = composer({ draft: "the last take, kept" })
  await mount(page, scripted(refused).fetcher).takeArrived(take())
  assert.equal(page.state(), "refused")
  assert.equal(page.status.textContent, MESSAGES.expiredSend)
  assert.equal(page.input.value, "the last take, kept")

  const empty = composer()
  await mount(empty, scripted(refused).fetcher).takeArrived(take())
  assert.equal(empty.status.textContent, MESSAGES.expired)
})

test("a failed send keeps a typed draft and adds the words after it", async () => {
  const page = composer({ draft: "half a thought" })
  const { fetcher } = scripted(answer(200, HEARD), answer(503, {}))
  await mount(page, fetcher).takeArrived(take())
  assert.equal(page.input.value, "half a thought\nHello Alex")
})

test("a new hold clears the old line, and letting go with no take does not leave it Listening", () => {
  const page = composer()
  mount(page, async () => answer(200, {}))
  page.status.textContent = "Sent. Spoken by Pat."
  page.root.dataset.agentChatVoiceState = "sent"

  page.listeners["studio:voice-recorder:state"]({ detail: { state: "starting" } })
  assert.equal(page.status.textContent, "", "gone the moment the person presses")

  page.listeners["studio:voice-recorder:state"]({ detail: { state: "recording" } })
  assert.equal(page.state(), "listening")
  assert.equal(page.status.textContent, MESSAGES.listening)

  page.listeners["studio:voice-recorder:state"]({ detail: { state: "idle" } })
  assert.equal(page.state(), "idle")
  assert.equal(page.status.textContent, "")
})

test("mounting clears the line: a restored page shows no old take", () => {
  const page = composer()
  page.status.textContent = "Sent. Spoken by Pat."
  page.root.dataset.agentChatVoiceState = "sent"
  mount(page, async () => answer(200, {}))
  assert.equal(page.status.textContent, "")
  assert.equal(page.state(), "idle")
})

test("a recorder's hint speaks on the one line; a blank one does not wipe it", () => {
  const page = composer()
  mount(page, async () => answer(200, {}))
  page.listeners["studio:voice-recorder:state"]({ detail: { state: "recording" } })
  page.listeners["studio:voice-recorder:hint"]({ detail: { kind: "heard", text: "" } })
  assert.equal(page.status.textContent, MESSAGES.listening)
  page.listeners["studio:voice-recorder:hint"]({ detail: { kind: "quiet", text: "I can't hear anything yet." } })
  assert.equal(page.status.textContent, "I can't hear anything yet.")
  assert.equal(page.state(), "listening")
  // Then the person speaks: the line takes the quiet hint back.
  page.listeners["studio:voice-recorder:hint"]({ detail: { kind: "heard", text: "" } })
  assert.equal(page.status.textContent, MESSAGES.listening)
})

test("a blank hint does not wipe a line a take in hand has written", () => {
  const page = composer()
  mount(page, async () => answer(200, {}))
  page.status.textContent = "Sending to Alex..."
  page.listeners["studio:voice-recorder:hint"]({ detail: { kind: "heard", text: "" } })
  assert.equal(page.status.textContent, "Sending to Alex...")
})

test("a silent take only says so", async () => {
  const page = composer()
  const { calls, fetcher } = scripted()
  mount(page, fetcher)
  page.listeners["studio:voice-recorder:silent"]({ detail: {} })
  assert.equal(page.state(), "silent")
  assert.equal(page.status.textContent, "I couldn't hear anything. Check your microphone and hold to talk again.")
  page.listeners["studio:voice-recorder:silent"]({ detail: { microphone: { label: "Arctis" } } })
  assert.equal(page.status.textContent, "I couldn't hear anything from Arctis. Check your microphone and hold to talk again.")
  assert.equal(calls.length, 0)
})

test("a take recorded during transcription is not dropped: the line says so and it goes next, in order", async () => {
  const page = composer()
  let release
  const held = new Promise((resolve) => { release = resolve })
  const { calls, fetcher } = scripted(
    () => held,
    answer(201, { turn: { ...TURN, id: 1 } }),
    answer(200, { ...HEARD, text: "Second thought" }),
    answer(201, { turn: { ...TURN, id: 2 } })
  )
  const voice = mount(page, fetcher)

  const first = voice.takeArrived(take())
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(calls.length, 1, "the first take is with the server")

  await voice.takeArrived(take({ durationMs: 900 }))
  assert.equal(page.state(), "queued")
  assert.equal(page.status.textContent, MESSAGES.queued)
  assert.equal(calls.length, 1, "one at a time")

  release(answer(200, HEARD))
  await first

  assert.equal(calls.length, 4, "both takes were transcribed and sent")
  assert.equal(calls[2].init.body.get("voice[duration_ms]"), "900")
  assert.deepEqual(calls.filter((call) => call.url === "/agent_chat/messages").map((call) => JSON.parse(call.init.body).text), ["Hello Alex", "Second thought"])
  assert.deepEqual(page.refreshes.map((event) => event.detail.turn.id), [1, 2])
  assert.equal(page.state(), "sent")
})

test("a take that lands after an unmount goes nowhere", async () => {
  const page = composer()
  const { calls, fetcher } = scripted()
  const voice = mount(page, fetcher)
  voice.destroy()
  assert.deepEqual(page.listeners, {})
  assert.equal(calls.length, 0)
})

const recorderSays = (page, state) => page.listeners["studio:voice-recorder:state"]({ detail: { state } })

test("a tap says to hold, on the one line, with the recorder's own words when it has them", () => {
  const page = composer()
  mount(page, async () => answer(200, {}))
  recorderSays(page, "tapped")
  assert.equal(page.state(), "tapped")
  assert.equal(page.status.textContent, MESSAGES.tapped)
  assert.doesNotMatch(MESSAGES.tapped, /microphone/i, "a tap is not the microphone's fault")
})

test("a recorder that failed or was refused speaks on the one line: its own line would move the button", () => {
  const page = composer()
  const own = { textContent: "Your microphone is busy in another app." }
  const query = page.root.querySelector
  page.root.querySelector = (s) => (s === "[data-voice-recorder-status]" ? own : query(s))
  mount(page, async () => answer(200, {}))
  recorderSays(page, "failed")
  assert.equal(page.state(), "failed")
  assert.equal(page.status.textContent, own.textContent)
  own.textContent = "Allow the microphone to record."
  recorderSays(page, "denied")
  assert.equal(page.state(), "refused")
  assert.equal(page.status.textContent, own.textContent)
})

// CONTROL: remove the sent listener in mountAgentChatVoice and the first assert fails.
test("a later typed send clears the line a take left; a take in hand or a hold keeps its own", async () => {
  const page = composer()
  const { fetcher } = scripted(answer(200, HEARD), answer(201, { turn: TURN, voice: { speaker: "Pat" } }))
  mount(page, fetcher)
  page.status.textContent = "Sent. Spoken by Pat."
  page.root.dataset.agentChatVoiceState = "sent"
  page.chatListeners["studio:agent-chat:sent"]({ detail: { turn: TURN } })
  assert.equal(page.status.textContent, "")
  assert.equal(page.state(), "idle")

  page.status.textContent = MESSAGES.listening
  page.root.dataset.agentChatVoiceState = "listening"
  page.chatListeners["studio:agent-chat:sent"]({ detail: { turn: TURN } })
  assert.equal(page.status.textContent, MESSAGES.listening, "a person still holding keeps their line")
})

test("a typed send while a take is being transcribed leaves that line alone", async () => {
  const page = composer()
  let release
  const fetcher = () => new Promise((resolve) => { release = resolve })
  const voice = mount(page, fetcher)
  const done = voice.takeArrived(take())
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(page.state(), "transcribing")
  page.chatListeners["studio:agent-chat:sent"]({ detail: { turn: TURN } })
  assert.equal(page.state(), "transcribing")
  release(answer(422, { reason: "no_speech" }))
  await done
})

// CONTROL: drop holdLine in onState and the first assert fails.
test("the line holds its height for the whole hold, however long the old line was", () => {
  const page = composer()
  mount(page, async () => answer(200, {}))
  page.status.textContent = "A long old refusal, three lines at a phone's width."
  page.status.offsetHeight = 60

  recorderSays(page, "starting")
  assert.equal(page.status.style.height, "60px", "taken before the old line clears")
  assert.equal(page.status.style.overflow, "hidden", "a take landing mid-hold cannot grow it")
  recorderSays(page, "recording")
  assert.equal(page.status.style.height, "60px")

  recorderSays(page, "captured")
  assert.equal(page.status.style.height, "", "let go, the line takes what it needs")
  assert.equal(page.status.style.overflow, "")
})
