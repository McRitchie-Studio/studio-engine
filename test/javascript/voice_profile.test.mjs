// [unit] studio/voice_profile: the voice row's level meter, silence rule, copy,
// phrase states, test embedder and the mounted flow against a stub browser.
// Loaded from source as a data: module, like knowledge_transcript.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/voice_profile.js", import.meta.url), "utf8")
const {
  SILENCE_RMS, TAKE_MS, rootMeanSquare, peakWindowRms, meterLevel, takeWasHeard, pickMimeType,
  copyFor, phraseStates, fakeVector, embedderFor, SilentTakeError, MESSAGES
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

function cosine(a, b) {
  let dot = 0, na = 0, nb = 0
  for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
  return dot / Math.sqrt(na * nb)
}

test("the module imports nothing statically", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
  assert.match(source, /import\("@huggingface\/transformers"\)/, "the runtime is a dynamic import")
})

test("the silence line is -40 dBFS, as measured in Voicebox", () => {
  assert.equal(SILENCE_RMS, 0.01)
  assert.equal(TAKE_MS, 6000)
})

test("rootMeanSquare and peakWindowRms", () => {
  assert.equal(rootMeanSquare([]), 0)
  assert.equal(rootMeanSquare(null), 0)
  assert.ok(Math.abs(rootMeanSquare([0.5, -0.5, 0.5, -0.5]) - 0.5) < 1e-12)
  const quietThenLoud = new Float32Array(1600)
  for (let i = 800; i < 1600; i++) quietThenLoud[i] = i % 2 ? 0.2 : -0.2
  assert.ok(Math.abs(peakWindowRms(quietThenLoud) - 0.2) < 1e-6, "the loudest window, not the mean")
  assert.equal(peakWindowRms(new Float32Array(1600)), 0)
})

test("meterLevel maps -40..-10 dBFS onto 0..1 and clamps", () => {
  assert.equal(meterLevel(0), 0)
  assert.equal(meterLevel(-1), 0)
  assert.equal(meterLevel(NaN), 0)
  assert.ok(Math.abs(meterLevel(0.01)) < 1e-9, "-40 dBFS is the floor")
  assert.ok(Math.abs(meterLevel(Math.pow(10, -10 / 20)) - 1) < 1e-9, "-10 dBFS is full")
  assert.equal(meterLevel(1), 1)
  assert.ok(meterLevel(0.05) > 0 && meterLevel(0.05) < 1)
})

test("a take is heard only when the measured peak reaches the line", () => {
  assert.equal(takeWasHeard(0.009, 40), false)
  assert.equal(takeWasHeard(0.01, 40), true)
  assert.equal(takeWasHeard(0, 0), true, "an unmeasured take is left to the embedder")
})

test("pickMimeType prefers webm/opus, falls back to mp4 (iOS)", () => {
  assert.equal(pickMimeType((t) => true), "audio/webm;codecs=opus")
  assert.equal(pickMimeType((t) => t.startsWith("audio/mp4")), "audio/mp4;codecs=mp4a.40.2")
  assert.equal(pickMimeType(() => { throw new Error("no") }), "")
  assert.equal(pickMimeType(undefined), "")
})

test("copyFor names the phrase being read", () => {
  assert.deepEqual(copyFor("ready", 0), { button: "Record phrase 1", status: "Tap Record, then read phrase 1 out loud." })
  assert.equal(copyFor("recording", 2).status, "Listening... read phrase 3, then tap Stop.")
  assert.equal(copyFor("complete", 3).button, "All three done")
})

test("phraseStates marks done, current and waiting", () => {
  assert.deepEqual(phraseStates(3, 0), ["current", "waiting", "waiting"])
  assert.deepEqual(phraseStates(3, 1), ["done", "current", "waiting"])
  assert.deepEqual(phraseStates(3, 3), ["done", "done", "done"])
})

test("the fake vector is fixed per voice and unrelated across voices", () => {
  const a1 = fakeVector("alex")
  const a2 = fakeVector("alex")
  const b = fakeVector("pat")
  assert.equal(a1.length, 256)
  assert.deepEqual(a1, a2)
  assert.ok(Math.abs(cosine(a1, b)) < 0.3, `two voices should be far apart (${cosine(a1, b)})`)
})

