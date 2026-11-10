// [unit] studio/carousel's watchRest: when a scrolling row has come to rest, so a
// looping row on a clone jumps home (the controller's settle()).
//
// CONTROLS, run against this file (2026-11-09):
//   - the backstop removed (onScroll arms no timer where scrollend exists): the
//     "one scroll event and no scrollend" and "moves the backstop on" tests red.
//   - the aim rule removed (onScrollend always rests): the "stale scrollend" test red
//     (it rests before the new scroll's first frame).
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/carousel.js", import.meta.url), "utf8")
const { watchRest, SETTLE_MS, REST_CAP_MS } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

// A clock the test moves by hand: no real waits.
function fakeTimers() {
  let now = 0
  let next = 1
  const due = new Map()
  return {
    setTimeout(fn, ms) { const id = next++; due.set(id, { at: now + ms, fn }); return id },
    clearTimeout(id) { due.delete(id) },
    advance(ms) {
      const until = now + ms
      for (;;) {
        const [id, timer] = [...due].filter(([, t]) => t.at <= until).sort((a, b) => a[1].at - b[1].at)[0] || []
        if (!timer) break
        due.delete(id)
        now = timer.at
        timer.fn()
      }
      now = until
    },
    get pending() { return due.size }
  }
}

function watched({ scrollend }) {
  const track = new EventTarget()
  const timers = fakeTimers()
  const rests = []
  const watch = watchRest(track, () => rests.push(timers), { scrollend, timers })
  const fire = (type) => track.dispatchEvent(new Event(type))
  return { track, timers, rests, watch, fire }
}

test("the backstop is three quiet spells, above a slow 8x-CPU frame", () => {
  assert.equal(SETTLE_MS, 150)
  assert.equal(REST_CAP_MS, SETTLE_MS * 3)
  assert.ok(REST_CAP_MS > 260)
})

test("with scrollend, scrollend rests the row at once", () => {
  const { rests, fire, timers } = watched({ scrollend: true })
  fire("scroll")
  fire("scroll")
  assert.equal(rests.length, 0)
  fire("scrollend")
  assert.equal(rests.length, 1)
  timers.advance(REST_CAP_MS * 2)
  assert.equal(rests.length, 1, "the backstop after scrollend finds nothing to end")
})

test("with scrollend, one scroll event and no scrollend still rests within the cap", () => {
  // Chrome, a page that shortens: the browser pulls the scroll back with one scroll
  // event and sends no scrollend.
  const { rests, fire, timers } = watched({ scrollend: true })
  fire("scroll")
  timers.advance(REST_CAP_MS - 1)
  assert.equal(rests.length, 0, "a slow frame is not a rest")
  timers.advance(1)
  assert.equal(rests.length, 1)
  fire("scrollend")
  assert.equal(rests.length, 1, "a late scrollend rests nothing twice")
})

test("with scrollend, each scroll event moves the backstop on", () => {
  const { rests, fire, timers } = watched({ scrollend: true })
  for (let i = 0; i < 5; i += 1) {
    fire("scroll")
    timers.advance(REST_CAP_MS - 10)
  }
  assert.equal(rests.length, 0, "a glide whose frames keep coming has not rested")
  timers.advance(10)
  assert.equal(rests.length, 1)
})

test("after an aim, a stale scrollend before the new scroll's first frame rests nothing", () => {
  const { rests, fire, watch } = watched({ scrollend: true })
  fire("scroll")
  watch.aimed()
  fire("scrollend")
  assert.equal(rests.length, 0, "the replaced scroll's end is not this aim's")
  fire("scroll")
  fire("scrollend")
  assert.equal(rests.length, 1)
})

test("without scrollend, a quiet spell rests the row", () => {
  const { track, rests, fire, timers } = watched({ scrollend: false })
  fire("scroll")
  timers.advance(SETTLE_MS - 1)
  fire("scroll")
  timers.advance(SETTLE_MS - 1)
  assert.equal(rests.length, 0)
  timers.advance(1)
  assert.equal(rests.length, 1)
  // A scrollend this browser never sends is not listened for.
  fire("scroll")
  track.dispatchEvent(new Event("scrollend"))
  assert.equal(rests.length, 1)
})

test("stop removes the listeners and the timer", () => {
  const { rests, fire, timers, watch } = watched({ scrollend: true })
  fire("scroll")
  watch.stop()
  assert.equal(timers.pending, 0)
  fire("scroll")
  fire("scrollend")
  timers.advance(REST_CAP_MS * 2)
  assert.equal(rests.length, 0)
})
