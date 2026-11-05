// studio/voice_recorder: one record button that captures a take and hands the
// finished audio to the page. It never uploads: the page listens for the take
// event and decides where the audio goes (a chat message, a transcript, an
// embedding). Ported from Voicebox's recorder_controller.js; the contract is in
// docs/VOICE_CAPTURE.md.
//
//   <div data-studio-controller="voice-recorder" data-voice-recorder-state="idle"
//        data-voice-recorder-max-ms="60000" data-voice-recorder-mode="toggle"
//        data-voice-recorder-copy='{"idle":{"button":"Talk"}}'>
//     <button type="button" data-voice-recorder-button>
//       <span data-voice-recorder-label>Record</span></button>
//     <span data-voice-recorder-timer>0:00</span>
//     <p data-voice-recorder-status role="status"></p>
//   </div>
//
// STATES, on data-voice-recorder-state: idle -> starting -> recording ->
// captured | silent | failed, plus denied (the microphone was refused),
// unsupported (no MediaRecorder) and, in hold mode, tapped (let go too soon to be a
// take). Any of idle, captured, silent, failed, denied and tapped takes a new press.
//
// EVENTS, dispatched on the root (they bubble):
//   studio:voice-recorder:take    detail { blob, mimeType, durationMs, peakRms, microphone: { label, deviceId } }
//   studio:voice-recorder:silent  detail { durationMs, microphone }  (nothing heard: no blob is handed over)
//   studio:voice-recorder:state   detail { state }
//   studio:voice-recorder:hint    detail { kind, text }  (kind "heard" or "quiet", while it records)
// and, on window, studio/microphone's EVENTS, which the chip listens to.
//
// MODES: "toggle" (tap to start, tap to stop) or "hold" (press and hold to
// talk; letting go stops). While it records, --studio-recorder-level (0..1) on
// the root drives the ring (studio/level_meter), and data-voice-recorder-heard
// turns "true" once a frame clears SILENCE_RMS.
import { openMicrophone, announce, silentMessage, EVENTS as MICROPHONE_EVENTS } from "studio/microphone"
import { createLevelMeter, SILENCE_RMS } from "studio/level_meter"

export const EVENTS = {
  take: "studio:voice-recorder:take",
  silent: "studio:voice-recorder:silent",
  state: "studio:voice-recorder:state",
  hint: "studio:voice-recorder:hint"
}

// What to ask MediaRecorder for, in order: webm/opus on Chrome and Firefox,
// mp4/aac on iOS Safari. The first the browser supports wins.
export const MIME_CANDIDATES = [
  "audio/webm;codecs=opus",
  "audio/webm",
  "audio/mp4;codecs=mp4a.40.2",
  "audio/mp4",
  "audio/ogg;codecs=opus"
]

export const READY = ["idle", "captured", "silent", "failed", "denied", "tapped"]

// Hold mode: a take shorter than this is a tap, not a hold. It says how to use the
// button and tells the chip nothing: the frames a tap records are too few to judge
// the microphone by, and two silent takes in a row would open the help.
export const TAP_MS = 300

// How long a take may stay silent before the status asks whether the
// microphone is on.
export const QUIET_HINT_MS = 2500

export const COPY = {
  idle: { button: "Record", status: "" },
  starting: { button: "Starting...", status: "" },
  recording: { button: "Stop", status: "Listening...", quiet: "I can't hear anything yet. Is your microphone on?", heard: "Listening..." },
  captured: { button: "Record again", status: "Got it." },
  silent: { button: "Record", status: "I couldn't hear anything. Check your microphone and try again.",
            named: "I couldn't hear anything from %{microphone}. Pick another microphone and try again." },
  failed: { button: "Try again", status: "That didn't record. Try again.", start: "I couldn't start recording. Try again.",
            missing: "I couldn't find a microphone. Plug one in and try again.",
            busy: "Your microphone is busy in another app. Close it there, then try again." },
  denied: { button: "Record", status: "Allow the microphone to record." },
  tapped: { button: "Record", status: "Hold the button while you talk, then let go." },
  unsupported: { button: "Record", status: "This browser can't record here. Try Safari or Chrome." }
}

