// [unit] studio/level_meter: the engine's one level meter. The silence line,
// the logarithmic scale, takeWasHeard's thresholds, and a meter run against a
// stub Web Audio graph: frames counted only while the context runs, the peak
// kept, paint stepped under reduced motion, close releasing frames, timer and
// context. Loaded from source as a data: module (it imports nothing).
import { test } from "node:test"
import assert from "node:assert/strict"
import { studioSource, loadStudioModule } from "./support/studio_module.mjs"

const {
  SILENCE_RMS, rootMeanSquare, peakWindowRms, meterLevel, takeWasHeard, steppedLevel, createLevelMeter
} = await loadStudioModule("studio/level_meter")

test("the module imports nothing", () => {
  assert.doesNotMatch(studioSource("studio/level_meter"), /^\s*import\s/m)
})

test("the silence line is -40 dBFS, as measured in Voicebox", () => {
  assert.equal(SILENCE_RMS, 0.01)
})

test("rootMeanSquare and peakWindowRms", () => {
  assert.equal(rootMeanSquare([]), 0)
  assert.equal(rootMeanSquare(null), 0)
  assert.ok(Math.abs(rootMeanSquare([0.5, -0.5, 0.5, -0.5]) - 0.5) < 1e-12)
  const quietThenLoud = new Float32Array(1600)
  for (let i = 800; i < 1600; i++) quietThenLoud[i] = i % 2 ? 0.2 : -0.2
  assert.ok(Math.abs(peakWindowRms(quietThenLoud) - 0.2) < 1e-6, "the loudest window, not the mean")
  assert.equal(peakWindowRms(null), 0)
})

test("meterLevel maps -40..-10 dBFS onto 0..1 and clamps", () => {
  assert.equal(meterLevel(0), 0)
  assert.equal(meterLevel(NaN), 0)
  assert.ok(Math.abs(meterLevel(0.01)) < 1e-9)
  assert.ok(Math.abs(meterLevel(Math.pow(10, -10 / 20)) - 1) < 1e-9)
  assert.equal(meterLevel(1), 1)
})

test("takeWasHeard: the measured peak must reach the line; an unmeasured take is let through", () => {
  assert.equal(takeWasHeard(0.0099, 40), false)
  assert.equal(takeWasHeard(0.01, 40), true)
  assert.equal(takeWasHeard(0.3, 1), true)
  assert.equal(takeWasHeard(0, 0), true)
})

test("steppedLevel rounds to quarters only under reduced motion", () => {
  assert.equal(steppedLevel(0.6, false), 0.6)
  assert.equal(steppedLevel(0.6, true), 0.5)
  assert.equal(steppedLevel(0.9, true), 1)
})

// A browser double: one analyser whose next frame the test sets, frames and
// timers run by hand.
function stubWindow({ state = "running", reduced = false, noAudio = false, throwOnSource = false } = {}) {
  const log = { closed: 0, frames: new Map(), timers: new Map(), resumed: 0 }
  let nextId = 1
  let clock = 0
  const win = {
    level: 0,
    performance: { now: () => clock },
    tick(ms) { clock += ms },
    matchMedia: (query) => ({ matches: reduced && /reduce/.test(query) }),
    requestAnimationFrame: (fn) => { const id = nextId++; log.frames.set(id, fn); return id },
    cancelAnimationFrame: (id) => log.frames.delete(id),
    setInterval: (fn) => { const id = nextId++; log.timers.set(id, fn); return id },
    clearInterval: (id) => log.timers.delete(id),
    runTimers() { [...log.timers.values()].forEach((fn) => fn()) },
    log
  }
  if (!noAudio) {
    win.AudioContext = class {
      constructor() { this.state = state }
      resume() { log.resumed += 1; return Promise.resolve() }
      close() { log.closed += 1; this.state = "closed"; return Promise.resolve() }
      createMediaStreamSource() {
        if (throwOnSource) throw new Error("no source")
        return { connect() {} }
      }
      createAnalyser() {
        return { fftSize: 0, getFloatTimeDomainData: (buffer) => buffer.fill(win.level) }
      }
    }
  }
  return win
}

test("a running meter keeps the peak, reports each sample and paints the level", () => {
  const win = stubWindow()
  const samples = []
  const paints = []
  const meter = createLevelMeter({}, { win, onSample: (rms) => samples.push(rms), onPaint: (level) => paints.push(level) })
  assert.deepEqual(paints, [0], "paints 0 at the start")
  assert.equal(win.log.frames.size, 1)
  assert.equal(win.log.timers.size, 1, "a timer measures a background tab")
  win.level = 0.005
  meter.sample()
  win.level = 0.1
  win.runTimers()
  win.level = 0.02
  meter.sample()
  assert.equal(meter.frames, 3)
  assert.ok(Math.abs(meter.peak - 0.1) < 1e-6)
  assert.equal(meter.heard(), true)
  assert.equal(samples.length, 3)
  assert.ok(paints.at(-1) > 0)
  meter.close()
  assert.equal(win.log.frames.size, 0)
  assert.equal(win.log.timers.size, 0)
  assert.equal(win.log.closed, 1)
  assert.equal(paints.at(-1), 0, "closing paints 0")
  assert.equal(meter.sample(), null, "a closed meter samples nothing")
})

test("a quiet take is not heard", () => {
  const win = stubWindow()
  const meter = createLevelMeter({}, { win })
  win.level = 0.004
  meter.sample(); meter.sample()
  assert.equal(meter.heard(), false)
})

test("a suspended context counts no frames, so the take is let through", () => {
  const win = stubWindow({ state: "suspended" })
  const meter = createLevelMeter({}, { win })
  assert.equal(win.log.resumed, 1, "it asks to resume")
  meter.sample()
  assert.equal(meter.frames, 0)
  assert.equal(meter.heard(), true)
})

test("no Web Audio, or a graph that fails to build: nothing measured, nothing left running", () => {
  const plain = stubWindow({ noAudio: true })
  const none = createLevelMeter({}, { win: plain })
  assert.equal(none.sample(), null)
  assert.equal(none.heard(), true)
  assert.equal(plain.log.timers.size, 0)

  const failing = stubWindow({ throwOnSource: true })
  const meter = createLevelMeter({}, { win: failing })
  assert.equal(failing.log.closed, 1, "the context it made is closed")
  assert.equal(failing.log.timers.size + failing.log.frames.size, 0)
  assert.equal(meter.heard(), true)
})

test("reduced motion paints in quarters, at most four times a second", () => {
  const win = stubWindow({ reduced: true })
  const paints = []
  const meter = createLevelMeter({}, { win, onPaint: (level) => paints.push(level) })
  win.level = 0.05
  win.tick(300); meter.sample()
  win.tick(100); meter.sample()
  win.tick(200); meter.sample()
  assert.equal(meter.frames, 3)
  assert.equal(paints.length, 3, "the start, then two of three samples")
  assert.ok(paints.slice(1).every((level) => level * 4 === Math.round(level * 4)))
})
