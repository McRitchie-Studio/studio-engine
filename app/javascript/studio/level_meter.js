// studio/level_meter: the ONE level meter every engine recorder uses (the voice
// recorder, studio/voice_recorder, and the voice row, studio/voice_profile). It
// reads a live microphone stream through a Web Audio AnalyserNode, keeps the
// take's loudest frame, and paints a 0..1 level the page draws as a ring or a
// dot. Voicebox carried two copies of this (its recorder and its voice setup);
// the engine carries one (docs/VOICE_CAPTURE.md).
//
//   const meter = createLevelMeter(stream, { onPaint: (level) => ..., onSample: (rms) => ... })
//   ... meter.sample() ...       // the recorder also samples on its own timer
//   const heard = meter.heard()  // before close: did the take clear SILENCE_RMS?
//   meter.close()                // stops frames and the timer, closes the context, paints 0
//
// WHY A TAKE IS JUDGED. A muted or wrong microphone records perfect silence,
// and a speech model handed silence makes a word up. A take whose loudest frame
// stayed under SILENCE_RMS is refused by the recorder before it goes anywhere.
//
// It imports nothing, so test/javascript/level_meter.test.mjs loads it as a
// data: module.

// The loudest frame (RMS of the samples, 0..1) a take must reach to count as
// heard: 0.01 is -40 dBFS. A muted or absent microphone sits at 0, a quiet room
// on a laptop microphone near 0.002-0.006, and speech at arm's length peaks
// well above 0.05, so a real voice clears it many times over. Measured in
// Voicebox.
export const SILENCE_RMS = 0.01

// How often the meter samples on a timer as well as on animation frames: a
// background tab stops frames, and a take recorded there is still measured.
export const SAMPLE_INTERVAL_MS = 100

// Reduced motion: the level steps four times a second, in quarters, instead
// of gliding.
export const REDUCED_PAINT_MS = 250

export function rootMeanSquare(samples) {
  if (!samples || samples.length === 0) return 0
  let sum = 0
  for (let i = 0; i < samples.length; i++) sum += samples[i] * samples[i]
  return Math.sqrt(sum / samples.length)
}

// The loudest window's RMS, 0..1 (800 samples is 50 ms at 16 kHz): the same
// silence rule applied to decoded samples rather than a live stream.
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

// The meter's reading, 0..1, for an RMS level: speech lives between about
// 0.01 and 0.3, so the scale is logarithmic from -40 dBFS to -10 dBFS.
export function meterLevel(rms) {
  if (!(rms > 0)) return 0
  const db = 20 * Math.log10(rms)
  return Math.min(1, Math.max(0, (db + 40) / 30))
}

// Heard, unless the meter measured the take and it stayed under SILENCE_RMS. A
// take the meter never measured (no Web Audio, a context that never ran) is let
// through, and whatever receives it (a server, an embedder) decides.
export function takeWasHeard(peakRms, framesMeasured) {
  if (!framesMeasured) return true
  return peakRms >= SILENCE_RMS
}

// The level as painted: in quarters under reduced motion.
export function steppedLevel(level, reduced) {
  return reduced ? Math.round(level * 4) / 4 : level
}

export function prefersReducedMotion(win = globalThis) {
  try { return !!(win.matchMedia && win.matchMedia("(prefers-reduced-motion: reduce)").matches) } catch (_) { return false }
}

// Starts measuring a live stream. Opened after the microphone prompt resolves,
// so a strict autoplay rule (iOS) can leave the context suspended: those frames
// read zeros and prove nothing, so they are not counted, and an unmeasured take
// is let through (takeWasHeard). Without Web Audio the meter measures nothing
// and paints nothing beyond 0; the take still records.
//
// onSample(rms) runs on every counted frame (the recorder tells the chip);
// onPaint(level) runs with the 0..1 level to draw.
export function createLevelMeter(stream, { win = globalThis, onSample = () => {}, onPaint = () => {}, intervalMs = SAMPLE_INTERVAL_MS } = {}) {
  let audioContext = null
  let analyser = null
  let buffer = null
  let frame = null
  let timer = null
  let peak = 0
  let frames = 0
  let lastPaint = 0
  let closed = false
  const reduced = prefersReducedMotion(win)
  const now = () => (win.performance && win.performance.now ? win.performance.now() : Date.now())

  function paint(level) {
    try { onPaint(steppedLevel(level, reduced)) } catch (_) { /* a painter's error never stops the take */ }
  }

  function sample() {
    if (closed || !analyser || !audioContext || audioContext.state !== "running") return null
    analyser.getFloatTimeDomainData(buffer)
    const rms = rootMeanSquare(buffer)
    frames += 1
    if (rms > peak) peak = rms
    try { onSample(rms) } catch (_) { /* as above */ }
    const t = now()
    if (!reduced || t - lastPaint >= REDUCED_PAINT_MS) {
      lastPaint = t
      paint(meterLevel(rms))
    }
    return rms
  }

  function close() {
    if (frame != null && win.cancelAnimationFrame) win.cancelAnimationFrame(frame)
    if (timer != null && win.clearInterval) win.clearInterval(timer)
    frame = null
    timer = null
    analyser = null
    if (audioContext && audioContext.state !== "closed" && audioContext.close) {
      try { audioContext.close().catch(() => {}) } catch (_) { /* already gone */ }
    }
    audioContext = null
    closed = true
    paint(0)
  }

  paint(0)
  const AudioContextClass = win.AudioContext || win.webkitAudioContext
  if (AudioContextClass && stream) {
    try {
      audioContext = new AudioContextClass()
      const source = audioContext.createMediaStreamSource(stream)
      analyser = audioContext.createAnalyser()
      analyser.fftSize = 1024
      buffer = new Float32Array(analyser.fftSize)
      source.connect(analyser)
      if (audioContext.state === "suspended" && audioContext.resume) audioContext.resume().catch(() => {})
      if (win.requestAnimationFrame) {
        const loop = () => {
          sample()
          if (!closed) frame = win.requestAnimationFrame(loop)
        }
        frame = win.requestAnimationFrame(loop)
      }
      if (win.setInterval) timer = win.setInterval(sample, intervalMs)
    } catch (_) {
      close() // measured nothing: heard() lets the take through
    }
  }

  return {
    sample,
    close,
    heard: () => takeWasHeard(peak, frames),
    get peak() { return peak },
    get frames() { return frames }
  }
}
