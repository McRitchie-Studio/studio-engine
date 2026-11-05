// [unit] studio/microphone_chip against a stub DOM: the picker's keyboard and
// ARIA contract. Esc in the open list closes it and hands focus back to the
// chip (a keyboard user is never left on an option that vanished); Esc with
// the list shut leaves focus alone; options mark the one in use with
// aria-current and carry no aria-pressed (picking is not a toggle). Loaded
// with its studio/ imports inlined (support/studio_module.mjs). The browser
// lane (e2e/voice_capture.spec.js) drives the same keys in Chromium.
//
// CONTROLS, run against this file:
//   - drop `if (chip) chip.focus()` from onKey: "Esc in the open list" fails.
//   - delete onDialogKey's listeners: "a key already down" fails.
//   - put `button.setAttribute("aria-pressed", ...)` back in renderList: "no
//     aria-pressed" fails.
import { test } from "node:test"
import assert from "node:assert/strict"
import { loadStudioModule } from "./support/studio_module.mjs"

const { mountMicrophoneChip } = await loadStudioModule("studio/microphone_chip")

class El {
  constructor(doc, tag, attrs = {}, children = []) {
    this.doc = doc
    this.tag = tag
    this.attrs = { ...attrs }
    this.children = []
    this.dataset = {}
    this.textContent = ""
    this.hidden = "hidden" in attrs
    this.listeners = {}
    this.style = { setProperty() {} }
    this.isConnected = true
    this.offsetParent = {}
    this.append(...children)
  }
  get ownerDocument() { return this.doc }
  append(...kids) { kids.forEach((kid) => { kid.parent = this; this.children.push(kid) }) }
  replaceChildren(...kids) { this.children = []; this.append(...kids) }
  setAttribute(name, value) { this.attrs[name] = String(value) }
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null }
  hasAttribute(name) { return name in this.attrs }
  removeAttribute(name) { delete this.attrs[name] }
  all() { return this.children.flatMap((child) => [child, ...child.all()]) }
  matches(selector) {
    const name = selector.replace(/^\[|\]$/g, "").split("=")[0]
    return name in this.attrs || (name === "data-microphone-option" && this.dataset.microphoneOption !== undefined)
  }
  querySelector(selector) { return this.all().find((el) => el.matches(selector)) || null }
  querySelectorAll(selector) { return this.all().filter((el) => el.matches(selector)) }
  contains(el) { return el === this || this.all().includes(el) }
  closest(selector) {
    let el = this
    while (el) { if (el.matches && el.matches(selector)) return el; el = el.parent }
    return null
  }
  focus() { this.doc.activeElement = this }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn) }
  removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] || []).filter((f) => f !== fn) }
  fire(type, target, extra = {}) {
    const event = { type, target, preventDefault() {}, ...extra };
    (this.listeners[type] || []).forEach((fn) => fn(event))
  }
}

const MICS = [
  { kind: "audioinput", deviceId: "default", label: "Default - MacBook Pro Microphone (Built-in)" },
  { kind: "audioinput", deviceId: "mbp", label: "MacBook Pro Microphone (Built-in)" },
  { kind: "audioinput", deviceId: "arctis", label: "Arctis Nova Pro Wireless (1038:12e0)" }
]

