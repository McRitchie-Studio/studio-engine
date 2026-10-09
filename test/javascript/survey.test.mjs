// [unit] studio/survey: what counts as an answer, where the stepper opens, and
// that a root is bound once. The flow itself (autosave, keys, Back and Next) is
// e2e/survey_flow.spec.js. Loaded from source as a data: module, like
// nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/survey.js", import.meta.url), "utf8")
const {
  typeOf, isChoice, isMulti, valueOf, answered, progressWidth, startIndex, enhanceSurvey
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing, and marks no bound root in the DOM", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
  assert.match(source, /^var bound = new WeakSet\(\);$/m,
               "a DOM marker would survive Turbo's snapshot clone, which carries no listeners")
})

// A step: its type, its option inputs and, for a text question, its field.
function step({ type = "", options = [], text, key = "q", required = false, active = false } = {}) {
  const classes = new Set(active ? ["is-active"] : [])
  return {
    dataset: { type, key, required: String(required) },
    hidden: false,
    classList: {
      contains: (name) => classes.has(name),
      toggle(name, on) { if (on) classes.add(name); else classes.delete(name) }
    },
    querySelectorAll: (selector) => (selector === "input.studio-survey__input" ? options : []),
    querySelector(selector) {
      if (selector === "[data-survey-text]") return text === undefined ? null : { value: text }
      return null
    }
  }
}
const option = (value, checked = false) => ({ value, checked })

test("the three choice types are single answers, multi_choice is many, anything else is text", () => {
  for (const type of ["emoji_scale", "rating", "choice"]) {
    assert.equal(isChoice(step({ type })), true, type)
    assert.equal(isMulti(step({ type })), false, type)
  }
  assert.equal(isMulti(step({ type: "multi_choice" })), true)
  assert.equal(isChoice(step({ type: "multi_choice" })), false)
  assert.equal(isChoice(step({ type: "long_text" })), false)
  assert.equal(typeOf({ dataset: {} }), "")
})

test("a choice answers its checked value, or blank", () => {
  assert.equal(valueOf(step({ type: "rating", options: [option("1"), option("4", true)] })), "4")
  assert.equal(valueOf(step({ type: "rating", options: [option("1"), option("4")] })), "")
})

test("a multi-choice answers every checked value, in order", () => {
  assert.deepEqual(valueOf(step({ type: "multi_choice", options: [option("a", true), option("b"), option("c", true)] })), ["a", "c"])
  assert.deepEqual(valueOf(step({ type: "multi_choice", options: [option("a")] })), [])
})

test("a text question answers its trimmed text, and blank when it has no field", () => {
  assert.equal(valueOf(step({ type: "long_text", text: "  fine  " })), "fine")
  assert.equal(valueOf(step({ type: "long_text" })), "")
})

test("answered: whitespace and an empty selection are not answers", () => {
  assert.equal(answered(step({ type: "long_text", text: "   " })), false)
  assert.equal(answered(step({ type: "long_text", text: "x" })), true)
  assert.equal(answered(step({ type: "multi_choice", options: [option("a")] })), false)
  assert.equal(answered(step({ type: "multi_choice", options: [option("a", true)] })), true)
  assert.equal(answered(step({ type: "choice", options: [option("a", true)] })), true)
})

test("the progress bar fills by question, and a survey with no question fills nothing", () => {
  assert.equal(progressWidth(1, 4), "25%")
  assert.equal(progressWidth(4, 4), "100%")
  assert.equal(progressWidth(1, 0), "0%")
})

test("the stepper opens on question 1, the resume point, or the restored step", () => {
  assert.equal(startIndex("", 5, -1), 0, "a fresh visitor")
  assert.equal(startIndex(undefined, 5, -1), 0)
  assert.equal(startIndex("3", 5, -1), 3, "a returning visitor's next question")
  assert.equal(startIndex("9", 5, -1), 0, "a resume point past the end")
  assert.equal(startIndex("-1", 5, -1), 0)
  assert.equal(startIndex("junk", 5, -1), 0)
  assert.equal(startIndex("3", 5, 1), 1, "a page restored from Turbo's cache comes back where it was left")
})

