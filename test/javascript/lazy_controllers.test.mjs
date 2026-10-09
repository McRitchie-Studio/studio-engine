// [unit] studio/lazy_controllers: which lazy identifiers a page names, the
// watcher that loads and registers each one once, on first sight, and what it
// does when a load fails. Loaded from source as a data: module.
//
// THE FAILING LOADERS HERE BEHAVE AS A BROWSER DOES: a module that failed to
// load fails on every later import() of it, with no new request
// (e2e/lazy_controller_failure.spec.js measures that in Chromium). A fake
// loader that fails once and then succeeds describes no browser, so no test
// here uses one to claim a retry.
//
// CONTROLS, each run against this file:
//   - re-queue a failed controller in the watcher's catch (`pending.add(name)`
//     in place of `failed.set(name, error)` and `mark()`): "never loaded
//     again", "reported once" and the marking tests fail.
//   - drop the `mark()` call from the catch: the tests that read a mark after
//     the first failure fail.
//   - drop `failed.size > 0` from the observer's condition: "an element that
//     arrives after the failure" fails.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/lazy_controllers.js", import.meta.url), "utf8")
const { controllerNames, lazyNamesIn, markFailed, watchLazyControllers, FAILED_ATTRIBUTE } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const ATTRIBUTE = "data-studio-controller"

// An element that remembers the attributes written on it.
const element = (value) => {
  const attributes = { [ATTRIBUTE]: value }
  return {
    attributes,
    writes: 0,
    getAttribute: (name) => (name in attributes ? attributes[name] : null),
    setAttribute(name, written) { attributes[name] = written; this.writes += 1 }
  }
}

// A root whose descendants the test can change, as a page changes. Each value
// keeps one element across scans, so a mark written on it is still there.
const fakeRoot = (values = [], own = null) => ({
  values,
  elements: new Map(),
  getAttribute: (name) => (name === ATTRIBUTE ? own : null),
  elementAt(index) {
    if (!this.elements.has(index)) this.elements.set(index, element(this.values[index]))
    return this.elements.get(index)
  },
  querySelectorAll(selector) {
    assert.equal(selector, `[${ATTRIBUTE}]`)
    return this.values.map((_, index) => this.elementAt(index))
  }
})

const failedMark = (root, index) => root.elementAt(index).getAttribute(FAILED_ATTRIBUTE)

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

// A module that failed to load, as a browser serves it: every import() of it
// rejects, however many times it is asked.
const brokenModule = (message = "offline") => {
  const loader = () => { loader.attempts += 1; return Promise.reject(new Error(message)) }
  loader.attempts = 0
  return loader
}

test("a loader that fails is never loaded again, however the page changes", async () => {
  const broken = brokenModule()
  const root = fakeRoot(["board"])
  const { handle, registered, observer } = watch(root, { board: broken })

  await handle.started
  assert.equal(broken.attempts, 1)
  assert.deepEqual([...handle.pending], [], "a failed controller is not pending: nothing loads it again")
  assert.deepEqual([...handle.failed.keys()], ["board"])
  assert.equal(handle.failed.get("board").message, "offline")

  for (let change = 0; change < 5; change += 1) {
    root.values = [...root.values, "board"]
    observer.callback()
    await settle()
  }
  await handle.scan()

  assert.equal(broken.attempts, 1, "one import for the document, as a browser makes one request")
  assert.deepEqual(registered, [])
})

test("a failure is reported once, not once per change", async () => {
  const root = fakeRoot(["board"])
  const { handle, reports, observer } = watch(root, { board: brokenModule("404") })

  await handle.started
  observer.callback()
  observer.callback()
  await settle()

  assert.deepEqual(reports, [["board", "404"]])
})

test("the default report names the controller and says a reload is needed", async () => {
  const logged = []
  const original = console.error
  console.error = (...args) => logged.push(args)
  try {
    const { handle } = watch(fakeRoot(["board"]), { board: brokenModule() }, { report: undefined })
    await handle.started
  } finally {
    console.error = original
  }

  assert.equal(logged.length, 1)
  assert.match(logged[0][0], /the board controller failed to load/)
  assert.match(logged[0][0], /until the page is reloaded/)
  assert.equal(logged[0][1].message, "offline")
})

test("every element naming a failed controller is marked, and only those", async () => {
  const root = fakeRoot(["board", "toast", "nav-collapse board", "board-extra"])
  const { handle } = watch(root, { board: brokenModule() })

  await handle.started
  assert.equal(failedMark(root, 0), "board")
  assert.equal(failedMark(root, 1), null, "a controller that did not fail is not marked")
  assert.equal(failedMark(root, 2), "board", "the mark names the failed identifier, not its neighbours")
  assert.equal(failedMark(root, 3), null, "only a whole identifier")
})

test("an element that arrives after the failure is marked, with no new load", async () => {
  const broken = brokenModule()
  const root = fakeRoot(["board"])
  const { handle, observer } = watch(root, { board: broken })
  await handle.started
  assert.equal(observer.connected, true, "still watching, to mark what arrives later")

  root.values = ["board", "board"]
  observer.callback()
  await settle()

  assert.equal(failedMark(root, 1), "board")
  assert.equal(broken.attempts, 1)
  assert.equal(root.elementAt(0).writes, 1, "an element already marked is not written again")
})

test("a controller that loads leaves no mark, and one failure does not stop another's load", async () => {
  const root = fakeRoot(["board", "profile"])
  const { handle, registered, observer } = watch(root, {
    board: brokenModule(),
    profile: () => Promise.resolve({ default: "P" })
  })

  await handle.started
  assert.deepEqual(registered, [["profile", "P"]])
  assert.equal(failedMark(root, 0), "board")
  assert.equal(failedMark(root, 1), null)
  assert.equal(observer.connected, true)
})

test("with every controller registered and none failed, the watcher stops", async () => {
  const { handle, observer } = watch(fakeRoot(["board"]), { board: () => ({ default: "B" }) })
  await handle.started
  assert.equal(handle.failed.size, 0)
  assert.equal(observer.connected, false)
})

test("a loader that throws, and a registration that throws, fail like a load that rejects", async () => {
  const thrown = fakeRoot(["board"])
  const first = watch(thrown, { board: () => { throw new Error("bad pin") } })
  await first.handle.started
  assert.deepEqual(first.reports, [["board", "bad pin"]])
  assert.equal(failedMark(thrown, 0), "board")

  const refused = fakeRoot(["board"])
  const second = watch(refused, { board: () => ({ default: "B" }) }, { register: () => { throw new Error("not a controller") } })
  await second.handle.started
  assert.deepEqual(second.reports, [["board", "not a controller"]])
  assert.equal(failedMark(refused, 0), "board")
})

test("markFailed writes the failed identifiers an element names, under the attribute it is given", () => {
  const root = fakeRoot(["board profile toast", "toast"], "profile")
  const own = []
  root.setAttribute = (name, value) => own.push([name, value])

  const marked = markFailed(root, ["board", "profile"], ATTRIBUTE, "data-lost")
  assert.deepEqual(own, [["data-lost", "profile"]], "the root itself counts")
  assert.equal(root.elementAt(0).getAttribute("data-lost"), "board profile")
  assert.equal(root.elementAt(1).getAttribute("data-lost"), null)
  assert.equal(marked.length, 2)
  assert.deepEqual(markFailed(root, [], ATTRIBUTE), [], "nothing failed, nothing marked")
  assert.equal(FAILED_ATTRIBUTE, "data-studio-controller-failed")
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
