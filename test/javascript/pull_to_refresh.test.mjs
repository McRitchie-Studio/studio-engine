// [unit] studio/pull_to_refresh: how far a finger has pulled, when a release
// refreshes, and that the pull arms only on a phone with touch.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/pull_to_refresh.js", import.meta.url), "utf8")
const { pullProgress, shouldRefresh, phoneTouch, watchPullToRefresh, THRESHOLD_PX, PHONE_QUERY } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the first half of the pull follows the finger, and past it the pull resists", () => {
  assert.equal(pullProgress(0), 0)
  assert.equal(pullProgress(-20), 0)
  assert.equal(pullProgress(THRESHOLD_PX / 2), 0.5)
  const past = pullProgress(THRESHOLD_PX)
  assert.ok(past > 0.5 && past < 1, "a full threshold of finger is not yet a refresh")
  assert.equal(pullProgress(10000), 1.2)
})

test("a release refreshes only once the eased pull reaches the threshold", () => {
  assert.equal(shouldRefresh(pullProgress(THRESHOLD_PX)), false)
  assert.equal(shouldRefresh(pullProgress(THRESHOLD_PX * 2)), true)
})

test("it arms on a phone with touch and nowhere else", () => {
  const win = (match) => ({ matchMedia: (q) => ({ matches: q === PHONE_QUERY && match }) })
  assert.equal(phoneTouch(win(true)), true)
  assert.equal(phoneTouch(win(false)), false)
  assert.equal(phoneTouch({}), false)
  assert.equal(watchPullToRefresh({}, win(false), {}), null, "a desktop gets no listeners at all")
})
