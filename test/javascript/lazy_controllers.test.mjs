// [unit] studio/lazy_controllers: which lazy identifiers a page names, and the
// watcher that loads and registers each one once, on first sight. Loaded from
// source as a data: module.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/lazy_controllers.js", import.meta.url), "utf8")
const { controllerNames, lazyNamesIn, watchLazyControllers } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const ATTRIBUTE = "data-studio-controller"

const element = (value) => ({ getAttribute: (name) => (name === ATTRIBUTE ? value : null) })

// A root whose descendants the test can change, as a page changes.
const fakeRoot = (values = [], own = null) => ({
  values,
  getAttribute: (name) => (name === ATTRIBUTE ? own : null),
  querySelectorAll(selector) {
    assert.equal(selector, `[${ATTRIBUTE}]`)
    return this.values.map(element)
  }
})

class FakeObserver {
  static instances = []
  constructor(callback) { this.callback = callback; this.connected = false; FakeObserver.instances.push(this) }
  observe(root, options) { this.root = root; this.options = options; this.connected = true }
  disconnect() { this.connected = false }
}

const watch = (root, loaders, extra = {}) => {
  const registered = []
  const reports = []
  FakeObserver.instances = []
  const handle = watchLazyControllers({
    root, attribute: ATTRIBUTE, loaders, Observer: FakeObserver,
    register: (name, controller) => registered.push([name, controller]),
    report: (name, error) => reports.push([name, error.message]),
    ...extra
  })
  return { handle, registered, reports, observer: FakeObserver.instances[0] }
}

const settle = () => new Promise((resolve) => setImmediate(resolve))

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("an attribute value is a space-separated list of identifiers", () => {
  assert.deepEqual(controllerNames("hold-button"), ["hold-button"])
  assert.deepEqual(controllerNames("  toast   hold-button "), ["toast", "hold-button"])
  assert.deepEqual(controllerNames(""), [])
  assert.deepEqual(controllerNames(null), [])
})

test("the lazy identifiers a page names, each once, and only whole identifiers", () => {
  const root = fakeRoot(["toast", "hold-button", "nav-collapse hold-button", "hold-button-extra"])

  assert.deepEqual(lazyNamesIn(root, ["hold-button", "board"], ATTRIBUTE), ["hold-button"])
  assert.deepEqual(lazyNamesIn(root, [], ATTRIBUTE), [])
  assert.deepEqual(lazyNamesIn(null, ["hold-button"], ATTRIBUTE), [])
  assert.deepEqual(lazyNamesIn(fakeRoot([], "board"), ["board"], ATTRIBUTE), ["board"], "the root itself counts")
})

test("a controller already on the page is loaded and registered at once", async () => {
  const Controller = class {}
  let loads = 0
  const { handle, registered, observer } = watch(fakeRoot(["hold-button"]), {
    "hold-button": () => { loads += 1; return Promise.resolve({ default: Controller }) }
  })

  await handle.started
  assert.deepEqual(registered, [["hold-button", Controller]])
  assert.equal(loads, 1)
  assert.equal(observer.connected, false, "nothing left to wait for")
})

test("a page that names no lazy controller loads none, and keeps watching", async () => {
  let loads = 0
  const root = fakeRoot(["toast"])
  const { handle, registered, observer } = watch(root, { "hold-button": () => { loads += 1; return { default: 1 } } })

  await handle.started
  assert.equal(loads, 0)
  assert.deepEqual(registered, [])
  assert.equal(observer.connected, true)
  assert.deepEqual(observer.options, { childList: true, subtree: true, attributes: true, attributeFilter: [ATTRIBUTE] })
  assert.equal(observer.root, root)
})

test("a controller that arrives later is loaded when the page changes, once", async () => {
  let loads = 0
  const root = fakeRoot([])
  const { registered, observer } = watch(root, { "hold-button": () => { loads += 1; return { default: "C" } } })
  await settle()

  root.values = ["hold-button"]
  observer.callback()
  observer.callback()
  await settle()

  assert.equal(loads, 1, "a second change while it loads starts no second load")
  assert.deepEqual(registered, [["hold-button", "C"]])
  assert.equal(observer.connected, false)
})

test("with two lazy controllers the watcher stops only when both have loaded", async () => {
  const root = fakeRoot(["hold-button"])
  const { registered, observer } = watch(root, {
    "hold-button": () => ({ default: "H" }),
    board: () => ({ default: "B" })
  })
  await settle()
  assert.deepEqual(registered, [["hold-button", "H"]])
  assert.equal(observer.connected, true)

  root.values = ["hold-button", "board"]
  observer.callback()
  await settle()
  assert.deepEqual(registered, [["hold-button", "H"], ["board", "B"]])
  assert.equal(observer.connected, false)
})

test("a loader that fails is reported and tried again on the next change", async () => {
  let attempts = 0
  const root = fakeRoot(["hold-button"])
  const { handle, registered, reports, observer } = watch(root, {
    "hold-button": () => {
      attempts += 1
      return attempts === 1 ? Promise.reject(new Error("offline")) : Promise.resolve({ default: "C" })
    }
  })

  await handle.started
  assert.deepEqual(reports, [["hold-button", "offline"]])
  assert.deepEqual(registered, [])
  assert.equal(observer.connected, true, "still watching, so the next change retries")

  observer.callback()
  await settle()
  assert.deepEqual(registered, [["hold-button", "C"]])
})

test("a loader that throws is reported like one that rejects", async () => {
  const { handle, reports } = watch(fakeRoot(["hold-button"]), { "hold-button": () => { throw new Error("bad pin") } })
  await handle.started
  assert.deepEqual(reports, [["hold-button", "bad pin"]])
})

test("stop disconnects the observer", () => {
  const { handle, observer } = watch(fakeRoot([]), { "hold-button": () => ({ default: 1 }) })
  handle.stop()
  assert.equal(observer.connected, false)
})

test("with no loaders there is nothing to observe", () => {
  const { observer } = watch(fakeRoot(["toast"]), {})
  assert.equal(observer, undefined)
})
