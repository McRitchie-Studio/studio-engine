// studio/agent_chat_voice: hold to talk in the shared agent chat's composer
// (studio/agent_chat/_voice; docs/AGENT_CHAT.md, "Talking by voice").
//
// THE FLOW, for one take the engine recorder hands over
// (studio:voice-recorder:take {blob, mimeType, durationMs}):
//
//   1. embed it ON THIS DEVICE when the page names an embedder (the person has
//      a saved voice; data-agent-chat-voice-embedder is the /profile voice row's
//      own config), with studio/voice_profile's embedderFor. Any failure, or a
//      model slower than EMBED_WAIT_MS, sends the take without a vector: the
//      server then answers "Someone new" (check no_embedding), never an error.
//   2. POST it to /voice/takes (multipart, X-CSRF-Token), which answers
//      {text, speaker, score, identified, check, duration_ms} and keeps nothing.
//   3. send `text` to the chat's own form action with `voice` {check, score,
//      duration_ms} and hand the turn to the chat (its public refresh hook,
//      studio:agent-chat:refresh), so the turn and the typing line appear. The
//      browser never sends a name: the server names the speaker, and the line
//      says who it kept.
//
// Every refusal is a line in [data-agent-chat-voice-status] (set as text) and a
// state on data-agent-chat-voice-state: listening, transcribing, queued, sending,
// sent, silent, no_speech, not_configured, rate_limited, refused, failed.
//
// NO WORDS ARE LOST. A transcript that could not be sent goes in the chat's box,
// after anything already typed there. A take that lands while another is still
// being turned into words waits its turn, in order, and the line says so.
//
// It imports nothing at load (studio/voice_profile, and the model behind it, only
// when a person with a saved voice talks), so test/javascript/agent_chat_voice.test.mjs
// loads it as a data: module.

export const EMBED_WAIT_MS = 8000

export const MESSAGES = {
  listening: "Listening...",
  transcribing: "Turning that into words...",
  queued: "Got that one too. It's next.",
  sending: (name) => `Sending to ${name}...`,
  sent: (speaker) => `Sent. Spoken by ${speaker}.`,
  sentPlain: "Sent.",
  silent: (label) => `I couldn't hear anything${label ? ` from ${label}` : ""}. Check your microphone and hold to talk again.`,
  noSpeech: "I couldn't hear any words in that. Check your microphone and try again.",
  notConfigured: "Voice isn't set up on this app yet, so I can't hear recordings. Type instead for now.",
  rateLimited: "That's a lot of voice messages in a row. Wait a moment, then hold to talk again.",
  signedOut: "Sign in again to talk.",
  unavailable: "I couldn't transcribe that just now. Try again in a moment.",
  failed: "That recording didn't go through. Try again.",
  offline: "Can't reach the server right now. Try again in a moment.",
  notSent: (name) => `Couldn't send that to ${name}. Your words are in the box; press send to try again.`
}

// "Try again in 40 seconds." from a Retry-After header or a retry_after field.
export function retryHint(seconds) {
  const n = Math.round(Number(seconds))
  if (!Number.isFinite(n) || n <= 0) return ""
  if (n < 60) return ` Try again in ${n} second${n === 1 ? "" : "s"}.`
  const minutes = Math.ceil(n / 60)
  return ` Try again in ${minutes} minute${minutes === 1 ? "" : "s"}.`
}

// What POST /voice/takes's refusal means on the page: {state, message}.
// `body` is the parsed JSON (or {}); `retryAfter` the header, if any.
export function refusalFor(status, body = {}, retryAfter = null) {
  const said = body && typeof body.error === "string" && body.error.trim() ? body.error.trim() : null
  if (status === 401) return { state: "refused", message: MESSAGES.signedOut }
  if (status === 429) {
    return { state: "rate_limited", message: MESSAGES.rateLimited + retryHint(retryAfter ?? (body && body.retry_after)) }
  }
  if (status === 422 && body && body.reason === "no_speech") return { state: "no_speech", message: said || MESSAGES.noSpeech }
  if (status === 503 && body && body.reason === "not_configured") return { state: "not_configured", message: said || MESSAGES.notConfigured }
  if (status === 503) return { state: "failed", message: said || MESSAGES.unavailable }
  if ([403, 413, 415, 422].includes(status)) return { state: "refused", message: said || MESSAGES.failed }
  return { state: "failed", message: MESSAGES.failed }
}