// A whole survey root, as far as binding and the first render read it.
function surveyRoot({ steps, resume = "", enhanced = false, hasErrors = false }) {
  const classes = new Set(enhanced ? ["is-enhanced"] : [])
  const part = () => ({
    hidden: true, style: {}, attrs: {}, listeners: {},
    classList: { toggle() {} },
    setAttribute(name, value) { this.attrs[name] = value },
    addEventListener(name, fn) { this.listeners[name] = fn }
  })
  const parts = {
    "[data-survey-form]": part(), "[data-survey-head]": part(), "[data-survey-back]": part(),
    "[data-survey-next]": part(), "[data-survey-submit]": part(), "[data-survey-top]": part(),
    "[data-survey-progress]": part(), "[data-survey-progress-fill]": part(), "[data-survey-count]": part(),
    "[data-survey-status]": part(), "[data-survey-hint]": part()
  }
  return {
    parts, classes, listeners: {},
    isConnected: true,
    dataset: { resumeIndex: resume, hasErrors: String(hasErrors), csrf: "token", answerBase: "/surveys/s/answers/" },
    classList: { contains: (name) => classes.has(name), add: (name) => classes.add(name) },
    querySelector: (selector) => parts[selector] || null,
    querySelectorAll: (selector) => (selector === "[data-survey-step]" ? steps : []),
    addEventListener(name, fn) { this.listeners[name] = fn }
  }
}

const fakeWindow = () => ({ matchMedia: () => ({ matches: true }), scrollTo() {}, setTimeout, clearTimeout })
const fakeDocument = () => ({ listeners: {}, addEventListener(name, fn) { this.listeners[name] = fn }, removeEventListener() {} })

test("enhance shows one question, marks the root, and binds it once", () => {
  const steps = [step({ type: "rating", options: [option("1")] }), step({ type: "long_text", text: "" })]
  const root = surveyRoot({ steps })
  const doc = fakeDocument()

  assert.equal(enhanceSurvey(root, fakeWindow(), doc), true)

  assert.equal(root.classes.has("is-enhanced"), true)
  assert.deepEqual(steps.map((s) => s.hidden), [false, true])
  assert.equal(root.parts["[data-survey-back]"].hidden, true, "nothing comes before question 1")
  assert.equal(root.parts["[data-survey-next]"].hidden, false)
  assert.equal(root.parts["[data-survey-submit]"].hidden, true)
  assert.equal(root.parts["[data-survey-count]"].textContent, "Question 1 of 2")
  assert.equal(root.parts["[data-survey-progress-fill]"].style.width, "50%")
  assert.equal(root.parts["[data-survey-hint]"].hidden, false, "a scale takes number keys")
  assert.equal(root.parts["[data-survey-form]"].noValidate, true)

  const first = root.listeners.keydown
  assert.equal(enhanceSurvey(root, fakeWindow(), doc), false)
  assert.equal(root.listeners.keydown, first, "a second connect adds no second listener")
})

test("enhance resumes a returning visitor on their next question and says so", () => {
  const steps = [step(), step(), step({ type: "long_text", text: "" })]
  const root = surveyRoot({ steps, resume: "2" })

  enhanceSurvey(root, fakeWindow(), fakeDocument())

  assert.deepEqual(steps.map((s) => s.hidden), [true, true, false])
  assert.equal(root.parts["[data-survey-submit]"].hidden, false, "the last question offers Submit")
  assert.equal(root.parts["[data-survey-next]"].hidden, true)
  assert.equal(root.parts["[data-survey-status]"].textContent, "Welcome back — picking up where you left off.")
})

test("enhance on a page restored from Turbo's cache stays on the step it was left on", () => {
  const steps = [step(), step({ active: true }), step()]
  const root = surveyRoot({ steps, resume: "0", enhanced: true })

  enhanceSurvey(root, fakeWindow(), fakeDocument())

  assert.deepEqual(steps.map((s) => s.hidden), [true, false, true])
  assert.equal(root.parts["[data-survey-status]"].textContent, undefined, "a restore is not a return visit")
})
