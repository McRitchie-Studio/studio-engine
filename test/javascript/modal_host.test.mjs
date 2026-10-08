// [unit] studio/modal_host: the shared and scoped modal stores, the focus trap
// they share, the animation and card-width registries, the load hold, and the
// registration that reads each host's template. Loaded from source as a data:
// module, like alpine_stores.test.mjs; the module imports nothing, which is what
// lets the head load it when studio/application does not.
//
// These scenarios ran against the partials' extracted inline <script> until the
// store moved here (test/views/modal_host_store_behavior_test.rb); they now call
// the module the browser runs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/modal_host.js", import.meta.url), "utf8")
const {
  CLOSE_ANIM_MS, SWAP_IN_MS, ANIMATION_DEFAULTS, DEFAULT_CARD_WIDTH, MIN_LOAD_MS,
  mergeAnimations, modalAnim, modalCardWidth, holdAtLeast, installModalGlobals,
  createModalStore, createScopedModalStore, hostConfig, hostsIn, registerModalStore,
  registerHostsIn, clearStaleModals, installModalHost
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// A focusable node: focus() makes it the document's activeElement.
const node = (doc, name, extra = {}) => {
  const n = { name, tabIndex: 0, offsetParent: {}, focus() { doc.activeElement = n }, ...extra }
  return n
}

const fakeDocument = () => {
  const listeners = {}
  const classes = new Set()
  const attached = new Set()
  const doc = {
    listeners,
    classes,
    attached,
    activeElement: null,
    body: { classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) } },
    contains: (n) => attached.has(n),
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    fire(name, event = {}) { (listeners[name] || []).forEach((fn) => fn(event)) },
    querySelectorAll: () => []
  }
  return doc
}

// Alpine.store as Alpine has it: one argument reads, two register.
const fakeAlpine = () => {
  const stores = {}
  return {
    stores,
    version: "3.16.1",
    nextTick: (fn) => queueMicrotask(fn),
    store(name, value) {
      if (value === undefined) return stores[name]
      stores[name] = value
    }
  }
}

const fakeWindow = (extra = {}) => ({ setTimeout: (fn, ms) => setTimeout(fn, ms), ...extra })

const sharedStore = (win = fakeWindow()) => {
  const doc = fakeDocument()
  return { doc, win, store: createModalStore({ doc, win }) }
}

const scopedStore = (win = fakeWindow()) => {
  const doc = fakeDocument()
  return { doc, win, store: createScopedModalStore({ doc, win }) }
}

// A host element, as the partials render its template.
const hostElement = (attrs) => ({
  getAttribute: (name) => (name in attrs ? attrs[name] : null),
  matches: () => true
})

