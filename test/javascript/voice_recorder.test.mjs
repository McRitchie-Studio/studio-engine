// [unit] studio/voice_recorder: the record button against a stub browser. A
// heard take hands its blob to the page in an event and uploads nothing; a
// silent take is refused and named; a refused microphone says so; a
// MediaRecorder that will not start lets go of the microphone and the meter;
// hold mode records while pressed; the mime pick and the copy merge. Loaded
// with its studio/ imports inlined (support/studio_module.mjs), so the meter
// under test is the engine's real one.
import { test } from "node:test"
import assert from "node:assert/strict"
import { studioSource, loadStudioModule } from "./support/studio_module.mjs"

const { mountVoiceRecorder, pickMimeType, formatElapsed, mergeCopy, COPY, EVENTS } = await loadStudioModule("studio/voice_recorder")

class El {
  constructor(attrs = {}, children = []) {
    this.attrs = { ...attrs }
    this.children = children
    children.forEach((child) => { child.parent = this })
    this.dataset = {}
    this.textContent = ""
    this.disabled = false
    this.listeners = {}
    this.events = []
    this.style = { props: {}, setProperty: (k, v) => { this.style.props[k] = v } }
  }
  setAttribute(name, value) { this.attrs[name] = String(value) }
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null }
  all() { return this.children.flatMap((child) => [child, ...child.all()]) }
  querySelector(selector) {
    const name = selector.replace(/^\[|\]$/g, "")
    return this.all().find((el) => name in el.attrs) || null
  }
  contains(el) { return el === this || this.all().includes(el) }
  closest(selector) {
    const name = selector.replace(/^\[|\]$/g, "")
    let el = this
    while (el) { if (name in el.attrs) return el; el = el.parent }
    return null
  }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn) }
  removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn) }
  dispatchEvent(event) { this.events.push(event); return true }
  fire(type, target, extra = {}) {
    const event = { type, target, preventDefault() {}, ...extra };
    (this.listeners[type] || []).forEach((fn) => fn(event))
  }
}

function buildRecorder(attrs = {}) {
  const label = new El({ "data-voice-recorder-label": "" })
  const button = new El({ "data-voice-recorder-button": "" }, [label])
  const timer = new El({ "data-voice-recorder-timer": "" })
  const status = new El({ "data-voice-recorder-status": "" })
  const root = new El(attrs, [button, timer, status])
  return { root, button, label, timer, status }
}

// level: how loud the microphone is (the analyser reads that RMS).
function stubWindow({ level = 0.1, open, recorderThrows = false, mimeSupported = () => true } = {}) {
  const log = { stopped: 0, closedContexts: 0, announced: [], recorders: [] }
  let clock = 1000
  class Recorder {
    constructor(stream, options = {}) {
      if (recorderThrows) throw new Error("cannot record this stream")
      this.state = "inactive"
      this.handlers = {}
      this.mimeType = options.mimeType || "audio/webm"
      log.recorders.push(this)
    }
    static isTypeSupported(type) { return mimeSupported(type) }
    addEventListener(type, fn) { this.handlers[type] = fn }
    start() { this.state = "recording" }
    stop() {
      this.state = "inactive"
      this.handlers.dataavailable({ data: { size: 1200, type: this.mimeType } })
      this.handlers.stop()
    }
  }
  const stream = { getTracks: () => [{ stop() { log.stopped += 1 } }] }
  const win = {
    MediaRecorder: Recorder,
    navigator: { mediaDevices: { getUserMedia: async () => stream } },
    AudioContext: class {
      constructor() { this.state = "running" }
      createMediaStreamSource() { return { connect() {} } }
      createAnalyser() { return { fftSize: 0, getFloatTimeDomainData: (buf) => buf.fill(level) } }
      close() { log.closedContexts += 1; this.state = "closed"; return Promise.resolve() }
    },
    performance: { now: () => clock },
    tick(ms) { clock += ms },
    requestAnimationFrame: () => 1,
    cancelAnimationFrame: () => {},
    setInterval: () => 2,
    clearInterval: () => {},
    dispatchEvent: (event) => { log.announced.push(event.type); return true },
    CustomEvent: class { constructor(type, init = {}) { this.type = type; this.detail = init.detail; this.bubbles = !!init.bubbles } },
    Blob: class { constructor(parts, options = {}) { this.size = parts.reduce((n, p) => n + (p.size || 0), 0); this.type = options.type } }
  }
  const opener = open || (async () => ({ stream, label: "MacBook Pro Microphone", deviceId: "mbp", fellBack: false }))
  return { win, log, open: opener, stream }
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))
const takes = (root, name) => root.events.filter((event) => event.type === name)