test("embedderFor knows the real and the fake embedder, and nothing else", async () => {
  assert.equal(embedderFor(null), null)
  assert.equal(embedderFor({ name: "whisper" }), null)
  const real = embedderFor({ name: "wespeaker", id: "wespeaker-x" })
  assert.equal(real.name, "wespeaker")
  assert.equal(real.id, "wespeaker-x")
  const win = { studioFakeVoice: "alex" }
  const fake = embedderFor({ name: "fake", id: "fake-256", size: 256 }, win)
  assert.deepEqual(await fake.embed({ size: 10 }), fakeVector("alex"))
  await assert.rejects(fake.embed({ size: 0 }), SilentTakeError)
})

// ---- the mounted flow, against a stub browser --------------------------------

class El {
  constructor(attrs = {}, children = []) {
    this.attrs = { ...attrs }
    this.children = children
    this.dataset = {}
    this.hidden = attrs.hidden !== undefined
    this.disabled = false
    this.textContent = ""
    this.style = { props: {}, setProperty: (k, v) => { this.style.props[k] = v } }
    this.listeners = {}
    children.forEach((c) => { c.parent = this })
  }
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null }
  setAttribute(name, value) { this.attrs[name] = String(value) }
  all() { return this.children.flatMap((c) => [c, ...c.all()]) }
  querySelectorAll(selector) {
    const name = selector.replace(/^\[|\]$/g, "")
    return this.all().filter((el) => name in el.attrs)
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null }
  contains(el) { return el === this || this.all().includes(el) }
  closest(selector) {
    const name = selector.replace(/^\[|\]$/g, "")
    let el = this
    while (el) { if (name in el.attrs) return el; el = el.parent }
    return null
  }
  addEventListener(type, fn) { this.listeners[type] = fn }
  removeEventListener(type) { delete this.listeners[type] }
  click(target) { this.listeners.click({ target, preventDefault() {} }) }
}

function buildRow(embedder) {
  const phrases = [0, 1, 2].map(() => new El({ "data-voice-phrase": "" }))
  const record = new El({ "data-voice-action": "record", "data-voice-record": "" }, [new El({ "data-voice-record-label": "" })])
  const save = new El({ "data-voice-action": "save", "data-voice-save": "" })
  const setup = new El({ "data-voice-setup": "", hidden: "" }, [...phrases, record, new El({ "data-voice-status": "" }), save])
  const open = new El({ "data-voice-action": "open" })
  const summary = new El({ "data-voice-summary": "" }, [open])
  const root = new El({ "data-voice-save-url": "/profile/voice", "data-voice-embedder": JSON.stringify(embedder) }, [summary, setup])
  root.ownerDocument = { querySelector: () => ({ content: "csrf-123" }) }
  return { root, phrases, record, save, setup, summary, open, status: setup.children[4] }
}

// A browser whose microphone is `level` loud (an analyser that reads that RMS).
function stubWindow(level, fetchAnswer) {
  const posts = []
  const timers = []
  class Recorder {
    constructor() { this.state = "inactive"; this.handlers = {}; this.mimeType = "audio/webm" }
    static isTypeSupported() { return true }
    addEventListener(type, fn) { this.handlers[type] = fn }
    start() { this.state = "recording" }
    stop() {
      this.state = "inactive"
      this.handlers.dataavailable({ data: { size: 1200 } })
      this.handlers.stop()
    }
  }
  const win = {
    studioFakeVoice: "alex",
    MediaRecorder: Recorder,
    navigator: { mediaDevices: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) } },
    AudioContext: class {
      constructor() { this.state = "running" }
      createMediaStreamSource() { return { connect() {} } }
      createAnalyser() { return { fftSize: 0, getFloatTimeDomainData: (buf) => buf.fill(level) } }
      close() { this.state = "closed"; return Promise.resolve() }
    },
    requestAnimationFrame: () => 1,
    cancelAnimationFrame: () => {},
    setInterval: () => 2,
    clearInterval: () => {},
    setTimeout: (fn) => { timers.push(fn); return timers.length },
    clearTimeout: () => {},
    fetch: async (url, options) => { posts.push({ url, options }); return fetchAnswer },
    location: { assigned: null, assign(url) { this.assigned = url } }
  }
  return { win, posts }
}