export function pickMimeType(isTypeSupported) {
  if (typeof isTypeSupported !== "function") return ""
  return MIME_CANDIDATES.find((type) => {
    try { return isTypeSupported(type) } catch (_) { return false }
  }) || ""
}

export function formatElapsed(ms) {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`
}

// The line for a microphone that would not open (NotAllowedError is "denied",
// not this). NotReadableError is a microphone another app holds (Chrome's
// older name, TrackStartError; Firefox can say AbortError); everything else
// reads as no microphone found.
export const BUSY_ERRORS = ["NotReadableError", "TrackStartError", "AbortError"]

export function failedLine(error, copy = COPY) {
  const busy = !!error && BUSY_ERRORS.includes(error.name)
  return busy ? (copy.failed.busy || COPY.failed.busy) : copy.failed.missing
}

// The page's words over the defaults, one state at a time.
export function mergeCopy(overrides) {
  const merged = {}
  Object.keys(COPY).forEach((state) => { merged[state] = { ...COPY[state] } })
  if (overrides && typeof overrides === "object") {
    Object.entries(overrides).forEach(([state, words]) => {
      if (words && typeof words === "object") merged[state] = { ...(merged[state] || {}), ...words }
    })
  }
  return merged
}

function parseJson(text) {
  try { return JSON.parse(text || "null") } catch (_) { return null }
}

// Binds one recorder. Returns { start, stop, toggle, destroy, get state }.
// options.open and options.meter replace openMicrophone and createLevelMeter
// (the unit tests pass stubs).
export function mountVoiceRecorder(root, { win = window, open = openMicrophone, meter: makeMeter = createLevelMeter } = {}) {
  const one = (selector) => root.querySelector(selector)
  const copy = mergeCopy(parseJson(root.getAttribute("data-voice-recorder-copy")))
  const maxMs = parseInt(root.getAttribute("data-voice-recorder-max-ms") || "0", 10) || 0
  const mode = root.getAttribute("data-voice-recorder-mode") === "hold" ? "hold" : "toggle"
  const now = () => win.performance.now()

  let state = null
  let stream = null
  let recorder = null
  let meter = null
  let chunks = []
  let timer = null
  let startedAt = 0
  let microphone = { label: "", deviceId: null }
  let hinted = null
  let stopWanted = false
  let keyHeld = false
  let destroyed = false

  function setState(next, message = null) {
    state = next
    root.dataset.voiceRecorderState = next
    const words = copy[next] || {}
    const label = one("[data-voice-recorder-label]")
    if (label && words.button) label.textContent = words.button
    const status = one("[data-voice-recorder-status]")
    if (status) status.textContent = message || words.status || ""
    const button = one("[data-voice-recorder-button]")
    if (button) {
      button.setAttribute("aria-pressed", next === "recording" ? "true" : "false")
      button.disabled = next === "unsupported"
    }
    if (next === "idle") paintTimer(0)
    root.dispatchEvent(new win.CustomEvent(EVENTS.state, { bubbles: true, detail: { state: next } }))
  }

  function supported() {
    return !!(win.MediaRecorder && win.navigator && win.navigator.mediaDevices && win.navigator.mediaDevices.getUserMedia)
  }

  function paintLevel(level) {
    root.style.setProperty("--studio-recorder-level", level.toFixed(3))
    root.dataset.voiceRecorderLevel = level.toFixed(2)
  }

  function paintTimer(ms) {
    const el = one("[data-voice-recorder-timer]")
    if (el) el.textContent = formatElapsed(ms)
  }

  function hint(kind) {
    if (state !== "recording" || hinted === kind || copy.recording[kind] == null) return
    hinted = kind
    const status = one("[data-voice-recorder-status]")
    if (status) status.textContent = copy.recording[kind]
    root.dispatchEvent(new win.CustomEvent(EVENTS.hint, { bubbles: true, detail: { kind, text: copy.recording[kind] } }))
  }

  function onSample(rms) {
    announce(MICROPHONE_EVENTS.level, { rms }, win)
    if (rms >= SILENCE_RMS && root.dataset.voiceRecorderHeard !== "true") {
      root.dataset.voiceRecorderHeard = "true"
      hint("heard")
    } else if (root.dataset.voiceRecorderHeard !== "true" && startedAt && now() - startedAt > QUIET_HINT_MS) {
      hint("quiet")
    }
    root.dataset.voiceRecorderPeak = meter ? meter.peak.toFixed(4) : "0"
  }

  function stopTimer() {
    if (timer) win.clearInterval(timer)
    timer = null
  }

  // Lets go of the meter and the microphone, and tells the chip.
  function release() {
    stopTimer()
    if (meter) meter.close()
    meter = null
    if (stream) {
      stream.getTracks().forEach((track) => track.stop())
      announce(MICROPHONE_EVENTS.closed, {}, win)
    }
    stream = null
  }

  async function start() {
    if (destroyed || !READY.includes(state)) return
    stopWanted = false
    setState("starting")
    let opened
    try {
      opened = await open(win.navigator.mediaDevices)
    } catch (error) {
      if (destroyed) return
      const denied = error && error.name === "NotAllowedError"
      if (denied) announce(MICROPHONE_EVENTS.denied, {}, win)
      setState(denied ? "denied" : "failed", denied ? null : failedLine(error, copy))
      return
    }
    stream = opened.stream
    microphone = { label: opened.label || "", deviceId: opened.deviceId || null }
    // Destroyed, or let go of (hold mode) before the microphone opened.
    if (destroyed || stopWanted) {
      release()
      if (!destroyed) setState(mode === "hold" ? "tapped" : "idle")
      return
    }
    chunks = []
    try {
      begin(stream)
    } catch (_) {
      // MediaRecorder refused the stream: let go of the microphone, the meter
      // and its frames rather than leave them running.
      recorder = null
      release()
      setState("failed", copy.failed.start)
    }
  }

  function begin(source) {
    root.dataset.voiceRecorderHeard = "false"
    root.dataset.voiceRecorderPeak = "0"
    hinted = null
    meter = makeMeter(source, { win, onSample, onPaint: paintLevel })
    const MediaRecorderClass = win.MediaRecorder
    const mimeType = pickMimeType(MediaRecorderClass.isTypeSupported && MediaRecorderClass.isTypeSupported.bind(MediaRecorderClass))
    try {
      recorder = mimeType ? new MediaRecorderClass(source, { mimeType }) : new MediaRecorderClass(source)
    } catch (_) {
      recorder = new MediaRecorderClass(source)
    }
    recorder.addEventListener("dataavailable", (event) => {
      if (event.data && event.data.size > 0) chunks.push(event.data)
    })
    recorder.addEventListener("stop", () => finish())
    recorder.start(250)
    startedAt = now()
    paintTimer(0)
    timer = win.setInterval(() => {
      const elapsed = now() - startedAt
      paintTimer(elapsed)
      if (maxMs && elapsed >= maxMs) stop()
    }, 250)
    setState("recording")
  }

  function stop() {
    if (state === "starting") { stopWanted = true; return }
    if (recorder && recorder.state !== "inactive") recorder.stop()
  }

  function finish() {
    const durationMs = Math.round(now() - startedAt)
    stopTimer()
    if (meter) meter.sample()
    const heard = meter ? meter.heard() : true
    const peakRms = meter ? meter.peak : 0
    const type = (recorder && recorder.mimeType) || (chunks[0] && chunks[0].type) || "audio/webm"
    const blob = new win.Blob(chunks, { type })
    chunks = []
    recorder = null
    release()
    if (destroyed) return
    if (mode === "hold" && durationMs < TAP_MS) {
      setState("tapped")
      return
    }
    if (blob.size === 0 || !heard) {
      setState("silent", silentMessage(copy.silent.named, microphone.label))
      announce(MICROPHONE_EVENTS.silent, { label: microphone.label }, win)
      root.dispatchEvent(new win.CustomEvent(EVENTS.silent, { bubbles: true, detail: { durationMs, microphone: { ...microphone } } }))
      return
    }
    setState("captured")
    root.dispatchEvent(new win.CustomEvent(EVENTS.take, {
      bubbles: true,
      detail: { blob, mimeType: type, durationMs, peakRms, microphone: { ...microphone } }
    }))
  }

  function toggle() {
    if (state === "recording" || state === "starting") stop()
    else start()
  }

  // Buttons inside the root: the record button follows the mode.
  function onClick(event) {
    if (mode !== "toggle") return
    const button = event.target.closest && event.target.closest("[data-voice-recorder-button]")
    if (!button || !root.contains(button)) return
    event.preventDefault()
    toggle()
  }

  function onPointerDown(event) {
    if (mode !== "hold") return
    const button = event.target.closest && event.target.closest("[data-voice-recorder-button]")
    if (!button || !root.contains(button)) return
    // Only the main button holds: a right-click (or a Mac's control-click) is a
    // context menu, not a take. Touch and pen report button 0.
    if (event.button || event.ctrlKey) return
    event.preventDefault()
    if (button.setPointerCapture && event.pointerId != null) {
      try { button.setPointerCapture(event.pointerId) } catch (_) { /* a synthetic pointer */ }
    }
    start()
  }

  function onPointerUp() {
    if (mode === "hold" && (state === "recording" || state === "starting")) stop()
  }

  // Hold mode by keyboard: Space or Enter held down records.
  function onKeyDown(event) {
    if (mode !== "hold" || event.repeat || ![" ", "Enter"].includes(event.key)) return
    if (!event.target.closest || !event.target.closest("[data-voice-recorder-button]")) return
    event.preventDefault()
    keyHeld = true
    start()
  }

  function onKeyUp(event) {
    if (mode !== "hold" || ![" ", "Enter"].includes(event.key)) return
    event.preventDefault()
    keyHeld = false
    onPointerUp()
  }

  // A key held on the button when focus leaves it (Tab, another window): its
  // keyup lands elsewhere and never reaches here, and the microphone would stay
  // live to the max_ms cap and send a take on its own. A pointer hold is captured,
  // so it has its own pointerup.
  function onFocusOut() {
    if (!keyHeld) return
    keyHeld = false
    onPointerUp()
  }

  root.addEventListener("click", onClick)
  root.addEventListener("pointerdown", onPointerDown)
  root.addEventListener("pointerup", onPointerUp)
  root.addEventListener("pointercancel", onPointerUp)
  root.addEventListener("keydown", onKeyDown)
  root.addEventListener("keyup", onKeyUp)
  root.addEventListener("focusout", onFocusOut)
  root.dataset.voiceRecorderMode = mode
  paintLevel(0)
  if (supported()) setState("idle")
  else setState("unsupported")
  root.dataset.voiceRecorderReady = "true"

  return {
    start,
    stop,
    toggle,
    get state() { return state },
    destroy() {
      destroyed = true
      root.removeEventListener("click", onClick)
      root.removeEventListener("pointerdown", onPointerDown)
      root.removeEventListener("pointerup", onPointerUp)
      root.removeEventListener("pointercancel", onPointerUp)
      root.removeEventListener("keydown", onKeyDown)
      root.removeEventListener("keyup", onKeyUp)
      root.removeEventListener("focusout", onFocusOut)
      if (recorder && recorder.state !== "inactive") {
        try { recorder.stop() } catch (_) { /* already stopped */ }
      }
      recorder = null
      release()
      delete root.dataset.voiceRecorderReady
    }
  }
}
