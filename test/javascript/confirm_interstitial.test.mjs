// [unit] studio/confirm_interstitial: the sign-in page posts its form once.
// Loaded from source as a data: module, like profile_form.test.mjs; the module
// imports nothing, which is what lets a page with no import map load it.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/confirm_interstitial.js", import.meta.url), "utf8")
const { FORM_ID, FALLBACK_ID, SHOWN_CLASS, FALLBACK_AFTER_MS, autoSubmit, revealFallbackLater } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

const fakeForm = (extra = {}) => ({
  dataset: {},
  requested: 0,
  submitted: 0,
  requestSubmit() { this.requested += 1 },
  submit() { this.submitted += 1 },
  ...extra
})

test("the module imports nothing and touches no document when there is none", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
  assert.equal(FORM_ID, "magic-consume-form")
})

test("the form is submitted through requestSubmit, and stamped", () => {
  const form = fakeForm()
  assert.equal(autoSubmit(form), true)
  assert.equal(form.requested, 1)
  assert.equal(form.submitted, 0)
  assert.equal(form.dataset.autoSubmitted, "1")
})

test("a stamped form is not submitted again", () => {
  const form = fakeForm()
  autoSubmit(form)
  assert.equal(autoSubmit(form), false)
  assert.equal(form.requested, 1)
})

test("a browser with no requestSubmit falls back to submit", () => {
  const form = fakeForm({ requestSubmit: undefined })
  assert.equal(autoSubmit(form), true)
  assert.equal(form.submitted, 1)
})

test("a page with no form does nothing", () => {
  assert.equal(autoSubmit(null), false)
})

test("the fallback is shown by a timer four seconds in, as well as by the page's CSS", () => {
  const classes = new Set()
  const fallback = { classList: { add: (name) => classes.add(name) } }
  const timers = []
  revealFallbackLater(fallback, (fn, ms) => { timers.push({ fn, ms }); return 7 })

  assert.equal(FALLBACK_ID, "magic-fallback")
  assert.deepEqual(timers.map((timer) => timer.ms), [FALLBACK_AFTER_MS])
  assert.equal(FALLBACK_AFTER_MS, 4000)
  assert.equal(classes.size, 0, "nothing shows before the timer")
  timers[0].fn()
  assert.deepEqual([...classes], [SHOWN_CLASS])
})

test("a page with no fallback block sets no timer", () => {
  const timers = []
  assert.equal(revealFallbackLater(null, (fn, ms) => timers.push(ms)), null)
  assert.deepEqual(timers, [])
})