test("the module imports nothing, so its own module tag survives a failed boot", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

// ---- registries -----------------------------------------------------------

test("an app's animations merge over the engine defaults, per channel", () => {
  const merged = mergeAnimations({ enter: { wobble: { cls: "custom-wobble", ms: 90 } } })
  assert.deepEqual(merged.enter.wobble, { cls: "custom-wobble", ms: 90 })
  assert.deepEqual(Object.keys(merged.enter).sort(), ["pop", "shake", "slide", "wobble"])
  assert.deepEqual(Object.keys(merged.exit).sort(), ["pop", "slide"])
})

test("the registry durations are the keyframes' and the phase constants match them", () => {
  assert.equal(ANIMATION_DEFAULTS.enter.pop.ms, 320)
  assert.equal(ANIMATION_DEFAULTS.enter.shake.ms, 600)
  assert.equal(ANIMATION_DEFAULTS.exit.pop.ms, CLOSE_ANIM_MS)
  assert.equal(ANIMATION_DEFAULTS.exit.slide.ms, CLOSE_ANIM_MS)
  assert.equal(ANIMATION_DEFAULTS.enter.slide.ms, SWAP_IN_MS)
})

test("an unknown key or a gutted registry resolves to pop, never undefined", () => {
  assert.equal(modalAnim({ ModalAnimations: mergeAnimations() }, "enter", "nope").cls, "modal-card-mount")
  assert.equal(modalAnim({ ModalAnimations: {} }, "exit", "slide").cls, "modal-card-unmount")
  assert.equal(modalAnim({}, "enter", undefined).cls, "modal-card-mount")
})

test("a card width comes from CARD_WIDTHS by id, else the default, else the literal floor", () => {
  const win = { StudioModals: { CARD_WIDTHS: { wide: "max-w-md" }, DEFAULT_CARD_WIDTH: "max-w-xs" } }
  assert.equal(modalCardWidth(win, "wide"), "max-w-md")
  assert.equal(modalCardWidth(win, "other"), "max-w-xs")
  assert.equal(modalCardWidth({}, "other"), DEFAULT_CARD_WIDTH)
  assert.equal(DEFAULT_CARD_WIDTH, "max-w-sm")
})

test("the globals install over what the host defined first, and keep it", () => {
  const ownHold = () => {}
  const win = {
    ModalAnimations: { enter: { wobble: { cls: "custom-wobble", ms: 90 } } },
    StudioModals: { CARD_WIDTHS: { "wide-card": "max-w-md" }, holdAtLeast: ownHold }
  }
  installModalGlobals(win)
  assert.equal(win.ModalAnimations.enter.wobble.cls, "custom-wobble")
  assert.ok(win.ModalAnimations.enter.pop && win.ModalAnimations.exit.slide)
  assert.equal(win.StudioModals.CARD_WIDTHS["wide-card"], "max-w-md")
  assert.equal(win.StudioModals.DEFAULT_CARD_WIDTH, "max-w-sm")
  assert.equal(win.StudioModals.MIN_LOAD_MS, MIN_LOAD_MS)
  assert.equal(win.StudioModals.holdAtLeast, ownHold, "an app's own holdAtLeast is never clobbered")

  const bare = {}
  installModalGlobals(bare)
  assert.equal(typeof bare.StudioModals.holdAtLeast, "function")
  assert.equal(bare.StudioModals.MIN_LOAD_MS, 1400)
})

test("holdAtLeast fires at the floor for a fast operation and at once for a slow one", () => {
  let now = 1000
  const scheduled = []
  const clock = { now: () => now, later: (fn, ms) => scheduled.push(ms) }

  const fast = holdAtLeast(1400, clock)
  now += 300
  fast.then(() => assert.fail("a fast operation must wait for the floor"))
  assert.deepEqual(scheduled, [1100])

  const slow = holdAtLeast(1400, clock)
  now += 2000
  let ran = false
  slow.then(() => { ran = true })
  assert.equal(ran, true)
})

// ---- the shared store: cardClasses resolution, timing, races --------------

test("cardClasses resolves the registry, keeps the slide keys, and emits one width", async () => {
  const win = fakeWindow({
    ModalAnimations: mergeAnimations({ enter: { wobble: { cls: "custom-wobble", ms: 90 } } }),
    StudioModals: { CARD_WIDTHS: { "wide-card": "max-w-md" }, DEFAULT_CARD_WIDTH: "max-w-sm" }
  })
  const { store } = sharedStore(win)

  store.open("plain")
  assert.equal(store.cardClasses()["modal-card-mount"], true, "default mount class")
  assert.ok(!store.cardClasses()["modal-card-swap-in"], "no swap-in on a plain mount")
  store.closeAll()

  // enterAnim 'slide' names a fixed swap class; it must stay truthy.
  store.open("slide-in", { enterAnim: "slide" })
  assert.equal(store.cardClasses()["modal-card-swap-in"], true)
  store.closeAll()

  store.open("wob", { enterAnim: "wobble" })
  assert.equal(store.cardClasses()["custom-wobble"], true, "an app's registered animation resolves")
  store.closeAll()

  // exitAnim 'slide' through close(): the class binds while closing.
  store.open("slide-out", { exitAnim: "slide" })
  store.close()
  assert.equal(store.cardClasses()["modal-card-swap-out"], true)
  assert.ok(!store.cardClasses()["modal-card-unmount"], "the default exit class does not double up")
  assert.equal(store.stack.length, 1, "the entry stays on the stack while the exit plays")
  await sleep(320)
  assert.equal(store.stack.length, 0, "spliced after the exit duration")

  store.open("wide-card")
  assert.equal(store.cardClasses()["max-w-md"], true)
  assert.ok(!store.cardClasses()["max-w-sm"], "the default does not also land on a named id")
  store.closeAll()

  store.open("some-other-card")
  assert.equal(store.cardClasses()["max-w-sm"], true)
  store.closeAll()

  store.open("wide-card", { enterAnim: "shake" })
  const widths = Object.keys(store.cardClasses()).filter((k) => k.startsWith("max-w-"))
  assert.equal(widths.length, 1, `exactly one max-w-* key, got ${JSON.stringify(widths)}`)
  store.closeAll()
})

test("a default close animates, then splices", async () => {
  const { store, doc } = sharedStore()
  store.open("bye")
  assert.ok(doc.classes.has("modal-open"), "the scroll lock is on while a card is up")
  store.close()
  assert.equal(store.cardClasses()["modal-card-unmount"], true)
  await sleep(CLOSE_ANIM_MS + 100)
  assert.equal(store.stack.length, 0)
  assert.ok(!doc.classes.has("modal-open"), "and off once the stack empties")
})

test("two swaps inside the slide-out window leave one entry: the last", async () => {
  const { store } = sharedStore()
  store.open("A")
  store.swap("B")
  store.swap("C")
  await sleep(700)
  assert.equal(store.stack.length, 1)
  assert.equal(store.stack[0].id, "C")
})

test("a swap slides out, lands the new entry, then settles it", async () => {
  const { store } = sharedStore()
  store.open("first")
  store.swap("second", {}, { direction: "back" })
  assert.equal(store.cardClasses()["modal-card-swap-out-back"], true)
  await sleep(CLOSE_ANIM_MS + 40)
  assert.equal(store.current().id, "second")
  assert.equal(store.cardClasses()["modal-card-swap-in-back"], true)
  await sleep(SWAP_IN_MS + 40)
  assert.equal(store.current()._settled, true)
  assert.ok(!store.cardClasses()["modal-card-mount"], "a settled entry never re-fires the bounce")
})

test("advance patches props in place, keeping the entry", async () => {
  const { store } = sharedStore()
  store.open("wizard", { step: "one" })
  const entry = store.current()
  store.advance({ step: "two" })
  assert.equal(store.cardClasses()["modal-card-swap-out"], true)
  await sleep(CLOSE_ANIM_MS + 40)
  assert.equal(store.current(), entry, "the same entry, so its x-data scope survives")
  assert.equal(store.current().props.step, "two")
})

test("a double close inside the animation window pops one stacked entry", async () => {
  const { store } = sharedStore()
  store.open("base")
  store.open("top")
  store.close()
  store.close()
  await sleep(400)
  assert.equal(store.stack.length, 1)
  assert.equal(store.stack[0].id, "base")
})

test("a registry or StudioModals replaced late falls back and never throws", async () => {
  const win = fakeWindow({ ModalAnimations: mergeAnimations(), StudioModals: {} })
  const { store } = sharedStore(win)
  win.ModalAnimations = {}
  store.open("late")
  assert.equal(store.cardClasses()["modal-card-mount"], true)
  assert.equal(store.cardClasses()["max-w-sm"], true, "a gutted StudioModals still yields the literal width")
  assert.doesNotThrow(() => store.close())
  assert.equal(store.cardClasses()["modal-card-unmount"], true)
  await sleep(320)
  assert.equal(store.stack.length, 0)
})

test("closeAllDismissible keeps only dismissible: false cards", () => {
  const { store } = sharedStore()
  store.open("celebrate")
  store.open("pending-tx", { dismissible: false })
  store.closeAllDismissible()
  assert.deepEqual(store.stack.map((e) => e.id), ["pending-tx"])
})

// ---- isLive: the lifecycle matrix, on both stores --------------------------

for (const [label, make] of [["shared", sharedStore], ["scoped", scopedStore]]) {
  test(`isLive answers "up and not leaving" on the ${label} store`, async () => {
    const { store } = make()

    assert.equal(store.isLive("ghost"), false)
    assert.equal(store.isOpen("ghost"), false)

    store.open("plain")
    assert.equal(store.isLive("plain"), true)
    assert.equal(store.isLive("other"), false, "isLive matches on id")
    store.closeAll()

    // close() flips _closing synchronously and splices after the exit.
    store.open("leaving")
    store.close()
    assert.equal(store.current()._closing, true)
    assert.equal(store.isLive("leaving"), false, "a closing card is not live")
    assert.equal(store.isOpen("leaving"), true, "isOpen still reports a closing card")
    await sleep(400)
    assert.equal(store.isOpen("leaving"), false)

    // _swappingOut without _closing is an in-flow advance: still live.
    store.open("wizard")
    if (typeof store.advance === "function") store.advance({ step: "two" })
    else store.current()._swappingOut = true
    assert.ok(!store.current()._closing)
    assert.equal(store.isLive("wizard"), true, "a card mid-advance stays live")
    await sleep(500)
    store.closeAll()

    store.open("first")
    store.swap("second")
    if (store.current().id === "first") {
      assert.equal(store.isLive("first"), false, "the card being swapped away is not live")
      await sleep(600)
    }
    assert.equal(store.isLive("second"), true)
    assert.equal(store.isLive("first"), false)
    store.closeAll()

    store.open("step-a")
    assert.equal(store.isLive(["step-a", "step-b"]), true)
    assert.equal(store.isLive(["step-b", "step-c"]), false)
    store.close()
    assert.equal(store.isLive(["step-a", "step-b"]), false)
    await sleep(400)

    store.open("base")
    store.open("top")
    store.close()
    assert.equal(store.isLive("top"), false)
    assert.equal(store.isLive("base"), true, "the scan does not stop at the top entry")
    await sleep(400)
  })
}

test("the scoped store swaps in place and binds mount, then unmount", () => {
  const { store } = scopedStore()
  store.open("crop-photo")
  assert.equal(store.cardClasses(), "modal-card-mount")
  store.swap("saving")
  assert.deepEqual(store.stack.map((e) => e.id), ["saving"])
  store.close()
  assert.equal(store.cardClasses(), "modal-card-unmount")
  assert.equal(store.advance, undefined, "the scoped store ships no advance()")
})

// ---- the focus trap --------------------------------------------------------

for (const [label, make] of [["shared", sharedStore], ["scoped", scopedStore]]) {
  test(`the ${label} store captures focus on the backdrop and returns it to the opener`, async () => {
    const { store, doc } = make()
    const opener = node(doc, "opener")
    const backdrop = node(doc, "backdrop")
    doc.attached.add(opener).add(backdrop)
    opener.focus()

    store.open("card")
    store.captureFocus(backdrop)
    assert.equal(doc.activeElement, backdrop, "focus lands on the backdrop, not a button")

    store.close()
    await sleep(CLOSE_ANIM_MS + 40)
    assert.equal(doc.activeElement, opener, "focus returns to the opener when the last card leaves")
  })

  test(`the ${label} store refocuses the backdrop when a push re-mounts the content`, async () => {
    const win = fakeWindow({ Alpine: fakeAlpine() })
    const { store, doc } = make(win)
    const backdrop = node(doc, "backdrop")
    doc.attached.add(backdrop)

    store.open("first")
    store.captureFocus(backdrop)
    doc.activeElement = null // the inner template re-mounted and took focus with it
    store.open("second")
    await sleep(0)
    assert.equal(doc.activeElement, backdrop)
  })

  test(`the ${label} store never restores focus to a detached opener`, async () => {
    const { store, doc } = make()
    const opener = node(doc, "opener")
    const backdrop = node(doc, "backdrop")
    doc.attached.add(backdrop)
    opener.focus()
    store.open("card")
    store.captureFocus(backdrop)
    store.close()
    await sleep(CLOSE_ANIM_MS + 40)
    assert.equal(doc.activeElement, backdrop, "a detached opener is left alone")
  })
}

// The shared store's timed re-mount seams. Each lands after the slide or the
// exit, so focus is dropped once the push's own refocus has run and the seam
// has to put it back. advance() has no browser spec; this is its only pin.
for (const [seam, act] of [
  ["a swap", (store) => store.swap("second")],
  ["an advance", (store) => store.advance({ step: "two" })],
  ["a close down to the card beneath", (store) => { store.open("top"); store.close() }]
]) {
  test(`the shared store refocuses the backdrop after ${seam}`, async () => {
    const win = fakeWindow({ Alpine: fakeAlpine() })
    const { store, doc } = sharedStore(win)
    const backdrop = node(doc, "backdrop")
    doc.attached.add(backdrop)
    store.open("first")
    store.captureFocus(backdrop)
    act(store)
    await sleep(20)
    doc.activeElement = null // the inner template re-mounts and takes focus with it
    await sleep(CLOSE_ANIM_MS + 40)
    assert.equal(doc.activeElement, backdrop)
  })
}

test("cycleFocus wraps both ways and skips hidden or untabbable nodes", () => {
  const { store, doc } = sharedStore()
  const a = node(doc, "a")
  const hidden = node(doc, "hidden", { offsetParent: null })
  const untabbable = node(doc, "untabbable", { tabIndex: -1 })
  const b = node(doc, "b")
  const dialog = node(doc, "dialog", { querySelectorAll: () => [a, hidden, untabbable, b] })

  b.focus()
  store.cycleFocus(dialog, { shiftKey: false })
  assert.equal(doc.activeElement, a, "Tab from the last wraps to the first")
  store.cycleFocus(dialog, { shiftKey: true })
  assert.equal(doc.activeElement, b, "Shift+Tab from the first wraps to the last")

  const empty = node(doc, "empty", { querySelectorAll: () => [] })
  store.cycleFocus(empty, {})
  assert.equal(doc.activeElement, empty, "a dialog with no controls keeps focus on itself")
})

test("dialogLabel prefers ariaLabel, then a non-blank title, then the id", () => {
  const { store } = sharedStore()
  assert.equal(store.dialogLabel(), "Dialog")
  store.open("wallet-setup", { title: "   " })
  assert.equal(store.dialogLabel(), "wallet setup")
  store.closeAll()
  store.open("x", { title: "Confirm", ariaLabel: "Confirm entry" })
  assert.equal(store.dialogLabel(), "Confirm entry")
})

// ---- registration ---------------------------------------------------------

test("a host element declares its store, shared by default", () => {
  assert.deepEqual(hostConfig(hostElement({ "data-modal-host-store-value": "modals" })),
                   { store: "modals", scoped: false })
  assert.deepEqual(hostConfig(hostElement({ "data-modal-host-store-value": "labModals",
                                            "data-modal-host-scoped-value": "true" })),
                   { store: "labModals", scoped: true })
  assert.deepEqual(hostConfig(hostElement({ "data-modal-host-scoped-value": "false" })),
                   { store: "modals", scoped: false })
})

test("hostsIn reads the root and every host below it, and tolerates no root", () => {
  const inner = hostElement({ "data-modal-host-store-value": "pageModals", "data-modal-host-scoped-value": "true" })
  const root = { querySelectorAll: () => [inner] }
  assert.deepEqual(hostsIn(root), [{ store: "pageModals", scoped: true }])
  assert.deepEqual(hostsIn(null), [])
})

test("a store registers once, and a store Alpine already has wins", () => {
  const Alpine = fakeAlpine()
  const env = { doc: fakeDocument(), win: fakeWindow() }
  assert.equal(registerModalStore(Alpine, { store: "modals", scoped: false }, env), true)
  const first = Alpine.stores.modals
  assert.equal(registerModalStore(Alpine, { store: "modals", scoped: false }, env), false)
  assert.equal(Alpine.stores.modals, first)
  assert.equal(registerModalStore(undefined, { store: "modals" }, env), false, "no Alpine, no throw")

  registerModalStore(Alpine, { store: "pageModals", scoped: true }, env)
  assert.equal(typeof Alpine.stores.pageModals.advance, "undefined", "a scoped host gets the scoped store")
  assert.equal(typeof Alpine.stores.modals.advance, "function")
})

test("install registers on alpine:init and before a Turbo render, once per document", () => {
  const doc = fakeDocument()
  const Alpine = fakeAlpine()
  delete Alpine.version // Alpine loaded, not yet running
  const win = fakeWindow({ Alpine })
  doc.querySelectorAll = () => [hostElement({ "data-modal-host-store-value": "modals" })]

  installModalHost(doc, win)
  installModalHost(doc, win)
  assert.equal(doc.listeners["alpine:init"].length, 1, "one listener per document")
  assert.equal(Alpine.stores.modals, undefined, "nothing registers before alpine:init")
  assert.equal(typeof win.StudioModals.holdAtLeast, "function", "the globals install at once")

  doc.fire("alpine:init")
  assert.equal(typeof Alpine.stores.modals.open, "function")

  const newBody = { querySelectorAll: () => [hostElement({ "data-modal-host-store-value": "emailModals",
                                                           "data-modal-host-scoped-value": "true" })] }
  doc.fire("turbo:before-render", { detail: { newBody } })
  assert.equal(typeof Alpine.stores.emailModals.open, "function", "a Turbo visit's scoped host registers before render")

  const newFrame = { querySelectorAll: () => [hostElement({ "data-modal-host-store-value": "frameModals",
                                                            "data-modal-host-scoped-value": "true" })] }
  doc.fire("turbo:before-frame-render", { detail: { newFrame } })
  assert.equal(typeof Alpine.stores.frameModals.open, "function")
})

test("clearStaleModals sweeps the named store, and tolerates a missing one", () => {
  const Alpine = fakeAlpine()
  const env = { doc: fakeDocument(), win: fakeWindow() }
  registerModalStore(Alpine, { store: "modals", scoped: false }, env)
  Alpine.stores.modals.open("celebrate")
  clearStaleModals({ Alpine }, "modals")
  assert.equal(Alpine.stores.modals.stack.length, 0)
  assert.doesNotThrow(() => clearStaleModals({ Alpine }, "missing"))
  assert.doesNotThrow(() => clearStaleModals({}, "modals"))
})