// The message's `voice`, from a 200 answer: what the take measured, never a name.
export function voiceMetadata(answer = {}) {
  const score = typeof answer.score === "number" && Number.isFinite(answer.score) ? answer.score : null
  const duration = Number.isInteger(answer.duration_ms) ? answer.duration_ms : null
  return { check: String(answer.check || "no_embedding"), score, duration_ms: duration }
}

// The multipart body POST /voice/takes reads (docs/VOICE_TRANSCRIPTION.md).
export function takeForm(detail, { embedding = null, model = null } = {}, FormDataClass = globalThis.FormData) {
  const form = new FormDataClass()
  form.append("voice[audio]", detail.blob, "take")
  if (detail.mimeType) form.append("voice[mime_type]", detail.mimeType)
  form.append("voice[duration_ms]", String(Math.max(1, Math.round(Number(detail.durationMs) || 0))))
  if (Array.isArray(embedding) && embedding.length && model) {
    form.append("voice[embedding]", JSON.stringify(embedding))
    form.append("voice[model]", model)
  }
  return form
}

export function parseEmbedder(text) {
  if (!text) return null
  try {
    const config = JSON.parse(text)
    return config && config.name && config.id ? config : null
  } catch (_) {
    return null
  }
}

// The words in the box, after anything already there: a person's draft is theirs.
export function wordsInBox(current, text) {
  return current && current.trim() ? `${current.trimEnd()}\n${text}` : text
}

// The chat form's own token, else the page's (csrf_meta_tags).
export function csrfToken(form, doc = globalThis.document) {
  const field = form && form.querySelector("input[name='authenticity_token']")
  if (field && field.value) return field.value
  const meta = doc && doc.querySelector("meta[name='csrf-token']")
  return meta ? meta.getAttribute("content") : null
}

// Resolves to `promise`'s value, or `fallback` once `ms` have passed.
export function within(promise, ms, fallback = null, setTimer = (fn, t) => globalThis.setTimeout(fn, t)) {
  return Promise.race([promise, new Promise((resolve) => setTimer(() => resolve(fallback), ms))])
}

async function readJson(response) {
  try { return await response.json() } catch (_) { return {} }
}

