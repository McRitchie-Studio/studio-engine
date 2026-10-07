// [unit] studio/head_chrome: the nav spinner's minimum display time and the
// success confetti's bursts. The theme is studio/alpine_stores
// (alpine_stores.test.mjs). Loaded from source as a
// data: module, like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/head_chrome.js", import.meta.url), "utf8")
const { spinnerHideDelay, spinnerMinMs, successBursts, SUCCESS_COLORS } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the spinner hides only after its minimum display time", () => {
  assert.equal(spinnerHideDelay(1000, 1100, 300), 200)
  assert.equal(spinnerHideDelay(1000, 1400, 300), 0)
  assert.equal(spinnerHideDelay(1000, 1000, 0), 0)
})

test("the minimum is read from the head's meta tag", () => {
  const doc = (content) => ({ querySelector: () => (content === undefined ? null : { getAttribute: () => content }) })
  assert.equal(spinnerMinMs(doc("300")), 300)
  assert.equal(spinnerMinMs(doc(undefined)), 0)
  assert.equal(spinnerMinMs(doc("nope")), 0)
})

test("the success confetti fires four bursts on the given palette", () => {
  const bursts = successBursts(["#000"])
  assert.deepEqual(bursts.map((b) => b[0]), [0, 150, 150, 400])
  for (const [, options] of bursts) assert.deepEqual(options.colors, ["#000"])
  assert.equal(bursts[0][1].particleCount, 150)
  assert.equal(SUCCESS_COLORS.length, 8)
})