test("the module imports the engine's microphone and meter, and uploads nothing", () => {
  const source = studioSource("studio/voice_recorder")
  const imports = (source.match(/^\s*import\s.*$/gm) || []).map((line) => line.match(/"([^"]+)"/)[1])
  assert.deepEqual(imports, ["studio/microphone", "studio/level_meter"])
  assert.doesNotMatch(source, /\bfetch\(|FormData|XMLHttpRequest/, "consumers decide where a take goes")
  assert.doesNotMatch(source, /getFloatTimeDomainData/, "the meter is studio/level_meter's")
})

test("a heard take hands the page its blob in an event", async () => {
  const { win, log, open } = stubWindow({ level: 0.1 })
  const r = buildRecorder({ "data-voice-recorder-copy": JSON.stringify({ idle: { button: "Talk" } }) })
  mountVoiceRecorder(r.root, { win, open })
  assert.equal(r.root.dataset.voiceRecorderState, "idle")
  assert.equal(r.root.dataset.voiceRecorderReady, "true")
  assert.equal(r.label.textContent, "Talk", "the page's words win")

  r.root.fire("click", r.label)
  await flush()
  assert.equal(r.root.dataset.voiceRecorderState, "recording")
  assert.equal(r.button.getAttribute("aria-pressed"), "true")
  win.tick(1800)
  r.root.fire("click", r.button)
  await flush()

  assert.equal(r.root.dataset.voiceRecorderState, "captured")
  const [take] = takes(r.root, EVENTS.take)
  assert.ok(take, "a take event")
  assert.equal(take.bubbles, true)
  assert.equal(take.detail.blob.size, 1200)
  assert.equal(take.detail.mimeType, "audio/webm;codecs=opus")
  assert.equal(take.detail.durationMs, 1800)
  assert.ok(take.detail.peakRms >= 0.09)
  assert.deepEqual(take.detail.microphone, { label: "MacBook Pro Microphone", deviceId: "mbp" })
  assert.equal(log.stopped, 1, "the microphone is let go")
  assert.equal(log.closedContexts, 1, "the meter is closed")
  assert.ok(log.announced.includes("studio:microphone:closed"))
  assert.ok(log.announced.includes("studio:microphone:level"))
  assert.equal(r.root.style.props["--studio-recorder-level"], "0.000", "the ring rests")
})

test("a silent take is refused, names the microphone, and hands over no blob", async () => {
  const { win, log, open } = stubWindow({ level: 0.002 })
  const r = buildRecorder()
  mountVoiceRecorder(r.root, { win, open })
  r.root.fire("click", r.button)
  await flush()
  r.root.fire("click", r.button)
  await flush()
  assert.equal(r.root.dataset.voiceRecorderState, "silent")
  assert.equal(takes(r.root, EVENTS.take).length, 0)
  assert.equal(takes(r.root, EVENTS.silent).length, 1)
  assert.equal(r.status.textContent, "I couldn't hear anything from MacBook Pro Microphone. Pick another microphone and try again.")
  assert.ok(log.announced.includes("studio:microphone:silent"), "the chip counts silent takes")
  assert.equal(log.stopped, 1)
})

test("a refused microphone says so and tells the chip", async () => {
  const denied = async () => { throw Object.assign(new Error("no"), { name: "NotAllowedError" }) }
  const { win, log } = stubWindow()
  const r = buildRecorder()
  mountVoiceRecorder(r.root, { win, open: denied })
  r.root.fire("click", r.button)
  await flush()
  assert.equal(r.root.dataset.voiceRecorderState, "denied")
  assert.equal(r.status.textContent, COPY.denied.status)
  assert.ok(log.announced.includes("studio:microphone:denied"))
})

test("no microphone at all: failed, with the missing line", async () => {
  const missing = async () => { throw Object.assign(new Error("none"), { name: "NotFoundError" }) }
  const { win } = stubWindow()
  const r = buildRecorder()
  mountVoiceRecorder(r.root, { win, open: missing })
  r.root.fire("click", r.button)
  await flush()
  assert.equal(r.root.dataset.voiceRecorderState, "failed")
  assert.equal(r.status.textContent, COPY.failed.missing)
})

test("a MediaRecorder that will not start lets go of the microphone and the meter", async () => {
  const { win, log, open } = stubWindow({ recorderThrows: true })
  const r = buildRecorder()
  mountVoiceRecorder(r.root, { win, open })
  r.root.fire("click", r.button)
  await flush()
  assert.equal(r.root.dataset.voiceRecorderState, "failed")
  assert.equal(r.status.textContent, COPY.failed.start)
  assert.equal(log.stopped, 1, "the stream's tracks are stopped")
  assert.equal(log.closedContexts, 1, "the meter's context is closed")
  assert.ok(log.announced.includes("studio:microphone:closed"))
})

test("hold mode records while pressed; letting go before the microphone opens records nothing", async () => {
  const { win, log, open } = stubWindow({ level: 0.1 })
  const r = buildRecorder({ "data-voice-recorder-mode": "hold" })
  mountVoiceRecorder(r.root, { win, open })
  assert.equal(r.root.dataset.voiceRecorderMode, "hold")
  r.root.fire("click", r.button)
  await flush()
  assert.equal(r.root.dataset.voiceRecorderState, "idle", "a click is not a hold")

  r.root.fire("pointerdown", r.button, { pointerId: 1 })
  await flush()
  assert.equal(r.root.dataset.voiceRecorderState, "recording")
  r.root.fire("pointerup", r.button)
  await flush()
  assert.equal(takes(r.root, EVENTS.take).length, 1)

  r.root.fire("pointerdown", r.button, { pointerId: 1 })
  r.root.fire("pointerup", r.button)
  await flush()
  assert.equal(r.root.dataset.voiceRecorderState, "idle")
  assert.equal(log.recorders.length, 1, "no second recording started")
  assert.equal(log.stopped, 2, "the late microphone is let go")
})

test("no MediaRecorder: unsupported, and the button is disabled", () => {
  const { win, open } = stubWindow()
  delete win.MediaRecorder
  const r = buildRecorder()
  mountVoiceRecorder(r.root, { win, open })
  assert.equal(r.root.dataset.voiceRecorderState, "unsupported")
  assert.equal(r.button.disabled, true)
})

test("destroy mid-take releases everything and emits no take", async () => {
  const { win, log, open } = stubWindow({ level: 0.1 })
  const r = buildRecorder()
  const handle = mountVoiceRecorder(r.root, { win, open })
  r.root.fire("click", r.button)
  await flush()
  handle.destroy()
  assert.equal(takes(r.root, EVENTS.take).length, 0)
  assert.equal(log.stopped, 1)
  assert.equal(r.root.dataset.voiceRecorderReady, undefined)
})

test("pickMimeType prefers webm/opus, falls back to mp4 (iOS)", () => {
  assert.equal(pickMimeType(() => true), "audio/webm;codecs=opus")
  assert.equal(pickMimeType((t) => t.startsWith("audio/mp4")), "audio/mp4;codecs=mp4a.40.2")
  assert.equal(pickMimeType(() => { throw new Error("no") }), "")
  assert.equal(pickMimeType(undefined), "")
})

test("formatElapsed and mergeCopy", () => {
  assert.equal(formatElapsed(0), "0:00")
  assert.equal(formatElapsed(65_400), "1:05")
  assert.equal(formatElapsed(-5), "0:00")
  const merged = mergeCopy({ idle: { button: "Talk" }, junk: "x" })
  assert.equal(merged.idle.button, "Talk")
  assert.equal(merged.idle.status, COPY.idle.status, "the rest of the state's words stand")
  assert.equal(merged.recording.button, COPY.recording.button)
  assert.equal(merged.junk, undefined)
})

test("torn down while the microphone is opening (a Turbo visit): the late stream is let go, nothing records", async () => {
  let resolveOpen
  const { win, log, stream } = stubWindow({ level: 0.1 })
  const slowOpen = () => new Promise((resolve) => { resolveOpen = resolve })
  const r = buildRecorder()
  const handle = mountVoiceRecorder(r.root, { win, open: slowOpen })
  r.root.fire("click", r.button)
  assert.equal(r.root.dataset.voiceRecorderState, "starting")
  handle.destroy()
  resolveOpen({ stream, label: "MacBook Pro Microphone", deviceId: "mbp", fellBack: false })
  await flush()
  assert.equal(log.stopped, 1, "the microphone opened after teardown is stopped")
  assert.equal(log.recorders.length, 0, "no MediaRecorder was started")
  assert.equal(takes(r.root, EVENTS.take).length, 0)
})
