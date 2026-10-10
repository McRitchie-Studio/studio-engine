// [unit] studio/knowledge_transcript: which cue is being spoken at a time, where
// the cue list scrolls to follow it, and the binding that seeks a player from a
// click. Loaded from source as a data: module, like geo_settings.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/knowledge_transcript.js", import.meta.url), "utf8")
const {
  secondsOf, cueOrder, cueAt, followTop, mountTranscript,
  PLAYER, CUES, CUE, CURRENT_CLASS, READY_ATTRIBUTE, FOLLOW_PAUSE_MS, MAX_SEARCH_STEPS
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("secondsOf reads a whole or fractional number of seconds and nothing else", () => {
  assert.equal(secondsOf("62"), 62)
  assert.equal(secondsOf("0"), 0)
  assert.equal(secondsOf("1.5"), 1.5)
  for (const bad of [null, undefined, "", "abc", "-3", "Infinity", "NaN"]) {
    assert.ok(Number.isNaN(secondsOf(bad)), `${String(bad)} is not a time`)
  }
})

test("cueOrder sorts by time, keeps page order between equal times, and drops cues with no time", () => {
  assert.deepEqual(cueOrder([0, 5, 9]), [0, 1, 2])
  assert.deepEqual(cueOrder([30, 5, NaN, 5, 0]), [4, 1, 3, 0])
  assert.deepEqual(cueOrder([]), [])
})

test("cueAt answers the last cue that has started", () => {
  const seconds = [0, 5, 9, 20]
  const order = cueOrder(seconds)
  assert.equal(cueAt(order, seconds, 0), 0)
  assert.equal(cueAt(order, seconds, 4.99), 0)
  assert.equal(cueAt(order, seconds, 5), 1)
  assert.equal(cueAt(order, seconds, 19.9), 2)
  assert.equal(cueAt(order, seconds, 5000), 3)
})

test("cueAt answers -1 before the first cue, for no cues, and for a time that is not one", () => {
  const seconds = [3, 8]
  const order = cueOrder(seconds)
  assert.equal(cueAt(order, seconds, 2.9), -1)
  assert.equal(cueAt([], [], 10), -1)
  assert.equal(cueAt(order, seconds, NaN), -1)
})

test("cueAt reads a transcript that is out of time order by time, not by page order", () => {
  const seconds = [30, 5, 60, 5]
  const order = cueOrder(seconds)
  assert.equal(cueAt(order, seconds, 6), 3, "of two cues at 0:05 the later on the page is current")
  assert.equal(cueAt(order, seconds, 31), 0)
  assert.equal(cueAt(order, seconds, 61), 2)
})

test("cueAt on 5,000 cues compares at most 13 times, and agrees with a scan at every boundary", () => {
  const seconds = Array.from({ length: 5000 }, (_, index) => index * 2)
  const order = cueOrder(seconds)
  let reads = 0
  const counted = new Proxy(seconds, { get(target, key) { if (typeof key === "string" && /^\d+$/.test(key)) reads++; return target[key] } })

  let worst = 0
  for (const time of [-1, 0, 1, 2, 4999, 5000, 9997, 9998, 9999, 1e9]) {
    reads = 0
    const found = cueAt(order, counted, time)
    worst = Math.max(worst, reads)
    let expected = -1
    for (let index = 0; index < seconds.length; index++) if (seconds[index] <= time) expected = index
    assert.equal(found, expected, `time ${time}`)
  }
  assert.ok(worst <= 13, `a lookup read ${worst} cue times; 5,000 cues need at most 13`)
  assert.ok(MAX_SEARCH_STEPS >= 13)
})

test("followTop leaves a visible cue alone and places a hidden one a quarter of the way down", () => {
  assert.equal(followTop({ cueTop: 100, cueHeight: 40, scrollTop: 0, viewHeight: 400 }), null)
  assert.equal(followTop({ cueTop: 0, cueHeight: 40, scrollTop: 0, viewHeight: 400 }), null)
  assert.equal(followTop({ cueTop: 380, cueHeight: 40, scrollTop: 0, viewHeight: 400 }), 280, "cut off at the bottom")
  assert.equal(followTop({ cueTop: 1000, cueHeight: 40, scrollTop: 0, viewHeight: 400 }), 900)
  assert.equal(followTop({ cueTop: 50, cueHeight: 40, scrollTop: 600, viewHeight: 400 }), 0, "never above the top")
})

// --- the binding, against a page of plain objects ---------------------------

function emitter() {
  const listeners = new Map()
  return {
    listeners,
    addEventListener(type, handler) { listeners.set(type, [...(listeners.get(type) || []), handler]) },
    removeEventListener(type, handler) { listeners.set(type, (listeners.get(type) || []).filter((item) => item !== handler)) },
    emit(type, event = {}) { (listeners.get(type) || []).forEach((handler) => handler(event)) }
  }
}

const CUE_HEIGHT = 40

function page(times, { viewHeight = 100 } = {}) {
  const writes = { classes: 0, scrolls: 0 }
  const list = {
    ...emitter(),
    clientHeight: viewHeight,
    position: 0,
    get scrollTop() { return this.position },
    set scrollTop(value) { writes.scrolls++; this.position = value },
    getBoundingClientRect() { return { top: 0, height: viewHeight } },
    contains: (node) => cues.includes(node),
    querySelectorAll: (selector) => (selector === CUE ? cues : [])
  }
  const cues = times.map((time, index) => {
    const classes = new Set()
    const attributes = new Map(time === null ? [] : [["data-seconds", String(time)]])
    const cue = {
      index,
      classes,
      attributes,
      classList: {
        add(name) { writes.classes++; classes.add(name) },
        remove(name) { writes.classes++; classes.delete(name) }
      },
      getAttribute: (name) => (attributes.has(name) ? attributes.get(name) : null),
      setAttribute: (name, value) => attributes.set(name, value),
      removeAttribute: (name) => attributes.delete(name),
      getBoundingClientRect: () => ({ top: index * CUE_HEIGHT - list.position, height: CUE_HEIGHT }),
      closest: (selector) => (selector === CUE ? cue : null)
    }
    // The cue's time button: a click on it reports the button, inside the cue.
    cue.button = { closest: (selector) => (selector === CUE ? cue : (selector === "button" ? cue.button : null)) }
    return cue
  })
  const media = { ...emitter(), currentTime: 0, plays: 0, play() { this.plays++; return Promise.resolve() } }
  const attributes = new Map()
  const root = {
    attributes,
    querySelector: (selector) => (selector === PLAYER ? media : (selector === CUES ? list : null)),
    setAttribute: (name, value) => attributes.set(name, value),
    removeAttribute: (name) => attributes.delete(name)
  }
  return { root, media, list, cues, writes }
}

const current = (cues) => cues.filter((cue) => cue.classes.has(CURRENT_CLASS)).map((cue) => cue.index)

test("mounting marks the page ready, and a page with no player or no cue list is left alone", () => {
  const { root } = page([0, 5])
  const mounted = mountTranscript(root, { win: null })
  assert.ok(mounted)
  assert.ok(root.attributes.has(READY_ATTRIBUTE))

  const bare = { querySelector: () => null, setAttribute: () => assert.fail("a page with no player was marked ready") }
  assert.equal(mountTranscript(bare, { win: null }), null)
})

test("a click on a cue's time sets the player's time, plays, and marks that cue", () => {
  const { root, media, list, cues } = page([0, 5, 9])
  mountTranscript(root, { win: null })
  assert.deepEqual(current(cues), [0], "the cue at 0:00 is current before anything plays")

  list.emit("click", { target: cues[2].button })
  assert.equal(media.currentTime, 9)
  assert.equal(media.plays, 1)
  assert.deepEqual(current(cues), [2])
  assert.equal(cues[2].attributes.get("aria-current"), "true")
  assert.equal(cues[0].attributes.has("aria-current"), false)
})

test("a click on the line seeks too, unless it finished a text selection; the time button always seeks", () => {
  const { root, media, list, cues } = page([0, 5, 9])
  let selected = ""
  const win = { getSelection: () => ({ isCollapsed: selected === "", toString: () => selected }) }
  mountTranscript(root, { win })

  list.emit("click", { target: cues[1] })
  assert.equal(media.currentTime, 5)

  selected = "a quoted sentence"
  list.emit("click", { target: cues[2] })
  assert.equal(media.currentTime, 5, "selecting text is not a request to seek")
  assert.equal(media.plays, 1)

  list.emit("click", { target: cues[2].button })
  assert.equal(media.currentTime, 9)
})

test("a click outside any cue, or on a cue with no time, does nothing", () => {
  const { root, media, list, cues } = page([0, null, 9])
  mountTranscript(root, { win: null })
  media.currentTime = 3

  list.emit("click", { target: { closest: () => null } })
  list.emit("click", { target: cues[1] })
  list.emit("click", { target: {} })
  assert.equal(media.currentTime, 3)
  assert.equal(media.plays, 0)
})

test("a play() the browser refuses is swallowed, not thrown", async () => {
  const { root, media, list, cues } = page([0, 5])
  const refused = Promise.reject(new Error("NotAllowedError"))
  media.play = () => refused
  mountTranscript(root, { win: null })
  list.emit("click", { target: cues[1].button })
  await assert.rejects(refused)
  await new Promise((resolve) => setTimeout(resolve, 0))
  assert.equal(media.currentTime, 5)
})

test("timeupdate writes to the page only when the current cue changes", () => {
  const { root, media, cues, writes } = page([0, 10, 20])
  mountTranscript(root, { win: null })
  const afterMount = writes.classes

  for (const time of [1, 2, 3, 4, 9.9]) {
    media.currentTime = time
    media.emit("timeupdate")
  }
  assert.equal(writes.classes, afterMount, "five updates inside one cue wrote nothing")

  media.currentTime = 10
  media.emit("timeupdate")
  assert.equal(writes.classes, afterMount + 2, "one class off, one class on")
  assert.deepEqual(current(cues), [1])

  media.currentTime = 25
  media.emit("seeked")
  assert.deepEqual(current(cues), [2], "a seek from the player's own bar is followed too")
})

test("before the first cue nothing is marked", () => {
  const { root, media, cues } = page([5, 10])
  mountTranscript(root, { win: null })
  assert.deepEqual(current(cues), [])
  media.currentTime = 6
  media.emit("timeupdate")
  assert.deepEqual(current(cues), [0])
  media.currentTime = 1
  media.emit("timeupdate")
  assert.deepEqual(current(cues), [])
})

test("the list follows the current cue, and stops while the reader is scrolling it", () => {
  const times = Array.from({ length: 50 }, (_, index) => index * 10)
  const { root, media, list, cues, writes } = page(times)
  let clock = 1_000_000
  mountTranscript(root, { now: () => clock, win: null })

  media.currentTime = 200
  media.emit("timeupdate")
  assert.equal(list.scrollTop, 20 * CUE_HEIGHT - 25, "cue 20, a quarter of the way down a 100px list")
  list.emit("scroll")
  const followed = writes.scrolls

  // The reader scrolls away. Following stops, whatever plays.
  list.position = 40
  list.emit("scroll")
  media.currentTime = 300
  media.emit("timeupdate")
  assert.equal(list.scrollTop, 40, "the list stayed where the reader left it")
  assert.equal(writes.scrolls, followed)
  assert.deepEqual(current(cues), [30], "the cue is still marked")

  // Still scrolling: each scroll renews the pause.
  clock += FOLLOW_PAUSE_MS - 1
  list.position = 60
  list.emit("scroll")
  clock += FOLLOW_PAUSE_MS - 1
  media.currentTime = 310
  media.emit("timeupdate")
  assert.equal(list.scrollTop, 60)

  // Left alone for the pause, the next cue is followed again.
  clock += 2
  media.currentTime = 320
  media.emit("timeupdate")
  assert.equal(list.scrollTop, 32 * CUE_HEIGHT - 25)
})

test("its own scroll does not count as the reader's", () => {
  const times = Array.from({ length: 50 }, (_, index) => index * 10)
  const { root, media, list } = page(times)
  mountTranscript(root, { now: () => 1, win: null })

  media.currentTime = 200
  media.emit("timeupdate")
  list.emit("scroll")
  media.currentTime = 400
  media.emit("timeupdate")
  assert.equal(list.scrollTop, 40 * CUE_HEIGHT - 25, "following went on after the scroll it caused")
})

test("a click on a cue resumes following at once", () => {
  const times = Array.from({ length: 50 }, (_, index) => index * 10)
  const { root, media, list, cues } = page(times)
  mountTranscript(root, { now: () => 1, win: null })
  list.position = 400
  list.emit("scroll")

  list.emit("click", { target: cues[45].button })
  assert.equal(media.currentTime, 450)
  assert.equal(list.scrollTop, 45 * CUE_HEIGHT - 25)
})

test("destroy unbinds everything and clears the mark", () => {
  const { root, media, list, cues } = page([0, 5])
  const mounted = mountTranscript(root, { win: null })
  mounted.destroy()

  assert.equal(root.attributes.has(READY_ATTRIBUTE), false)
  assert.deepEqual(current(cues), [])
  for (const [type, handlers] of [...media.listeners, ...list.listeners]) assert.deepEqual(handlers, [], `${type} is still bound`)
  list.emit("click", { target: cues[1].button })
  assert.equal(media.currentTime, 0)
})
