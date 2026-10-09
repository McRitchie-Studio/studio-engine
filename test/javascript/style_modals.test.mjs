// [unit] studio/style_modals: the style guide's stack demos, the enter/leave
// simulator's controls built from the live animation registry, and the wallet
// stubs. Loaded from source as a data: module, like identity_mini.test.mjs;
// the module imports nothing.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/style_modals.js", import.meta.url), "utf8")
const {
  VEHICLE, ANIM_DEMO_ID, ANIM_DEMO_PROPS, ANIM_CONTROL_IDS, PENDING, SUCCESS, FAILURE, WALLET_CONNECT_MS,
  animationLabel, animationRegistry, roundTripHoldMs, installWalletStubs, createModalDemos
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing and names no store but the one it is handed", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
  assert.doesNotMatch(source, /solanaModal/, "the guide drives its own store, never an app's legacy proxy")
})

test("a registry key becomes a label, and pop says it is the default", () => {
  assert.equal(animationLabel("shake"), "Shake")
  assert.equal(animationLabel("pop"), "Pop (default)")
})

test("the registry is read from the window when asked, and a missing one is two empty tables", () => {
  assert.deepEqual(animationRegistry({}), { enter: {}, exit: {} })
  const win = { ModalAnimations: { enter: { pop: { ms: 320 } } } }
  assert.equal(animationRegistry(win).enter, win.ModalAnimations.enter)
  assert.deepEqual(animationRegistry(win).exit, {})
})

test("a round trip holds for the entrance's own duration plus a beat", () => {
  const win = { ModalAnimations: { enter: { shake: { ms: 600 } }, exit: {} } }
  assert.equal(roundTripHoldMs(win, "shake"), 1300)
  assert.equal(roundTripHoldMs(win, "unknown"), 1020)
})

// ---- the wallet stubs ---------------------------------------------------------

test("the wallet stubs list two wallets, have neither, and connect after a beat", async () => {
  const delays = []
  const win = { setTimeout(fn, ms) { delays.push(ms); fn() } }
  installWalletStubs(win)
  assert.deepEqual(win.walletProvider.available().map((w) => w.name), ["Phantom", "Solflare"])
  assert.equal(win.walletProvider.isAvailable(), false)
  assert.equal(win.walletProvider.isMobile(), false)
  assert.deepEqual(await win.dsWalletConnectDemo(), { success: true })
  assert.deepEqual(delays, [WALLET_CONNECT_MS])
})

test("a page that ships a real provider or connect keeps it", () => {
  const provider = { real: true }
  const connect = () => "real"
  const win = { walletProvider: provider, dsWalletConnectDemo: connect, setTimeout() {} }
  installWalletStubs(win)
  assert.equal(win.walletProvider, provider)
  assert.equal(win.dsWalletConnectDemo, connect)
})

// ---- the demos ------------------------------------------------------------------

// A modal store that records what it was asked, a window whose timers the test
// runs by hand, and a document with the four simulator containers.
const fakeStore = () => ({
  stack: [],
  opened: [],
  advanced: [],
  closed: 0,
  current() { return this.stack.length ? this.stack[this.stack.length - 1] : null },
  open(id, props) { const entry = { id, props }; this.stack.push(entry); this.opened.push(entry) },
  advance(patch) { this.advanced.push(patch) },
  close() { this.closed += 1 }
})

const fakeNode = (tag) => ({ tag, children: [], innerHTML: "x", appendChild(child) { this.children.push(child) } })

const world = ({ registry, storeName = "dsModals" } = {}) => {
  const store = fakeStore()
  const stores = { [storeName]: store }
  let timers = []
  const holds = []
  const nodes = Object.fromEntries(Object.values(ANIM_CONTROL_IDS).map((id) => [id, fakeNode(id)]))
  const win = {
    ModalAnimations: registry || { enter: { pop: { ms: 320 }, shake: { ms: 600 } }, exit: { pop: { ms: 220 }, slide: { ms: 220 } } },
    Alpine: { store: (name) => stores[name] },
    StudioModals: { holdAtLeast(ms) { const hold = { ms, then(cb) { this.cb = cb } }; holds.push(hold); return hold } },
    setTimeout(fn, ms) { timers.push({ fn, ms }) },
    delays: () => timers.map((t) => t.ms),
    run() { const due = timers; timers = []; due.forEach((t) => t.fn()) }
  }
  const doc = {
    getElementById: (id) => nodes[id] || null,
    createElement: (tag) => ({ tag })
  }
  const demos = createModalDemos({ win, doc, store: storeName })
  return { demos, store, win, doc, nodes, holds }
}

test("a stack demo opens the guide's own vehicle as a pending, locked operation", () => {
  const { demos, store } = world()
  demos.processing()
  assert.equal(store.opened[0].id, VEHICLE)
  assert.deepEqual(store.opened[0].props, PENDING)
  assert.equal(PENDING.dismissible, false)
})

test("success and error open the vehicle on those faces; dismissible overrides the lock", () => {
  const { demos, store } = world()
  demos.success()
  demos.error()
  demos.dismissible()
  assert.equal(store.opened[0].props.state, "success")
  assert.equal(store.opened[1].props.state, "error")
  assert.equal(store.opened[2].props.dismissible, true)
  assert.equal(store.opened[2].props.state, "processing")
})

