// [unit] studio/page_transitions: the pure half. One direction per app; each page change
// draws one of its two styles; a same-page visit plays nothing. Loaded from source as a
// data: module, like nav_collapse.test.mjs. Outside a browser it installs nothing.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { runInNewContext } from "node:vm"

const source = readFileSync(new URL("../../app/javascript/studio/page_transitions.js", import.meta.url), "utf8")
const { STYLES, DEFAULT_STYLE, STILL, READY_CAP_MS, FULL_LOAD_STYLE_KEY, REVERSE, BACK_LINK, styleFor, planVisit, planFullLoad, visitIsBack, fullLoadIsBack, sameAddress, leaveStyle, withCap, shareName, holdRender, skipOwnTransition, installPageTransitions } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const visit = { direction: "left", from: "/", to: "/chat", transitions: true, sharedName: false }

test("the module imports nothing, so a head tag can load it alone", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("without the setting's meta it binds nothing", () => {
  const doc = { querySelector: () => null, addEventListener() { throw new Error("bound a listener") } }
  assert.equal(installPageTransitions(doc), false)
})

test("each setting pair names one move", () => {
  assert.deepEqual(STYLES.slide, { left: "slide-left", right: "slide-right", top: "slide-top", bottom: "slide-bottom" })
  assert.deepEqual(STYLES.unfold, { left: "unfold-right", right: "unfold-left", top: "unfold-bottom", bottom: "unfold-top" })
})

test("nothing in either script draws at random", () => {
  assert.doesNotMatch(source, /random/i)
  assert.doesNotMatch(revealSource, /random/i)
})

test("the same settings give the same move every time, whatever Math.random says", () => {
  const real = Math.random
  try {
    for (const value of [0, 0.49, 0.5, 0.999]) {
      Math.random = () => value
      assert.equal(styleFor("top", "unfold"), "unfold-bottom")
      assert.equal(styleFor("top", "slide"), "slide-top")
      assert.equal(planVisit({ ...visit, style: "unfold" }), "unfold-right")
    }
  } finally {
    Math.random = real
  }
})

test("no style setting, or an unknown one, plays the default slide", () => {
  assert.equal(DEFAULT_STYLE, "slide")
  assert.equal(styleFor("left", null), "slide-left")
  assert.equal(styleFor("left", undefined), "slide-left")
  assert.equal(styleFor("left", "swirl"), "slide-left")
  assert.equal(styleFor("left", "constructor"), "slide-left")
})

test("an unknown direction plays nothing, an inherited Object key included", () => {
  assert.equal(styleFor("diagonal", "slide"), null)
  assert.equal(styleFor("constructor", "unfold"), null)
  assert.equal(planVisit({ ...visit, direction: "constructor" }), null)
})

test("a plan is the app's own direction and style on any route, with nothing remembered", () => {
  for (const [from, to] of [["/a", "/b"], ["/b", "/a"], ["/", "/deep/nested"], ["/deep/nested", "/"]]) {
    assert.equal(planVisit({ ...visit, from, to }), "slide-left")
    assert.equal(planVisit({ ...visit, style: "unfold", from, to }), "unfold-right")
  }
})

test("a same-page visit is still", () => {
  assert.equal(planVisit({ ...visit, to: "/" }), STILL)
  assert.equal(planVisit({ ...visit, to: "/", sharedName: true }), STILL)
})

test("an advance to the same path keeps a shared name's morph, and nothing else changes", () => {
  assert.equal(planVisit({ ...visit, to: "/", sharedName: true, advance: true }), null)
  assert.equal(planVisit({ ...visit, to: "/", advance: true }), STILL)
  assert.equal(planVisit({ ...visit, to: "/", sharedName: true, advance: false }), STILL)
})

test("two pages sharing a name play no style, so their morph stands", () => {
  assert.equal(planVisit({ ...visit, sharedName: true }), null)
})

test("no view transition, no setting or no known target leaves the swap alone", () => {
  assert.equal(planVisit({ ...visit, transitions: false }), null)
  assert.equal(planVisit({ ...visit, direction: null }), null)
  assert.equal(planVisit({ ...visit, to: null }), null)
})

test("shareName needs one name on both sides", () => {
  assert.equal(shareName(new Set(["a", "b"]), new Set(["b"])), true)
  assert.equal(shareName(new Set(["a"]), new Set(["b"])), false)
  assert.equal(shareName(new Set(["a"]), undefined), false)
  assert.equal(shareName(new Set(), new Set()), false)
})

test("a slow wait cannot pass the cap, and a fast one ends it", async () => {
  let cap = null
  await withCap(new Promise(() => {}), READY_CAP_MS, (done, ms) => { cap = ms; done() })
  assert.equal(cap, 500)
  assert.equal(await withCap(Promise.resolve("ready"), 500, () => {}), "ready")
})

const fakeEvent = (resume) => ({ detail: { resume }, prevented: false, preventDefault() { this.prevented = true } })

test("the render resumes once the wait ends", async () => {
  let resumed = 0
  const event = fakeEvent(() => { resumed += 1 })
  assert.equal(holdRender(event, () => Promise.resolve()), true)
  assert.equal(event.prevented, true)
  assert.equal(resumed, 0)
  await new Promise((done) => setTimeout(done, 5))
  assert.equal(resumed, 1)
})

test("a failing wait, thrown or rejected, still resumes", async () => {
  let resumed = 0
  holdRender(fakeEvent(() => { resumed += 1 }), () => { throw new Error("importNode") })
  holdRender(fakeEvent(() => { resumed += 1 }), () => Promise.reject(new Error("decode")))
  await new Promise((done) => setTimeout(done, 5))
  assert.equal(resumed, 2)
})

test("a hung wait still resumes at the cap", async () => {
  let resumed = 0
  holdRender(fakeEvent(() => { resumed += 1 }), () => new Promise(() => {}), 10)
  await new Promise((done) => setTimeout(done, 30))
  assert.equal(resumed, 1)
})

test("another listener's resume cannot end the wait", async () => {
  let resumed = 0
  let finish
  const event = fakeEvent(() => { resumed += 1 })
  holdRender(event, () => new Promise((done) => { finish = done }))
  event.detail.resume()
  await new Promise((done) => setTimeout(done, 5))
  assert.equal(resumed, 0)
  finish()
  await new Promise((done) => setTimeout(done, 5))
  assert.equal(resumed, 1)
})

test("with no resume to call, the render is not paused", () => {
  const event = { detail: {}, preventDefault() { throw new Error("paused a render it cannot restart") } }
  assert.equal(holdRender(event, () => {}), false)
})

// ---- A full page load ------------------------------------------------------------------

const activation = (url) => ({ entry: { url: `https://app.test${url}` } })
const fullLoad = { direction: "left", from: "/" }

test("a full load plays what a Turbo visit plays, for every pair of settings", () => {
  for (const style of Object.keys(STYLES)) {
    for (const direction of Object.keys(STYLES[style])) {
      const move = planFullLoad({ direction, style, from: "/", activation: activation("/x") })
      assert.equal(move, STYLES[style][direction])
      assert.equal(move, planVisit({ direction, style, from: "/", to: "/x", transitions: true, sharedName: false }))
    }
  }
})

test("a full load to the same path plans nothing, whatever the query", () => {
  assert.equal(planFullLoad({ ...fullLoad, activation: activation("/?page=2") }), null)
})

test("a full load with no activation entry, or no direction, plans nothing", () => {
  assert.equal(planFullLoad({ ...fullLoad, activation: null }), null)
  assert.equal(planFullLoad({ ...fullLoad, activation: {} }), null)
  assert.equal(planFullLoad({ direction: null, from: "/", activation: activation("/x") }), null)
})

test("the style goes to the next document, and a refusal reads as a plain load", () => {
  const store = new Map()
  const sessionStorage = { setItem: (key, value) => store.set(key, value), removeItem: (key) => store.delete(key) }
  assert.equal(leaveStyle({ sessionStorage }, "slide-left"), true)
  assert.equal(store.get(FULL_LOAD_STYLE_KEY), "slide-left")
  assert.equal(leaveStyle({ sessionStorage }, null), false)
  assert.equal(store.size, 0)
  assert.equal(leaveStyle({ sessionStorage: { setItem() { throw new Error("full") } } }, "slide-left"), false)
})

// A module-level flag lets one document install once, so each case imports its own copy.
async function installed(pathname = "/a", { motion = false, names = [] } = {}) {
  const { installPageTransitions: install } = await import(`data:text/javascript,${encodeURIComponent(`${source}\n// ${Math.random()}`)}`)
  const on = { doc: {}, win: {} }
  const store = new Map()
  const root = { dataset: {} }
  const win = {
    location: { pathname },
    addEventListener: (name, handler) => { on.win[name] = handler },
    sessionStorage: { setItem: (key, value) => store.set(key, value), removeItem: (key) => store.delete(key) },
    matchMedia: () => ({ matches: false }),
    // The response's names, read off the parsed page the way morphNames reads a document.
    DOMParser: class {
      parseFromString(html) {
        const found = [...html.matchAll(/data-vt-morph="([^"]+)"/g)].map((match) => match[1])
        return { querySelectorAll: () => found.map((name) => ({ getAttribute: () => name })) }
      }
    },
  }
  const doc = {
    ...(motion ? { startViewTransition() {} } : {}),
    defaultView: win,
    documentElement: root,
    querySelector: (selector) => (selector.startsWith("meta") ? { content: "left" } : null),
    querySelectorAll: () => names.map((name) => ({ getAttribute: () => name })),
    addEventListener: (name, handler) => { on.doc[name] = handler },
  }
  assert.equal(install(doc), true)
  const swap = (url) => {
    const skipped = { value: false }
    const ready = { caught: false, catch() { this.caught = true; return this } }
    on.win.pageswap({ viewTransition: { ready, skipTransition: () => { skipped.value = true } }, activation: activation(url) })
    assert.equal(ready.caught, skipped.value, "a skip the engine chooses handles its own ready, and only then")
    return skipped.value
  }
  return { on, root, store, win, swap }
}

// Chrome leaves a skipped transition's ready rejection unhandled (a "Transition was skipped"
// pageerror), so a skip the engine chooses handles that one promise itself.
test("the engine's own skip handles its ready rejection, and only that", async () => {
  const order = []
  const ready = Promise.reject(new Error("Transition was skipped"))
  const finished = Promise.resolve()
  const real = { ready, finished, skipTransition: () => order.push("skip") }
  const caught = []
  const original = ready.catch.bind(ready)
  ready.catch = (fn) => { caught.push("ready"); order.push("catch"); return original(fn) }
  finished.catch = () => { caught.push("finished") }
  skipOwnTransition(real)
  assert.deepEqual(order, ["catch", "skip"], "handled before the skip rejects it")
  assert.deepEqual(caught, ["ready"])
  skipOwnTransition({ skipTransition: () => order.push("bare") })
  assert.deepEqual(order.at(-1), "bare", "a transition with no ready still skips")
})

test("pageswap leaves a style and names the stack for the old picture", async () => {
  const { root, store, swap } = await installed()
  root.dataset.pageTransitionMorph = ""
  assert.equal(swap("/b"), false)
  assert.equal(store.get(FULL_LOAD_STYLE_KEY), "slide-left")
  assert.equal(root.dataset.pageTransitionVisit, "")
  assert.equal(root.dataset.pageTransitionMorph, undefined)
})

test("pageswap with no transition leaves nothing, and clears a stale style", async () => {
  const { on, root, store } = await installed()
  store.set(FULL_LOAD_STYLE_KEY, "slide-left")
  on.win.pageswap({ viewTransition: null, activation: activation("/b") })
  assert.equal(store.size, 0)
  assert.equal(root.dataset.pageTransitionVisit, undefined)
})

test("pageswap with blocked storage throws nothing, and the load is plain", async () => {
  const { on, win, root, swap } = await installed()
  Object.defineProperty(win, "sessionStorage", { get() { throw new Error("SecurityError") } })
  on.win.pageswap({ viewTransition: null, activation: activation("/b") })
  assert.equal(swap("/b"), true)
  assert.equal(root.dataset.pageTransitionVisit, undefined)
})

test("pageswap to the same path skips the transition", async () => {
  const { root, store, swap } = await installed()
  assert.equal(swap("/a"), true)
  assert.equal(store.size, 0)
  assert.equal(root.dataset.pageTransitionVisit, undefined)
})

test("a Turbo visit answered by a reload stays still, and a real one is overwritten at before-render", async () => {
  const { on, root } = await installed()
  on.doc["turbo:visit"]({ detail: { url: "https://app.test/b" } })
  assert.equal(root.dataset.pageTransition, STILL)
  on.doc["turbo:reload"]({})
  assert.equal(root.dataset.pageTransition, STILL, "the transition Turbo opened must still draw nothing")
  assert.equal(root.dataset.pageTransitionVisit, undefined)
})

// Turbo starts its view transition one frame after its own read of the response resolves,
// and the old page's picture is taken then. The morph's name is let through only once the
// names are known, so Turbo must read the response through this module's read: the read
// that resolves for Turbo is the one that already named the morph. Measured before this:
// under an 8x CPU throttle, 2 of 6 visits started the transition with no name down, and
// the chat head did not morph (e2e/page_transitions.spec.js, "a chat head on both pages").
test("Turbo's read of a response resolves only after the morph is named", async () => {
  const { on, root } = await installed("/a", { names: ["agent-portrait"] })
  on.doc["turbo:visit"]({ detail: { url: "https://app.test/b", action: "advance" } })
  assert.equal(root.dataset.pageTransitionMorph, undefined, "page b is unknown at the visit")
  // Turbo's getter is response.clone().text(): each access is its own read of the body, and
  // nothing orders one read before another. Here Turbo's (the second) finishes first.
  const page = '<div data-vt-morph="agent-portrait"></div>'
  const reads = []
  const fetchResponse = {
    response: { url: "https://app.test/b", redirected: false },
    redirected: false,
    get responseHTML() {
      let done
      const read = new Promise((resolve) => { done = resolve })
      reads.push(() => done(page))
      return read
    },
  }
  on.doc["turbo:before-fetch-response"]({ target: null, detail: { fetchResponse } })
  const turboRead = Promise.resolve(fetchResponse.responseHTML).then((html) => ({ html, named: root.dataset.pageTransitionMorph }))
  reads.slice().reverse().forEach((finish) => finish())
  const { html, named } = await turboRead
  assert.equal(named, "", "the name was down when Turbo's read resolved")
  assert.equal(html, '<div data-vt-morph="agent-portrait"></div>', "Turbo still reads the page itself")
})

test("Turbo's read of a response survives a page the module cannot parse", async () => {
  const { on, win } = await installed("/a", { names: ["agent-portrait"] })
  win.DOMParser = class { parseFromString() { throw new Error("parser gone") } }
  on.doc["turbo:visit"]({ detail: { url: "https://app.test/b", action: "advance" } })
  const fetchResponse = { response: { url: "https://app.test/b" }, responseHTML: Promise.resolve("<p>b</p>") }
  on.doc["turbo:before-fetch-response"]({ target: null, detail: { fetchResponse } })
  assert.equal(await fetchResponse.responseHTML, "<p>b</p>")
})

test("a visit that fails leaves no style at rest", async () => {
  const { on, root } = await installed()
  on.doc["turbo:visit"]({ detail: { url: "https://app.test/b" } })
  on.doc["turbo:fetch-request-error"]({})
  assert.equal(root.dataset.pageTransition, undefined)
})

test("a visit does not cut a motion that is still running", async () => {
  const { on, root } = await installed()
  root.dataset.pageTransition = "slide-left"
  on.doc["turbo:visit"]({ detail: { url: "https://app.test/b" } })
  assert.equal(root.dataset.pageTransition, "slide-left")
})

test("the document's own first turbo:load leaves a full load's motion alone", async () => {
  const { on, root } = await installed()
  root.dataset.pageTransition = "slide-left"
  root.dataset.pageTransitionVisit = ""
  on.doc["turbo:load"]({})
  assert.equal(root.dataset.pageTransition, "slide-left")
  assert.equal(root.dataset.pageTransitionVisit, "")
})

test("the turbo:load that ends a visit clears the marks", async () => {
  const { on, root } = await installed()
  on.doc["turbo:visit"]({ detail: { url: "https://app.test/b" } })
  on.doc["turbo:load"]({})
  assert.equal(root.dataset.pageTransition, undefined)
})

test("back from the back/forward cache, the page plans from where it now stands", async () => {
  const { on, win, store, swap } = await installed("/a")
  on.doc["turbo:visit"]({ detail: { url: "https://app.test/b" } })
  win.location.pathname = "/c"
  on.win.pageshow({ persisted: false })
  assert.equal(swap("/c"), false, "a fresh pageshow changes nothing")
  store.clear()
  on.win.pageshow({ persisted: true })
  assert.equal(swap("/c"), true, "the restored page is at /c, so /c is the same path")
})

// ---- Back: the app's move the other way --------------------------------------------------

test("each direction has one reverse, and the reverse of the reverse is the direction", () => {
  assert.deepEqual({ ...REVERSE }, { left: "right", right: "left", top: "bottom", bottom: "top" })
  for (const direction of Object.keys(REVERSE)) assert.equal(REVERSE[REVERSE[direction]], direction)
})

test("a back visit plays the reverse move in the same style, for every pair of settings", () => {
  for (const style of Object.keys(STYLES)) {
    for (const direction of Object.keys(STYLES[style])) {
      const back = planVisit({ ...visit, direction, style, back: true })
      assert.equal(back, STYLES[style][REVERSE[direction]])
      assert.notEqual(back, planVisit({ ...visit, direction, style }))
    }
  }
  assert.equal(planVisit({ ...visit, back: true }), "slide-right")
  assert.equal(planVisit({ ...visit, style: "unfold", back: true }), "unfold-left")
})

test("a back visit keeps every other rule: same path, shared name, reduced motion", () => {
  assert.equal(planVisit({ ...visit, to: "/", back: true }), STILL)
  assert.equal(planVisit({ ...visit, sharedName: true, back: true }), null)
  assert.equal(planVisit({ ...visit, transitions: false, back: true }), null)
  assert.equal(styleFor("constructor", "slide", true), null)
})

test("a restore goes back only when Turbo says back, so Forward keeps the app's direction", () => {
  assert.equal(visitIsBack({ action: "restore", turboDirection: "back" }), true)
  assert.equal(visitIsBack({ action: "restore", turboDirection: "forward" }), false)
  assert.equal(visitIsBack({ action: "restore", turboDirection: undefined }), false)
})

test("an advance goes back only to the address of the back link clicked", () => {
  const url = "https://app.test/deployments"
  assert.equal(visitIsBack({ action: "advance", url, backHref: "https://app.test/deployments" }), true)
  assert.equal(visitIsBack({ action: "advance", url, backHref: "https://app.test/deployments#top" }), true)
  assert.equal(visitIsBack({ action: "advance", url, backHref: "https://app.test/epics" }), false)
  assert.equal(visitIsBack({ action: "advance", url, backHref: null }), false)
  assert.equal(visitIsBack({ action: "advance", url: "https://app.test/deployments?all=1", backHref: url }), false)
  assert.equal(sameAddress("not a url", null), false)
})

test("a full load goes back on a traverse to an earlier entry, or to the back link's address", () => {
  const traverse = (from, to) => ({ navigationType: "traverse", from: { index: from }, entry: { index: to, url: "https://app.test/a" } })
  assert.equal(fullLoadIsBack(traverse(3, 2)), true)
  assert.equal(fullLoadIsBack(traverse(2, 3)), false, "Forward")
  assert.equal(fullLoadIsBack({ navigationType: "traverse", from: null, entry: { index: 1 } }), false)
  assert.equal(fullLoadIsBack(traverse(-1, 0)), false, "an entry from another document has index -1")
  const push = { navigationType: "push", entry: { url: "https://app.test/deployments", index: 4 } }
  assert.equal(fullLoadIsBack(push, "https://app.test/deployments"), true)
  assert.equal(fullLoadIsBack(push, "https://app.test/epics"), false)
  assert.equal(fullLoadIsBack(null, "https://app.test/x"), false)
  assert.equal(planFullLoad({ ...fullLoad, activation: activation("/x"), back: true }), "slide-right")
})

// The fake link for the capture-phase click listener.
const link = (href, back) => ({ href, matches: (selector) => selector === BACK_LINK && back })
const clickOn = (on, element) => on.doc.click({ target: { closest: () => element } })
const render = (on, root) => {
  on.doc["turbo:before-render"]({ detail: { newBody: { querySelector: () => null, querySelectorAll: () => [] } } })
  return root.dataset.pageTransition
}

test("a click on a back link turns its visit around, and an ordinary link or a restore Forward does not", async () => {
  const { on, root } = await installed("/deployments/rel-1", { motion: true })
  const visitTo = (url, action = "advance", turboDirection) => {
    if (turboDirection) root.dataset.turboVisitDirection = turboDirection
    else delete root.dataset.turboVisitDirection
    on.doc["turbo:visit"]({ detail: { url, action } })
    const style = render(on, root)
    on.doc["turbo:render"]({})
    on.doc["turbo:load"]({})
    return style
  }

  clickOn(on, link("https://app.test/deployments", true))
  assert.equal(visitTo("https://app.test/deployments"), "slide-right")
  clickOn(on, link("https://app.test/epics", false))
  assert.equal(visitTo("https://app.test/epics"), "slide-left")
  clickOn(on, link("https://app.test/deployments", true))
  assert.equal(visitTo("https://app.test/tasks"), "slide-left", "a visit elsewhere than the back link's address")
  assert.equal(visitTo("https://app.test/deployments"), "slide-left", "the mark lasts one visit")
  assert.equal(visitTo("https://app.test/tasks", "restore", "back"), "slide-right")
  assert.equal(visitTo("https://app.test/deployments", "restore", "forward"), "slide-left")
})

// The first half plays the way the click asked; the second half, Turbo's replace to the
// final address, draws nothing whichever way that was. (An `if (!redirected)` guard once
// kept `back` across the second half. Turbo's replace still fires turbo:before-render, but
// `from` is the final address by then, so planVisit plays STILL either way; the guard was
// dead. Drop `if (redirected) from = target` and this goes red.)
test("a redirect plays its first half's way once, and its second half draws nothing", async () => {
  for (const [backLink, way] of [[true, "slide-right"], [false, "slide-left"]]) {
    const { on, root } = await installed("/a", { motion: true })
    clickOn(on, link("https://app.test/b", backLink))
    on.doc["turbo:visit"]({ detail: { url: "https://app.test/b", action: "advance" } })
    assert.equal(render(on, root), way)
    on.doc["turbo:render"]({})
    on.doc["turbo:visit"]({ detail: { url: "https://app.test/c", action: "replace" } })
    assert.equal(render(on, root), STILL, `after a ${way} first half`)
  }
})

test("pageswap on a traverse to an earlier entry leaves the reverse style", async () => {
  const { on, store } = await installed("/b")
  on.win.pageswap({
    viewTransition: { skipTransition() {} },
    activation: { navigationType: "traverse", from: { index: 2 }, entry: { index: 1, url: "https://app.test/a" } },
  })
  assert.equal(store.get(FULL_LOAD_STYLE_KEY), "slide-right")
  on.win.pageswap({
    viewTransition: { skipTransition() {} },
    activation: { navigationType: "traverse", from: { index: 1 }, entry: { index: 2, url: "https://app.test/c" } },
  })
  assert.equal(store.get(FULL_LOAD_STYLE_KEY), "slide-left", "Forward keeps the direction")
})

test("pageswap after a click on a back link leaves the reverse style, and a plain link the direction", async () => {
  const { on, store } = await installed("/b")
  const swapTo = (url) => on.win.pageswap({ viewTransition: { skipTransition() {} }, activation: { navigationType: "push", entry: { url, index: 3 } } })
  clickOn(on, link("https://app.test/a", true))
  swapTo("https://app.test/a")
  assert.equal(store.get(FULL_LOAD_STYLE_KEY), "slide-right")
  clickOn(on, link("https://app.test/a", false))
  swapTo("https://app.test/a")
  assert.equal(store.get(FULL_LOAD_STYLE_KEY), "slide-left")
})

// ---- studio/page_transition_reveal, the classic script ------------------------------------

const revealSource = readFileSync(new URL("../../app/assets/javascripts/studio/page_transition_reveal.js", import.meta.url), "utf8")

function reveal({ style = null, storage, stack = {} } = {}) {
  const store = new Map(style ? [[FULL_LOAD_STYLE_KEY, style]] : [])
  const listeners = {}
  const attributes = {}
  const appended = []
  const element = stack && { setAttribute: (name, value) => { attributes[name] = value } }
  const root = { dataset: {} }
  const document = {
    documentElement: root,
    head: { appendChild: (el) => appended.push(el) },
    createElement: () => ({ setAttribute(name, value) { this[name] = value }, remove() { this.removed = true } }),
    querySelector: (selector) => (selector.startsWith("meta") ? { content: "left" } : element),
  }
  const timers = []
  const window = {
    addEventListener: (name, handler) => { listeners[name] = handler },
    setTimeout: (fn, ms) => timers.push({ fn, ms }),
    sessionStorage: storage ?? {
      getItem: (key) => store.get(key) ?? null,
      removeItem: (key) => store.delete(key),
    },
  }
  runInNewContext(revealSource, { window, document })
  return { listeners, root, store, attributes, appended, timers }
}

function transition() {
  const state = { skipped: false, readyCaught: false }
  let finish
  const finished = new Promise((done) => { finish = done })
  const ready = { catch() { state.readyCaught = true; return this } }
  return { state, finish, viewTransition: { skipTransition: () => { state.skipped = true }, finished, ready } }
}

test("the classic script holds no table of styles and shares the module's key", () => {
  assert.doesNotMatch(revealSource, /slide-|fade-|unfold-/)
  assert.ok(revealSource.includes(`"${FULL_LOAD_STYLE_KEY}"`))
  assert.doesNotMatch(revealSource, /^\s*(import|export)\s/m)
})

test("an arrival applies the left style, names the stack, and cleans up when the motion ends", async () => {
  const { listeners, root, store, attributes } = reveal({ style: "unfold-right" })
  const { viewTransition, finish, state } = transition()
  listeners.pagereveal({ viewTransition })
  assert.equal(root.dataset.pageTransition, "unfold-right")
  assert.equal(root.dataset.pageTransitionDirection, "left")
  assert.equal(root.dataset.pageTransitionVisit, "")
  assert.equal(attributes["data-vt-held"], "")
  assert.equal(store.size, 0)
  assert.equal(state.skipped, false)
  finish()
  await viewTransition.finished
  await new Promise((done) => setTimeout(done, 0))
  assert.equal(root.dataset.pageTransition, undefined)
  assert.equal(root.dataset.pageTransitionVisit, undefined)
})

test("a motion's end leaves a Turbo visit's own style alone", async () => {
  const { listeners, root } = reveal({ style: "slide-left" })
  const { viewTransition, finish } = transition()
  listeners.pagereveal({ viewTransition })
  root.dataset.pageTransition = "unfold-right"
  finish()
  await viewTransition.finished
  await new Promise((done) => setTimeout(done, 0))
  assert.equal(root.dataset.pageTransition, "unfold-right")
})

test("an arrival nobody planned is skipped, so the browser's own fade never plays", () => {
  const { listeners, root } = reveal()
  const { viewTransition, state } = transition()
  listeners.pagereveal({ viewTransition })
  assert.equal(state.skipped, true)
  assert.equal(state.readyCaught, true, "the skip it chose leaves no unhandled ready rejection")
  assert.equal(root.dataset.pageTransition, undefined)
})

test("a page back from the cache sheds what it wore when it left, with or without a motion", () => {
  const { listeners, root, store } = reveal({ style: "slide-left" })
  root.dataset.pageTransition = "slide-left"
  root.dataset.pageTransitionVisit = ""
  listeners.pagereveal({ viewTransition: null })
  assert.equal(root.dataset.pageTransition, undefined)
  assert.equal(root.dataset.pageTransitionVisit, undefined)
  assert.equal(store.size, 0, "a stale style must not reach a later load")
})

test("a page with no stack still plays", () => {
  const { listeners, root } = reveal({ style: "slide-left", stack: null })
  listeners.pagereveal({ viewTransition: transition().viewTransition })
  assert.equal(root.dataset.pageTransition, "slide-left")
})

test("storage that throws reads as a plain load, and nothing escapes", () => {
  const storage = { getItem() { throw new Error("denied") }, removeItem() { throw new Error("denied") } }
  const { listeners, appended, root } = reveal({ storage })
  const { viewTransition, state } = transition()
  listeners.pagereveal({ viewTransition })
  assert.equal(state.skipped, true)
  assert.equal(appended.length, 0)
  assert.equal(root.dataset.pageTransition, undefined)
})

test("the first render waits for the whole page only on a planned arrival, up to the cap", () => {
  assert.equal(reveal().appended.length, 0)
  assert.equal(reveal().timers.length, 0)
  const { appended: [link], timers: [timer] } = reveal({ style: "slide-left" })
  assert.equal(link.rel, "expect")
  assert.equal(link.blocking, "render")
  assert.match(link.href, /^#/)
  assert.equal(timer.ms, 3000)
  assert.equal(link.removed, undefined)
  timer.fn()
  assert.equal(link.removed, true)
})
