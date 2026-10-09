// [unit] studio/booking: asking Google once, which clicks the popup takes, and
// what each install wires. Loaded from source as a data: module, like
// nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/booking.js", import.meta.url), "utf8")
const {
  FRAME, WAITING_FRAMES, WRAP, SHUT_WRAP, POPUP_LINK, DIALOG, POPUP_FRAME,
  loadBookingFrame, plainClick, armBookingFrames, installBookingFrames, installBookingPopup,
  handleBookingLinkClick, resetBookingDialog
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("every selector names the engine's own elements", () => {
  for (const selector of [FRAME, WAITING_FRAMES, WRAP, SHUT_WRAP, POPUP_LINK, DIALOG]) {
    assert.match(selector, /\[data-studio-booking\]/, `${selector} would match an app's local booking markup`)
  }
})

const iframe = (attrs = {}) => ({
  attrs: { ...attrs },
  dataset: { src: "https://calendar.example/embed" },
  assigned: 0,
  getAttribute(name) { return this.attrs[name] === undefined ? null : this.attrs[name] },
  removeAttribute(name) { delete this.attrs[name] },
  set src(value) { this.attrs.src = value; this.assigned++ },
  get src() { return this.attrs.src }
})

test("a frame is asked for once: a second load finds the src set", () => {
  const frame = iframe()
  loadBookingFrame(frame)
  loadBookingFrame(frame)
  assert.equal(frame.attrs.src, "https://calendar.example/embed")
  assert.equal(frame.assigned, 1)
})

const click = (over = {}) => ({
  defaultPrevented: false, button: 0, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false,
  prevented: 0,
  preventDefault() { this.prevented++ },
  ...over
})

test("only a plain primary click is taken", () => {
  assert.equal(plainClick(click()), true)
  for (const modified of [{ metaKey: true }, { ctrlKey: true }, { shiftKey: true }, { altKey: true }, { button: 1 }, { defaultPrevented: true }]) {
    assert.equal(plainClick(click(modified)), false, JSON.stringify(modified))
  }
})

// A window that records listeners and timers, and a document that answers the
// selectors the module asks.
function fakeWindow(extra = {}) {
  const listeners = {}
  return {
    listeners,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    fire(name, event = {}) { (listeners[name] || []).forEach((fn) => fn(event)) },
    setInterval: () => 1,
    clearInterval: () => {},
    ...extra
  }
}

function fakeDocument(found = {}, readyState = "complete") {
  const listeners = {}
  return {
    listeners, readyState, found,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    fire(name, event = {}) { (listeners[name] || []).forEach((fn) => fn(event)) },
    querySelector(selector) { const hit = found[selector]; return Array.isArray(hit) ? hit[0] || null : hit || null },
    querySelectorAll(selector) { const hit = found[selector]; return Array.isArray(hit) ? hit : hit ? [hit] : [] }
  }
}

class Watcher {
  static all = []
  constructor(callback, options) { this.callback = callback; this.options = options; this.live = true; Watcher.all.push(this) }
  observe(target) { this.target = target }
  disconnect() { this.live = false }
}

test("arm: a frame loads only once it nears the viewport, and is watched once", () => {
  Watcher.all = []
  const frame = iframe()
  const win = fakeWindow({ IntersectionObserver: Watcher })
  const doc = fakeDocument({ [WAITING_FRAMES]: [frame] })

  armBookingFrames(win, doc)
  armBookingFrames(win, doc)
  assert.equal(Watcher.all.length, 1, "a second arm adds no second observer")
  assert.equal(Watcher.all[0].options.rootMargin, "200px")
  assert.equal(frame.assigned, 0, "nothing is asked of Google while the frame is far away")

  Watcher.all[0].callback([{ isIntersecting: false }])
  assert.equal(frame.assigned, 0)
  Watcher.all[0].callback([{ isIntersecting: true }])
  assert.equal(frame.assigned, 1)
  assert.equal(Watcher.all[0].live, false, "the observer is dropped once it has fired")
})

test("arm: with no IntersectionObserver the frame loads at once", () => {
  const frame = iframe()
  armBookingFrames(fakeWindow(), fakeDocument({ [WAITING_FRAMES]: [frame] }))
  assert.equal(frame.assigned, 1)
})

test("install frames: once per document, publishing the loader, and nothing before `load`", () => {
  Watcher.all = []
  const frame = iframe()
  const win = fakeWindow({ IntersectionObserver: Watcher })
  const doc = fakeDocument({ [WAITING_FRAMES]: [frame] }, "interactive")

  assert.equal(installBookingFrames(win, doc), true)
  assert.equal(installBookingFrames(win, doc), false)
  assert.equal(win.__studioBookingFramesArmed, true)
  assert.equal(win.__studioBookingLoad, loadBookingFrame)
  assert.equal(win.listeners.blur.length, 1, "the second install added no second listener")
  assert.equal(Watcher.all.length, 0, "the frame is not watched before the window has loaded")

  doc.readyState = "complete"
  win.fire("load")
  assert.equal(Watcher.all.length, 1)
})

test("install frames: a Turbo visit arms the frames of the new body", () => {
  Watcher.all = []
  const win = fakeWindow({ IntersectionObserver: Watcher })
  const doc = fakeDocument({ [WAITING_FRAMES]: [] })
  installBookingFrames(win, doc)

  doc.found[WAITING_FRAMES] = [iframe()]
  doc.fire("turbo:load")
  assert.equal(Watcher.all.length, 1)
})

test("install frames: focus moving into a cropped frame opens its wrapper", () => {
  const wrap = { classes: [], classList: { add(name) { wrap.classes.push(name) } } }
  const active = { tagName: "IFRAME", matches: (selector) => selector === FRAME, closest: (selector) => (selector === WRAP ? wrap : null) }
  const win = fakeWindow()
  const doc = fakeDocument({})
  doc.activeElement = active
  installBookingFrames(win, doc)

  win.fire("blur")
  assert.deepEqual(wrap.classes, ["is-open"])
})

// A page for the link handler: an optional inline frame and an optional dialog.
function bookingPage({ inline = null, dialog = null, readyState = "complete" } = {}) {
  return fakeDocument({ [FRAME]: inline, [DIALOG]: dialog }, readyState)
}

const linkTarget = { closest: (selector) => (selector === POPUP_LINK ? {} : null) }

function fakeDialog({ open = false, modal = true } = {}) {
  const frame = iframe()
  const dialog = {
    open, frame, shown: 0, closed: 0,
    querySelector: (selector) => (selector === POPUP_FRAME ? frame : null),
    close() { this.open = false; this.closed++ }
  }
  if (modal) dialog.showModal = function () { this.open = true; this.shown++ }
  return dialog
}

test("a click that is not on a booking link, or is modified, is left to the browser", () => {
  const doc = bookingPage({ dialog: fakeDialog() })
  const elsewhere = click({ target: { closest: () => null } })
  const newTab = click({ target: linkTarget, metaKey: true })

  assert.equal(handleBookingLinkClick(elsewhere, fakeWindow(), doc), null)
  assert.equal(handleBookingLinkClick(newTab, fakeWindow(), doc), null)
  assert.equal(elsewhere.prevented + newTab.prevented, 0)
})

test("a booking link opens the dialog and asks for its frame once", () => {
  const dialog = fakeDialog()
  const doc = bookingPage({ dialog })
  const win = fakeWindow()

  const first = click({ target: linkTarget })
  assert.equal(handleBookingLinkClick(first, win, doc), "dialog")
  assert.equal(first.prevented, 1)
  assert.equal(dialog.shown, 1)
  assert.equal(dialog.frame.assigned, 1)

  handleBookingLinkClick(click({ target: linkTarget }), win, doc)
  assert.equal(dialog.shown, 1, "an open dialog is not shown again")
  assert.equal(dialog.frame.assigned, 1, "and Google is not asked twice")
})

test("with no dialog, or no <dialog> support, the link keeps its own href", () => {
  const event = click({ target: linkTarget })
  assert.equal(handleBookingLinkClick(event, fakeWindow(), bookingPage()), null)
  assert.equal(handleBookingLinkClick(event, fakeWindow(), bookingPage({ dialog: fakeDialog({ modal: false }) })), null)
  assert.equal(event.prevented, 0)
})

test("on a page with the inline frame the link goes to that frame, not a popup", () => {
  const wrap = { classes: [], scrolled: [], classList: { add(name) { wrap.classes.push(name) } }, scrollIntoView(options) { this.scrolled.push(options) } }
  const inline = Object.assign(iframe(), { focused: [], closest: (selector) => (selector === WRAP ? wrap : null), focus(options) { this.focused.push(options) } })
  const dialog = fakeDialog()
  const win = fakeWindow({ __studioBookingLoad: loadBookingFrame, matchMedia: () => ({ matches: false }) })
  const event = click({ target: linkTarget })

  assert.equal(handleBookingLinkClick(event, win, bookingPage({ inline, dialog })), "frame")

  assert.equal(event.prevented, 1)
  assert.deepEqual(wrap.classes, ["is-open"])
  assert.equal(inline.assigned, 1, "after `load` the link loads the frame itself")
  assert.deepEqual(wrap.scrolled, [{ behavior: "smooth", block: "start" }])
  assert.deepEqual(inline.focused, [{ preventScroll: true }])
  assert.equal(dialog.shown, 0)
})

test("before `load` the link leaves the frame waiting, and reduced motion scrolls without animation", () => {
  const inline = Object.assign(iframe(), { scrolled: [], closest: () => null, focus() {}, scrollIntoView(options) { this.scrolled.push(options) } })
  const win = fakeWindow({ __studioBookingLoad: loadBookingFrame, matchMedia: () => ({ matches: true }) })

  handleBookingLinkClick(click({ target: linkTarget }), win, bookingPage({ inline, readyState: "interactive" }))

  assert.equal(inline.assigned, 0)
  assert.deepEqual(inline.scrolled, [{ behavior: "auto", block: "start" }], "with no wrapper the frame itself is scrolled to")
})

test("install popup: once per document; a backdrop click closes; a snapshot never keeps it open or loaded", () => {
  const dialog = fakeDialog({ open: true })
  dialog.frame.attrs.src = "https://calendar.example/embed"
  const doc = bookingPage({ dialog })
  const win = fakeWindow()

  assert.equal(installBookingPopup(win, doc), true)
  assert.equal(installBookingPopup(win, doc), false)
  assert.equal(doc.listeners.click.length, 2)

  const backdrop = { matches: (selector) => selector === DIALOG, closed: 0, close() { this.closed++ } }
  doc.fire("click", click({ target: backdrop }))
  assert.equal(backdrop.closed, 1)

  doc.fire("turbo:before-cache")
  assert.equal(dialog.open, false)
  assert.equal(dialog.frame.attrs.src, undefined, "the src goes back to waiting in data-src")

  assert.doesNotThrow(() => resetBookingDialog(bookingPage()))
})