test("the timed demos advance the open card in place after three seconds", () => {
  const { demos, store, win } = world()
  demos.processThenSuccess()
  assert.deepEqual(win.delays(), [3000])
  win.run()
  assert.deepEqual(store.advanced, [SUCCESS])

  const failing = world()
  failing.demos.processThenError()
  failing.win.run()
  assert.deepEqual(failing.store.advanced, [FAILURE])
})

test("a timer that fires after the card closed patches nothing", () => {
  const { demos, store, win } = world()
  demos.processThenSuccess()
  store.stack.pop()
  win.run()
  assert.deepEqual(store.advanced, [])

  const other = world()
  other.demos.processThenSuccess()
  other.store.stack.push({ id: "some-other-card", props: {} })
  other.win.run()
  assert.deepEqual(other.store.advanced, [], "a different card on top is left alone")

  const closing = world()
  closing.demos.processThenSuccess()
  closing.store.current()._closing = true
  closing.win.run()
  assert.deepEqual(closing.store.advanced, [])
})

test("the hold demo advances when the engine's hold lets go, and the no-hold one after 50ms", () => {
  const { demos, store, win, holds } = world()
  demos.fastWithHold()
  assert.equal(holds[0].ms, 1500)
  assert.deepEqual(store.advanced, [])
  holds[0].cb()
  assert.deepEqual(store.advanced, [SUCCESS])

  const flashing = world()
  flashing.demos.fastNoHold()
  assert.deepEqual(flashing.win.delays(), [50])
})

test("stackTwo pushes a second card onto the first", () => {
  const { demos, store, win } = world()
  demos.stackTwo()
  assert.deepEqual(win.delays(), [700])
  win.run()
  assert.deepEqual(store.opened.map((entry) => entry.id), [VEHICLE, ANIM_DEMO_ID])
  assert.deepEqual(store.opened[1].props, ANIM_DEMO_PROPS)
})

test("the demos drive the store they are handed", () => {
  const { demos, store } = world({ storeName: "labModals" })
  demos.processing()
  assert.equal(store.opened.length, 1)
})

// ---- the simulator --------------------------------------------------------------

test("the controls are built from the registry: one button and one option per key", () => {
  const { demos, nodes } = world()
  demos.buildAnimControls()
  const enterButtons = nodes[ANIM_CONTROL_IDS.enterButtons].children
  const exitButtons = nodes[ANIM_CONTROL_IDS.exitButtons].children
  const enterOptions = nodes[ANIM_CONTROL_IDS.enterSelect].children
  const exitOptions = nodes[ANIM_CONTROL_IDS.exitSelect].children

  assert.deepEqual(enterButtons.map((b) => b.textContent), ["Pop (default) ↗", "Shake ↗"])
  assert.deepEqual(exitButtons.map((b) => b.textContent), ["Pop (default)", "Slide"])
  assert.deepEqual(enterOptions.map((o) => o.value), ["pop", "shake"])
  assert.deepEqual(exitOptions.map((o) => o.value), ["pop", "slide"])
  assert.equal(enterOptions[0].selected, true)
  assert.equal(enterOptions[1].selected, undefined)
  assert.equal(enterButtons[0].className, "btn btn-outline btn-sm")
})

test("a key registered after the first build grows a control on the next, and nothing doubles", () => {
  const { demos, nodes, win } = world()
  demos.buildAnimControls()
  win.ModalAnimations.enter.labzoom = { cls: "lab-zoom-in", ms: 500 }
  const container = nodes[ANIM_CONTROL_IDS.enterButtons]
  // The fake's innerHTML setter does not empty children, so empty them as the
  // browser would when innerHTML is cleared.
  Object.values(nodes).forEach((node) => {
    Object.defineProperty(node, "innerHTML", { set() { node.children = [] }, configurable: true })
  })
  demos.buildAnimControls()
  assert.deepEqual(container.children.map((b) => b.textContent), ["Pop (default) ↗", "Shake ↗", "Labzoom ↗"])
})

test("an enter button opens the demo card with that entrance; an exit button round-trips to that exit", () => {
  const { demos, nodes, store, win } = world()
  demos.buildAnimControls()

  nodes[ANIM_CONTROL_IDS.enterButtons].children[1].onclick()
  assert.equal(store.opened[0].id, ANIM_DEMO_ID)
  assert.deepEqual(store.opened[0].props, { ...ANIM_DEMO_PROPS, enterAnim: "shake", exitAnim: "pop" })

  nodes[ANIM_CONTROL_IDS.exitButtons].children[1].onclick()
  assert.deepEqual(store.opened[1].props, { ...ANIM_DEMO_PROPS, enterAnim: "pop", exitAnim: "slide" })
  assert.deepEqual(win.delays(), [1020])
  win.run()
  assert.equal(store.closed, 1)
})

test("the selects drive an open and a round trip", () => {
  const { demos, nodes, store, win } = world()
  nodes[ANIM_CONTROL_IDS.enterSelect].value = "shake"
  nodes[ANIM_CONTROL_IDS.exitSelect].value = "slide"
  demos.animOpenSelected()
  assert.deepEqual(store.opened[0].props, { ...ANIM_DEMO_PROPS, enterAnim: "shake", exitAnim: "slide" })
  demos.animRoundTripSelected()
  assert.deepEqual(win.delays(), [1300])
})

test("a page with none of the simulator's containers builds nothing and does not throw", () => {
  const { win } = world()
  const demos = createModalDemos({ win, doc: { getElementById: () => null, createElement: () => ({}) } })
  demos.buildAnimControls()
})