function build() {
  const doc = { activeElement: null }
  doc.createElement = (tag) => new El(doc, tag)
  const chip = new El(doc, "button", { "data-microphone-chip": "", "aria-expanded": "false" })
  const list = new El(doc, "ul", { "data-microphone-list": "" })
  const helpLink = new El(doc, "button", { "data-microphone-help-link": "" })
  const panel = new El(doc, "div", { "data-microphone-panel": "", hidden: "" },
    [new El(doc, "p", { "data-microphone-note": "" }), list, helpLink])
  const root = new El(doc, "div", { "data-microphone-copy": "{}" },
    [chip, new El(doc, "span", { "data-microphone-label": "" }), panel])
  const win = {
    navigator: { userAgent: "Chrome/130", mediaDevices: { enumerateDevices: async () => MICS } },
    addEventListener() {}, removeEventListener() {}, dispatchEvent() { return true }
  }
  return { doc, root, chip, panel, list, win }
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

async function openList() {
  const page = build()
  mountMicrophoneChip(page.root, { win: page.win })
  await flush()
  page.root.fire("click", page.chip)
  await flush()
  return page
}

test("Esc in the open list closes it and returns focus to the chip", async () => {
  const page = await openList()
  assert.equal(page.panel.hidden, false)
  const option = page.list.all().find((el) => el.dataset.microphoneOption === "arctis")
  option.focus()

  let stopped = 0
  page.root.fire("keydown", option, { key: "Escape", stopPropagation() { stopped += 1 } })

  assert.equal(stopped, 1, "a modal around the chip keeps its own Esc")
  assert.equal(page.panel.hidden, true)
  assert.equal(page.chip.getAttribute("aria-expanded"), "false")
  assert.equal(page.doc.activeElement, page.chip, "focus is back on the chip")
})

test("Esc with the list shut leaves focus where it is; other keys do nothing", async () => {
  const page = build()
  mountMicrophoneChip(page.root, { win: page.win })
  await flush()
  const elsewhere = new El(page.doc, "input")
  elsewhere.focus()
  page.root.fire("keydown", elsewhere, { key: "Escape" })
  assert.equal(page.doc.activeElement, elsewhere)

  page.root.fire("click", page.chip)
  await flush()
  page.root.fire("keydown", page.chip, { key: "Enter" })
  assert.equal(page.panel.hidden, false)
})

test("options mark the one in use with aria-current and carry no aria-pressed", async () => {
  const page = await openList()
  const options = page.list.all().filter((el) => el.dataset.microphoneOption !== undefined)
  assert.deepEqual(options.map((el) => el.dataset.microphoneOption), ["mbp", "arctis"])
  options.forEach((el) => assert.equal(el.hasAttribute("aria-pressed"), false, `${el.dataset.microphoneOption} has aria-pressed`))
  assert.deepEqual(options.map((el) => el.getAttribute("aria-current")), ["true", null])
})

test("a key already down when the help opens does not press Close; a new press does", async () => {
  const page = build()
  const close = new El(page.doc, "button", { "data-microphone-help-close": "" })
  const dialog = new El(page.doc, "dialog", { "data-microphone-dialog": "" }, [close])
  dialog.showModal = () => { dialog.open = true }
  dialog.close = () => { dialog.open = false }
  page.root.append(dialog)
  const handlers = {}
  page.win.addEventListener = (name, fn) => { handlers[name] = fn }
  mountMicrophoneChip(page.root, { win: page.win })
  await flush()
  handlers["studio:microphone:denied"]({})
  assert.equal(dialog.open, true)

  const fire = (type, key, repeat) => {
    let stopped = false
    dialog.fire(type, close, { key, repeat, preventDefault() { stopped = true } })
    return stopped
  }
  for (const key of [" ", "Enter"]) {
    assert.equal(fire("keydown", key, true), true, "a repeat presses nothing")
    assert.equal(fire("keyup", key, false), true, "nor does the keyup of the hold")
    assert.equal(fire("keydown", key, false), false, "a new press is a person answering")
    assert.equal(fire("keyup", key, false), false)
  }
  assert.equal(fire("keydown", "Escape", true), false, "Esc is not one of these keys")
})

test("the help's Close shuts the dialog itself: it is a plain button, with no form to submit", async () => {
  const page = build()
  const close = new El(page.doc, "button", { "data-microphone-help-close": "" })
  const dialog = new El(page.doc, "dialog", { "data-microphone-dialog": "" }, [close])
  let closed = 0
  dialog.close = () => { closed += 1 }
  page.root.append(dialog)
  mountMicrophoneChip(page.root, { win: page.win })
  await flush()

  page.root.fire("click", close)
  assert.equal(closed, 1)
  page.root.fire("click", page.chip)
  assert.equal(closed, 1, "another click is not Close")
})
