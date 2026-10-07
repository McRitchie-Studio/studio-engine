// [unit] studio/head_chrome: the theme toggle, the nav spinner's minimum
// display time, and the success confetti's bursts. Loaded from source as a
// data: module, like local_path.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/head_chrome.js", import.meta.url), "utf8")
const { storedTheme, toggleTheme, spinnerHideDelay, spinnerMinMs, successBursts, SUCCESS_COLORS } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const storage = (initial = {}) => {
  const values = { ...initial }
  return { values, getItem: (k) => (k in values ? values[k] : null), setItem: (k, v) => { values[k] = String(v) } }
}

const root = (classes) => {
  const set = new Set(classes)
  return {
    set,
    classList: {
      add: (c) => set.add(c),
      remove: (c) => set.delete(c),
      contains: (c) => set.has(c),
      toggle: (c) => (set.has(c) ? (set.delete(c), false) : (set.add(c), true))
    }
  }
}

test("the stored theme is dark unless the reader chose light", () => {
  assert.equal(storedTheme(storage()), "dark")
  assert.equal(storedTheme(storage({ theme: "light" })), "light")
})

test("toggling flips the root, stores the result, and clears the transition later", () => {
  const html = root(["dark"])
  const store = storage({ theme: "dark" })
  const later = []
  assert.equal(toggleTheme(html, store, (fn, ms) => later.push([fn, ms])), "light")
  assert.equal(html.set.has("dark"), false)
  assert.equal(store.values.theme, "light")
  assert.equal(html.set.has("theme-transition"), true, "the transition class is on while the colours move")
  assert.equal(later[0][1], 300)
  later[0][0]()
  assert.equal(html.set.has("theme-transition"), false)

  assert.equal(toggleTheme(html, store, () => {}), "dark")
  assert.equal(store.values.theme, "dark")
})

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