globalThis.Blob = class { constructor(parts) { this.size = parts.reduce((n, p) => n + (p.size || 0), 0) } }

const FAKE = { name: "fake", id: "fake-256", size: 256 }
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))
const { mountVoiceProfile } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

async function readPhrase(row) {
  row.root.click(row.record)
  await flush()
  assert.equal(row.root.dataset.voiceState, "recording")
  row.root.click(row.record)
  await flush()
}

test("three heard takes save three vectors, with the model id and the CSRF token", async () => {
  const { win, posts } = stubWindow(0.1, { ok: true, json: async () => ({ url: "/profile" }) })
  const row = buildRow(FAKE)
  mountVoiceProfile(row.root, win)
  assert.equal(row.root.dataset.voiceState, "idle")

  row.root.click(row.open)
  assert.equal(row.setup.hidden, false)
  assert.equal(row.summary.hidden, true)
  assert.equal(row.root.dataset.voiceState, "ready")
  assert.equal(row.save.disabled, true, "nothing to save yet")

  for (let i = 0; i < 3; i++) await readPhrase(row)
  assert.equal(row.root.dataset.voiceState, "complete")
  assert.deepEqual(row.phrases.map((p) => p.dataset.phraseState), ["done", "done", "done"])
  assert.equal(row.root.style.props["--studio-voice-level"], "0.000", "the meter rests after a take")
  assert.equal(row.save.disabled, false)

  row.root.click(row.save)
  await flush()
  assert.equal(posts.length, 1)
  assert.equal(posts[0].url, "/profile/voice")
  assert.equal(posts[0].options.headers["X-CSRF-Token"], "csrf-123")
  const body = JSON.parse(posts[0].options.body)
  assert.equal(body.voice.model, "fake-256")
  assert.equal(body.voice.embeddings.length, 3)
  assert.deepEqual(body.voice.embeddings[0], fakeVector("alex"))
  assert.equal(Object.keys(body.voice).sort().join(","), "embeddings,model", "vectors only, never audio")
  assert.equal(win.location.assigned, "/profile")
})

test("a silent take is refused and the phrase stays current", async () => {
  const { win } = stubWindow(0.001, null)
  const row = buildRow(FAKE)
  mountVoiceProfile(row.root, win)
  row.root.click(row.open)

  await readPhrase(row)

  assert.equal(row.root.dataset.voiceLastTake, "silent")
  assert.equal(row.root.dataset.voiceState, "ready")
  assert.equal(row.status.textContent, MESSAGES.silent)
  assert.deepEqual(row.phrases.map((p) => p.dataset.phraseState), ["current", "waiting", "waiting"])
})

test("the meter shows the level while a take records", async () => {
  const { win } = stubWindow(0.1, null)
  let frame
  win.requestAnimationFrame = (fn) => { frame = fn; return 1 }
  const row = buildRow(FAKE)
  mountVoiceProfile(row.root, win)
  row.root.click(row.open)
  row.root.click(row.record)
  await flush()
  frame()

  assert.equal(row.root.dataset.voiceHeard, "true")
  assert.equal(row.root.style.props["--studio-voice-level"], meterLevel(0.1).toFixed(3))
})

test("a refused save keeps the takes and says why", async () => {
  const { win } = stubWindow(0.1, { ok: false, json: async () => ({ error: "Nope." }) })
  const row = buildRow(FAKE)
  mountVoiceProfile(row.root, win)
  row.root.click(row.open)
  for (let i = 0; i < 3; i++) await readPhrase(row)

  row.root.click(row.save)
  await flush()

  assert.equal(row.root.dataset.voiceState, "complete")
  assert.equal(row.status.textContent, "Nope.")
  assert.equal(win.location.assigned, null)
})

test("no embedder this script knows: setup says so and cannot record", () => {
  const { win } = stubWindow(0.1, null)
  const row = buildRow({ name: "whisper" })
  mountVoiceProfile(row.root, win)
  row.root.click(row.open)

  assert.equal(row.status.textContent, MESSAGES.unsupported)
  assert.equal(row.record.disabled, true)
})
