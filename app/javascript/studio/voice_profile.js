// studio/voice_profile: the voice row on /profile (studio/profiles/_voice_section).
// The signed-in person reads three short phrases; each take is recorded, turned
// into a speaker embedding ON THIS DEVICE, and thrown away. Save posts only the
// vectors; the server averages them into one voice on the person's own record
// (Studio::VoiceMatch). No audio leaves the device for this.
//
//   <section data-studio-controller="voice-profile" data-voice-state="idle"
//            data-voice-save-url="/profile/voice" data-voice-embedder='{"name":"wespeaker",...}'>
//
// The controller (studio/controllers/voice_profile_controller) calls
// mountVoiceProfile(element) and destroys it on disconnect. Ported from
// Voicebox's voice setup (McRitchie-Studio/voicebox#10), where the embedder, the
// level meter and the silence threshold were measured.
//
// STATES, on data-voice-state: idle (the summary) -> ready (setup open, phrase
// n waiting) -> recording -> thinking -> ready ... -> complete -> saving. Each
// phrase carries data-phrase-state: waiting, current or done. A take the meter
// heard nothing in is refused (data-voice-last-take="silent") and the phrase
// stays current. While recording, --studio-voice-level (0..1) on the root drives
// the ring around the record button.
//
// EMBEDDERS, named by the page (Studio::VoiceMatch.browser_config):
//   wespeaker  WeSpeaker ResNet34 (VoxCeleb), int8, through transformers.js on
//              onnxruntime-web, from jsDelivr and Hugging Face at a pinned
//              revision. Loaded when the setup opens; the browser caches it.
//   fake       Tests only: a fixed vector per voice name (window.studioFakeVoice),
//              because Chrome's fake microphone cannot play chosen audio.
//
// It imports nothing statically; the model runtime is a dynamic import of
// "@huggingface/transformers" (pinned by the engine's importmap, never
// preloaded). test/javascript/voice_profile.test.mjs loads it as a data: module.

// The model hears 16 kHz mono; a take is cut to its first MAX_SECONDS.
export const SAMPLE_RATE = 16000
export const MAX_SECONDS = 10

// The loudest frame (RMS, 0..1) a take must reach to count as heard: 0.01 is
// -40 dBFS. A muted microphone sits at 0, a quiet room near 0.002-0.006, and
// speech at arm's length peaks well above 0.05.
export const SILENCE_RMS = 0.01

// A phrase is about four seconds; the take stops itself after TAKE_MS.
export const TAKE_MS = 6000

const MIME_CANDIDATES = [
  "audio/webm;codecs=opus",
  "audio/webm",
  "audio/mp4;codecs=mp4a.40.2",
  "audio/mp4",
  "audio/ogg;codecs=opus"
]

export const COPY = {
  idle: ["", ""],
  ready: ["Record phrase {n}", "Tap Record, then read phrase {n} out loud."],
  recording: ["Stop", "Listening... read phrase {n}, then tap Stop."],
  thinking: ["One moment...", "Learning your voice..."],
  complete: ["All three done", "All three done. Tap Save."],
  saving: ["Saving...", "Saving..."]
}

export const MESSAGES = {
  silent: "I couldn't hear that one. Check your microphone and read it again.",
  failed: "That one didn't work. Tap Record and read it again.",
  denied: "Allow the microphone to set up your voice.",
  unsupported: "This browser can't record here. Try Safari or Chrome.",
  network: "We couldn't reach the server. Tap Save again.",
  notSaved: "That didn't save. Tap Save again."
}

export class SilentTakeError extends Error {}

export function rootMeanSquare(samples) {
  if (!samples || samples.length === 0) return 0
  let sum = 0
  for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i]
  return Math.sqrt(sum / samples.length)
}

// The loudest 50 ms window's RMS, 0..1, at 16 kHz.
export function peakWindowRms(samples, windowSize = 800) {
  let peak = 0
  if (!samples) return peak
  for (let start = 0; start < samples.length; start += windowSize) {
    const end = Math.min(samples.length, start + windowSize)
    let sum = 0
    for (let i = start; i < end; i++) sum += samples[i] * samples[i]
    const rms = Math.sqrt(sum / Math.max(1, end - start))
    if (rms > peak) peak = rms
  }
  return peak
}

// The meter's reading, 0..1: logarithmic from -40 dBFS to -10 dBFS, where
// speech lives.
export function meterLevel(rms) {
  if (!(rms > 0)) return 0
  const db = 20 * Math.log10(rms)
  return Math.min(1, Math.max(0, (db + 40) / 30))
}