// Mounts one voice section, which sits inside the chat's form. Returns
// { takeArrived, destroy } for tests.
export function mountAgentChatVoice(root, {
  fetch: fetcher = (...args) => globalThis.fetch(...args),
  doc = globalThis.document,
  loadEmbedder = async (config) => {
    const { embedderFor } = await import("studio/voice_profile")
    return embedderFor(config)
  },
  setTimer = (fn, ms) => globalThis.setTimeout(fn, ms),
  FormDataClass = globalThis.FormData,
  CustomEventClass = globalThis.CustomEvent
} = {}) {
  const status = root.querySelector("[data-agent-chat-voice-status]")
  const form = root.closest("[data-agent-chat-form]")
  const chat = root.closest("[data-agent-chat-soul]")
  const name = root.dataset.agentChatVoiceName || "the agent"
  const soul = root.dataset.agentChatVoiceSoul
  const embedders = new Map()
  const waiting = []
  let working = false
  let alive = true

  function say(state, message) {
    root.dataset.agentChatVoiceState = state
    if (status) status.textContent = message || ""
  }

  function embedder() {
    const config = parseEmbedder(root.getAttribute("data-agent-chat-voice-embedder"))
    if (!config) return Promise.resolve(null)
    if (!embedders.has(config.id)) {
      const loading = Promise.resolve().then(() => loadEmbedder(config)).catch(() => null)
      embedders.set(config.id, loading)
      loading.then((loaded) => { if (!loaded) embedders.delete(config.id) })
    }
    return embedders.get(config.id)
  }

  async function embed(blob) {
    try {
      const loaded = await within(embedder(), EMBED_WAIT_MS, null, setTimer)
      if (!loaded) return {}
      const vector = await within(loaded.embed(blob), EMBED_WAIT_MS, null, setTimer)
      return Array.isArray(vector) && vector.length ? { embedding: vector, model: loaded.id } : {}
    } catch (_) {
      return {}
    }
  }

  function keepWords(text) {
    const input = form && form.querySelector("[data-agent-chat-input]")
    if (input) input.value = wordsInBox(input.value, text)
  }

  function headers(extra = {}) {
    const token = csrfToken(form, doc)
    return { Accept: "application/json", ...extra, ...(token ? { "X-CSRF-Token": token } : {}) }
  }

  async function send(answer) {
    if (!form) {
      say("failed", MESSAGES.notSent(name))
      return
    }
    say("sending", MESSAGES.sending(name))
    let response
    try {
      response = await fetcher(form.getAttribute("action"), {
        method: "POST", headers: headers({ "Content-Type": "application/json" }), credentials: "same-origin",
        body: JSON.stringify({ soul, text: answer.text, voice: voiceMetadata(answer) })
      })
    } catch (_) {
      keepWords(answer.text)
      say("failed", MESSAGES.notSent(name))
      return
    }
    const data = await readJson(response)
    if (response.status === 201 && data.turn) {
      // The speaker the server kept, which is what the agent is told.
      const kept = data.voice && typeof data.voice.speaker === "string" ? data.voice.speaker : null
      say("sent", kept ? MESSAGES.sent(kept) : MESSAGES.sentPlain)
      if (chat) chat.dispatchEvent(new CustomEventClass("studio:agent-chat:refresh", { detail: { turn: data.turn } }))
      return
    }
    keepWords(answer.text)
    const reason = typeof data.error === "string" && data.error ? `${data.error} ` : ""
    say(response.status === 429 ? "rate_limited" : "failed", `${reason}${MESSAGES.notSent(name)}`)
  }

  async function handleTake(detail) {
    say("transcribing", MESSAGES.transcribing)
    const vector = await embed(detail.blob)
    let response
    try {
      response = await fetcher(root.dataset.agentChatVoiceTakesUrl || "/voice/takes", {
        method: "POST", headers: headers(), credentials: "same-origin", body: takeForm(detail, vector, FormDataClass)
      })
    } catch (_) {
      say("failed", MESSAGES.offline)
      return
    }
    const body = await readJson(response)
    if (!response.ok || typeof body.text !== "string" || !body.text.trim()) {
      const retryAfter = response.headers && response.headers.get ? response.headers.get("Retry-After") : null
      const { state, message } = response.ok ? { state: "no_speech", message: MESSAGES.noSpeech } : refusalFor(response.status, body, retryAfter)
      say(state, message)
      return
    }
    await send(body)
  }

  // One take at a time, in the order they were spoken. Resolves when the queue
  // has drained, so a test can await it.
  async function takeArrived(detail) {
    if (working) {
      waiting.push(detail)
      say("queued", MESSAGES.queued)
      return
    }
    working = true
    try {
      let next = detail
      while (next && alive) {
        await handleTake(next)
        next = waiting.shift()
      }
    } finally {
      working = false
    }
  }

  function onTake(event) {
    if (event.detail && event.detail.blob) takeArrived(event.detail)
  }

  // The one line for a silent take, naming the microphone (the recorder's own
  // line for it is hidden in the composer, studio/agent_chat/_voice).
  function onSilent(event) {
    say("silent", MESSAGES.silent(event.detail && event.detail.microphone && event.detail.microphone.label))
  }

  // The recorder's state, on the one line: a new hold replaces whatever the last
  // take left there ("Sent.", a refusal). A take still in hand speaks over it
  // when it lands. Starting the model download here gets it ready while the
  // person is still talking.
  function onState(event) {
    const next = event.detail && event.detail.state
    if (next === "starting") {
      say("idle", "")
    } else if (next === "recording") {
      say("listening", MESSAGES.listening)
      embedder().then((loaded) => loaded && loaded.warm && loaded.warm()).catch(() => {})
    } else if (root.dataset.agentChatVoiceState === "listening") {
      say(working ? "transcribing" : "idle", working ? MESSAGES.transcribing : "")
    }
  }

  root.addEventListener("studio:voice-recorder:take", onTake)
  root.addEventListener("studio:voice-recorder:silent", onSilent)
  root.addEventListener("studio:voice-recorder:state", onState)

  return {
    takeArrived,
    destroy() {
      alive = false
      root.removeEventListener("studio:voice-recorder:take", onTake)
      root.removeEventListener("studio:voice-recorder:silent", onSilent)
      root.removeEventListener("studio:voice-recorder:state", onState)
    }
  }
}