// Heard, unless the meter measured the take and it stayed under SILENCE_RMS. A
// take the meter never measured (no Web Audio, a context that never ran) is
// let through, and the embedder's own check on the decoded samples decides.
export function takeWasHeard(peakRms, framesMeasured) {
  if (!framesMeasured) return true
  return peakRms >= SILENCE_RMS
}

export function pickMimeType(isTypeSupported) {
  if (typeof isTypeSupported !== "function") return ""
  return MIME_CANDIDATES.find((type) => {
    try { return isTypeSupported(type) } catch (_) { return false }
  }) || ""
}

// The words for a state, with {n} the phrase being read (1-based).
export function copyFor(state, step) {
  const [button, status] = COPY[state] || ["Try again", ""]
  const n = String(step + 1)
  return { button: button.replace("{n}", n), status: status.replace("{n}", n) }
}

// Each phrase's state for a step (how many takes are kept).
export function phraseStates(total, step) {
  return Array.from({ length: total }, (_, i) => (i < step ? "done" : (i === step ? "current" : "waiting")))
}

// mulberry32: a small seeded generator, so the fake's vectors are the same in
// every run and every browser.
function seededRandom(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6D2B79F5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function hashString(text) {
  let h = 2166136261
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return h >>> 0
}

// The fake embedder's vector for a voice name: the same name always gives the
// same vector, and two names give nearly unrelated ones (cosine near 0).
export function fakeVector(voice, size = 256) {
  const random = seededRandom(hashString(String(voice)))
  return Array.from({ length: size }, () => random() * 2 - 1)
}

// A recorded Blob as 16 kHz mono floats: the browser decodes the container
// (webm/opus or mp4/aac) and resamples it while rendering offline.
export async function decodeToMono16k(blob, win = globalThis) {
  const bytes = await blob.arrayBuffer()
  const Offline = win.OfflineAudioContext || win.webkitOfflineAudioContext
  const probe = new Offline(1, 1, SAMPLE_RATE)
  const decoded = await probe.decodeAudioData(bytes)
  const seconds = Math.min(decoded.duration, MAX_SECONDS)
  const length = Math.max(1, Math.ceil(seconds * SAMPLE_RATE))
  const offline = new Offline(1, length, SAMPLE_RATE)
  const source = offline.createBufferSource()
  source.buffer = decoded
  source.connect(offline.destination) // a mono destination downmixes
  source.start()
  const rendered = await offline.startRendering()
  return rendered.getChannelData(0)
}

class WespeakerEmbedder {
  constructor(config) { this.config = config }

  get name() { return this.config.name }
  get id() { return this.config.id }

  // Starts the download (runtime ~4.3 MB, model ~6.7 MB, cached after the first
  // time) without waiting for it. Safe to call more than once; a failed load
  // can be retried.
  warm() {
    if (!this.loading) {
      this.loading = (async () => {
        const transformers = await import("@huggingface/transformers")
        // The model comes from the Hugging Face hub at a pinned revision, never
        // from this app's own /models path.
        transformers.env.allowLocalModels = false
        const options = { revision: this.config.revision }
        const [processor, model] = await Promise.all([
          transformers.AutoProcessor.from_pretrained(this.config.model, options),
          transformers.AutoModel.from_pretrained(this.config.model, { ...options, dtype: this.config.dtype })
        ])
        return { processor, model }
      })()
      this.loading.catch(() => { this.loading = null })
    }
    return this.loading
  }

  async embed(blob) {
    const samples = await decodeToMono16k(blob)
    if (peakWindowRms(samples) < SILENCE_RMS) throw new SilentTakeError("silent take")
    const { processor, model } = await this.warm()
    const inputs = await processor(samples)
    const output = await model(inputs)
    const tensor = output.embeddings || output.last_hidden_state || Object.values(output)[0]
    return Array.from(tensor.data)
  }
}

class FakeEmbedder {
  constructor(config, win) {
    this.config = config
    this.win = win
  }

  get name() { return this.config.name }
  get id() { return this.config.id }

  warm() { return Promise.resolve() }

  async embed(blob) {
    if (!blob || blob.size === 0) throw new SilentTakeError("empty take")
    return fakeVector((this.win && this.win.studioFakeVoice) || "default", this.config.size)
  }
}

const EMBEDDERS = { wespeaker: WespeakerEmbedder, fake: FakeEmbedder }

// The embedder the page names, or null when it names none this script knows.
export function embedderFor(config, win = globalThis) {
  if (!config || !config.name) return null
  const Embedder = EMBEDDERS[config.name]
  return Embedder ? new Embedder(config, win) : null
}

function parseJson(text) {
  try { return JSON.parse(text || "null") } catch (_) { return null }
}

// Binds the voice row. Returns { destroy }.
export function mountVoiceProfile(root, win = window) {
  const doc = root.ownerDocument
  const phrases = () => Array.from(root.querySelectorAll("[data-voice-phrase]"))
  const one = (selector) => root.querySelector(selector)
  const embedder = embedderFor(parseJson(root.getAttribute("data-voice-embedder")), win)
  const saveUrl = root.getAttribute("data-voice-save-url")

  let vectors = []
  let state = "idle"
  let stream = null
  let recorder = null
  let chunks = []
  let timer = null
  let audioContext = null
  let analyser = null
  let levelBuffer = null
  let meterFrame = null
  let meterTimer = null
  let peakRms = 0
  let frames = 0
  let starting = false
  let destroyed = false

  function setState(next, message = null) {
    state = next
    root.dataset.voiceState = next
    const states = phraseStates(phrases().length, vectors.length)
    phrases().forEach((phrase, i) => { phrase.dataset.phraseState = states[i] })
    const words = copyFor(next, vectors.length)
    const label = one("[data-voice-record-label]")
    if (label && words.button) label.textContent = words.button
    const status = one("[data-voice-status]")
    if (status) status.textContent = message || words.status
    const button = one("[data-voice-record]")
    if (button) {
      button.disabled = !["ready", "recording"].includes(next)
      button.setAttribute("aria-pressed", next === "recording" ? "true" : "false")
    }
    const save = one("[data-voice-save]")
    if (save) save.disabled = next !== "complete"
  }

  function settle(message = null) {
    setState(vectors.length >= phrases().length ? "complete" : "ready", message)
  }

  function supported() {
    return !!(win.MediaRecorder && win.navigator && win.navigator.mediaDevices && win.navigator.mediaDevices.getUserMedia)
  }

  function open() {
    if (state !== "idle") return
    vectors = []
    const setup = one("[data-voice-setup]")
    if (setup) setup.hidden = false
    const summary = one("[data-voice-summary]")
    if (summary) summary.hidden = true
    if (!embedder || !supported()) {
      setState("ready", MESSAGES.unsupported)
      const button = one("[data-voice-record]")
      if (button) button.disabled = true
      return
    }
    embedder.warm().catch(() => {})
    setState("ready")
  }

  function cancel() {
    stopTake(false)
    vectors = []
    const setup = one("[data-voice-setup]")
    if (setup) setup.hidden = true
    const summary = one("[data-voice-summary]")
    if (summary) summary.hidden = false
    setState("idle")
  }

  function paintLevel(level) {
    root.style.setProperty("--studio-voice-level", level.toFixed(3))
    root.dataset.voiceLevel = level.toFixed(2)
  }

  function sampleLevel() {
    if (!analyser || !audioContext || audioContext.state !== "running") return
    analyser.getFloatTimeDomainData(levelBuffer)
    const rms = rootMeanSquare(levelBuffer)
    frames += 1
    if (rms > peakRms) {
      peakRms = rms
      root.dataset.voicePeak = rms.toFixed(4)
    }
    if (rms >= SILENCE_RMS) root.dataset.voiceHeard = "true"
    paintLevel(meterLevel(rms))
  }

  function startMeter(source) {
    peakRms = 0
    frames = 0
    root.dataset.voiceHeard = "false"
    root.dataset.voicePeak = "0"
    paintLevel(0)
    const AudioContextClass = win.AudioContext || win.webkitAudioContext
    if (!AudioContextClass) return
    try {
      audioContext = new AudioContextClass()
      const input = audioContext.createMediaStreamSource(source)
      analyser = audioContext.createAnalyser()
      analyser.fftSize = 1024
      levelBuffer = new Float32Array(analyser.fftSize)
      input.connect(analyser)
      if (audioContext.state === "suspended" && audioContext.resume) audioContext.resume().catch(() => {})
    } catch (_) {
      closeMeter()
      return
    }
    const frame = () => {
      sampleLevel()
      meterFrame = win.requestAnimationFrame(frame)
    }
    meterFrame = win.requestAnimationFrame(frame)
    // A background tab stops animation frames; the timer keeps measuring.
    meterTimer = win.setInterval(sampleLevel, 100)
  }

  function closeMeter() {
    if (meterFrame) win.cancelAnimationFrame(meterFrame)
    if (meterTimer) win.clearInterval(meterTimer)
    meterFrame = null
    meterTimer = null
    analyser = null
    if (audioContext && audioContext.state !== "closed") audioContext.close().catch(() => {})
    audioContext = null
    paintLevel(0)
  }

  function release() {
    if (stream) stream.getTracks().forEach((track) => track.stop())
    stream = null
  }

  async function startTake() {
    try {
      stream = await win.navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (error) {
      setState("ready", error && error.name === "NotAllowedError" ? MESSAGES.denied : MESSAGES.failed)
      return
    }
    if (destroyed || state !== "ready") { release(); return }
    chunks = []
    try {
      startMeter(stream)
      const MediaRecorderClass = win.MediaRecorder
      const mimeType = pickMimeType(MediaRecorderClass.isTypeSupported && MediaRecorderClass.isTypeSupported.bind(MediaRecorderClass))
      try {
        recorder = mimeType ? new MediaRecorderClass(stream, { mimeType }) : new MediaRecorderClass(stream)
      } catch (_) {
        recorder = new MediaRecorderClass(stream)
      }
      recorder.addEventListener("dataavailable", (event) => {
        if (event.data && event.data.size > 0) chunks.push(event.data)
      })
      recorder.addEventListener("stop", () => finishTake())
      recorder.start(250)
    } catch (_) {
      closeMeter()
      release()
      setState("ready", MESSAGES.failed)
      return
    }
    setState("recording")
    timer = win.setTimeout(() => stopTake(true), TAKE_MS)
  }

  function stopTake(keep = true) {
    if (timer) win.clearTimeout(timer)
    timer = null
    if (!recorder || recorder.state === "inactive") return
    if (!keep) recorder.discard = true
    recorder.stop()
  }

  async function finishTake() {
    const discarded = recorder && recorder.discard
    sampleLevel()
    const heard = takeWasHeard(peakRms, frames)
    closeMeter()
    release()
    const type = (recorder && recorder.mimeType) || "audio/webm"
    const blob = new Blob(chunks, { type })
    chunks = []
    recorder = null
    if (discarded || destroyed) return
    if (!heard || blob.size === 0) {
      root.dataset.voiceLastTake = "silent"
      settle(MESSAGES.silent)
      return
    }
    setState("thinking")
    try {
      const vector = await embedder.embed(blob)
      if (destroyed || state !== "thinking") return
      vectors.push(vector)
      root.dataset.voiceLastTake = "kept"
      settle()
    } catch (error) {
      if (destroyed || state !== "thinking") return
      const silent = error instanceof SilentTakeError
      root.dataset.voiceLastTake = silent ? "silent" : "failed"
      settle(silent ? MESSAGES.silent : MESSAGES.failed)
    }
  }

  function toggle() {
    if (state === "recording") stopTake(true)
    else if (state === "ready" && !starting) {
      starting = true
      startTake().finally(() => { starting = false })
    }
  }

  function csrfToken() {
    const meta = doc.querySelector("meta[name='csrf-token']")
    return meta ? meta.content : ""
  }

  async function save() {
    if (state !== "complete") return
    setState("saving")
    let response
    let body
    try {
      response = await win.fetch(saveUrl, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Accept": "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
        body: JSON.stringify({ voice: { model: embedder.id, embeddings: vectors } })
      })
      body = await response.json().catch(() => null)
    } catch (_) {
      setState("complete", MESSAGES.network)
      return
    }
    // fetch resolves on a 4xx or 5xx: only an ok answer with a url is saved.
    if (!response.ok || !body || !body.url) {
      setState("complete", (body && body.error) || MESSAGES.notSaved)
      return
    }
    vectors = []
    root.dataset.voiceSaved = "true"
    win.location.assign(body.url)
  }

  const handlers = {
    open: () => open(),
    cancel: () => cancel(),
    record: () => toggle(),
    save: () => save()
  }

  function onClick(event) {
    const target = event.target.closest && event.target.closest("[data-voice-action]")
    if (!target || !root.contains(target)) return
    const handler = handlers[target.getAttribute("data-voice-action")]
    if (!handler) return
    event.preventDefault()
    handler()
  }

  root.addEventListener("click", onClick)
  root.dataset.voiceReady = "true"
  setState("idle")

  return {
    destroy() {
      destroyed = true
      root.removeEventListener("click", onClick)
      stopTake(false)
      closeMeter()
      release()
    }
  }
}
