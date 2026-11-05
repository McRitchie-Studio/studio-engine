// [unit] studio/alpine_stores: the theme and devMode stores, the theme value
// and toggle behind them, and the registration that runs from two paths. Loaded
// from source as a data: module, like head_chrome.test.mjs; the module imports
// nothing, which is what lets it load when studio/application does not.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/alpine_stores.js", import.meta.url), "utf8")
const { themeStore, registerStudioStores, installStudioStores } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const storage = (initial = {}) => {
  const values = { ...initial }
  return { values, getItem: (k) => (k in values ? values[k] : null), setItem: (k, v) => { values[k] = String(v) } }
}

const root = (classes) => {
  const set = new Set(classes)
  return {
    set,
    dataset: {},
    classList: {
      contains: (c) => set.has(c),
      toggle: (c, on) => (on ? (set.add(c), true) : (set.delete(c), false))
    }
  }
}

// Alpine.store as Alpine has it: one argument reads, two register.
const fakeAlpine = () => {
  const stores = {}
  const writes = []
  return {
    stores,
    writes,
    store(name, value) {
      if (value === undefined) return stores[name]
      writes.push(name)
      stores[name] = value
    }
  }
}

const fakeDocument = () => {
  const listeners = {}
  return {
    listeners,
    documentElement: root(["dark"]),
    addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn) },
    fire(type) { (listeners[type] || []).forEach((fn) => fn()) }
  }
}

test("the source imports nothing, so no other module's failure can stop it", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("the store starts from the root's class, which the pre-paint script set", () => {
  // The pre-paint script reads anything but "light" as dark. The store used to read that word itself.
  assert.equal(themeStore({ root: root(["dark"]), storage: storage({ theme: "sepia" }) }).isDark, true)
  assert.equal(themeStore({ root: root([]), storage: storage({ theme: "light" }) }).value, "light")
  assert.equal(themeStore({ root: root(["dark"]), storage: storage() }).value, "dark")
})

// A document with view transitions. Each one holds its callback until the test takes the old
// picture, and a new one skips the one before it, flushing its callback, as the browser does.
const fakeDoc = () => {
  const transitions = []
  const doc = {
    transitions,
    startViewTransition(callback) {
      const last = transitions.at(-1)
      if (last && !last.done) last.skip()
      const transition = {
        ran: false,
        done: false,
        run() { if (!this.ran) { this.ran = true; callback() } },
        finish() { this.run(); this.done = true; this.resolve() },
        skip() { this.run(); this.done = true; this.rejectReady(new Error("AbortError")); this.resolve() }
      }
      transition.finished = new Promise((resolve) => { transition.resolve = resolve })
      transition.ready = new Promise((_, reject) => { transition.rejectReady = reject })
      transition.updateCallbackDone = Promise.resolve()
      transitions.push(transition)
      return transition
    }
  }
  return doc
}

const fakeWin = ({ reduced = false } = {}) => ({
  flushed: [],
  matchMedia: () => ({ matches: reduced }),
  getComputedStyle(el) { this.flushed.push(el); return {} }
})

// The store, on a page in `theme`, with a view of everything that must agree.
const page = (theme = "dark", { doc = fakeDoc(), win = fakeWin() } = {}) => {
  const html = root(theme === "dark" ? ["dark"] : [])
  const store = storage({ theme })
  const later = []
  const theme_ = themeStore({ root: html, storage: store, later: (fn, ms) => later.push([fn, ms]), doc, win })
  return {
    html, store, later, doc, win, theme: theme_,
    state: () => ({ value: theme_.value, isDark: theme_.isDark, dark: html.set.has("dark"), stored: store.values.theme })
  }
}
const DARK = { value: "dark", isDark: true, dark: true, stored: "dark" }
const LIGHT = { value: "light", isDark: false, dark: false, stored: "light" }
const settled = () => new Promise((resolve) => setImmediate(resolve))

test("the old transition class is gone from the source", () => {
  assert.doesNotMatch(source, /theme-transition/)
})

test("crossfade: nothing changes before the old picture, then all three change in one step", async () => {
  const p = page("dark")
  p.theme.toggle()
  assert.equal(p.doc.transitions.length, 1)
  assert.equal(p.html.dataset.themeFlip, "", "the rules must be on before the old picture")
  assert.deepEqual(p.state(), DARK, "the old picture must hold the old theme")

  p.doc.transitions[0].run()
  assert.deepEqual(p.state(), LIGHT)
  assert.equal(p.html.dataset.themeFlip, "", "the attribute stays for the whole crossfade")

  p.doc.transitions[0].finish()
  await settled()
  assert.equal(p.html.dataset.themeFlip, undefined)
  assert.deepEqual(p.later, [], "the crossfade needs no timer")
})

test("crossfade: a skipped transition clears the attribute and rejects nothing unhandled", async () => {
  const unhandled = []
  const hear = (error) => unhandled.push(error)
  process.on("unhandledRejection", hear)
  try {
    const p = page("dark")
    p.theme.toggle()
    p.doc.transitions[0].skip()
    await settled()
    await settled()
    assert.equal(p.html.dataset.themeFlip, undefined)
    assert.deepEqual(p.state(), LIGHT, "the callback still runs on a skip")
    assert.deepEqual(unhandled, [])
  } finally {
    process.off("unhandledRejection", hear)
  }
})

test("crossfade: a throw in the step leaves no attribute and no unhandled rejection", async () => {
  const unhandled = []
  const hear = (error) => unhandled.push(error)
  process.on("unhandledRejection", hear)
  try {
    const failed = Promise.reject(new Error("quota"))
    const doc = {
      startViewTransition: () => ({ finished: failed, ready: failed, updateCallbackDone: failed })
    }
    const p = page("dark", { doc })
    p.theme.toggle()
    await settled()
    await settled()
    assert.equal(p.html.dataset.themeFlip, undefined)
    assert.deepEqual(unhandled, [])
  } finally {
    process.off("unhandledRejection", hear)
  }
})

test("a second toggle before the first picture ends on the first theme, and the three agree", async () => {
  const p = page("dark")
  p.theme.toggle()
  p.theme.toggle()
  assert.equal(p.doc.transitions[0].done, true, "the browser skipped the first")
  assert.deepEqual(p.state(), DARK, "the skipped flip's late callback must not act")

  await settled()
  assert.equal(p.html.dataset.themeFlip, "", "the skipped flip must not clear the live flip's attribute")

  p.doc.transitions[1].finish()
  await settled()
  assert.deepEqual(p.state(), DARK)
  assert.equal(p.html.dataset.themeFlip, undefined)
})

test("a second toggle during the first crossfade flips back, and the first's end clears nothing", async () => {
  const p = page("dark")
  p.theme.toggle()
  p.doc.transitions[0].run()
  assert.deepEqual(p.state(), LIGHT)

  p.theme.toggle()
  await settled()
  assert.equal(p.html.dataset.themeFlip, "")
  p.doc.transitions[1].finish()
  await settled()
  assert.deepEqual(p.state(), DARK)
  assert.equal(p.html.dataset.themeFlip, undefined)
})

for (const [name, options] of [
  ["a browser with no view transitions", { doc: {} }],
  ["a reduced-motion reader", { win: fakeWin({ reduced: true }) }]
]) {
  test(`instant: ${name} flips at once, with the rules on until the new styles are computed`, () => {
    const p = page("dark", options)
    p.theme.toggle()
    assert.deepEqual(p.state(), LIGHT)
    assert.equal(p.html.dataset.themeFlip, "", "the new styles must compute under the rules")
    assert.deepEqual(p.win.flushed, [p.html])
    assert.equal(p.later[0][1], 0)
    p.later[0][0]()
    assert.equal(p.html.dataset.themeFlip, undefined)
  })
}

for (const attribute of ["turboVisitDirection", "pageTransition"]) {
  test(`instant: during a visit (${attribute}) a toggle leaves Turbo's transition alone`, () => {
    const p = page("dark")
    p.html.dataset[attribute] = "forward"
    p.theme.toggle()
    assert.equal(p.doc.transitions.length, 0, "a second transition would cut the visit's motion short")
    assert.deepEqual(p.state(), LIGHT)
  })
}

test("an instant flip outruns a crossfade still waiting for its picture", async () => {
  const p = page("dark")
  p.theme.toggle()
  p.html.dataset.turboVisitDirection = "forward"
  p.theme.toggle()
  assert.deepEqual(p.state(), DARK)
  p.doc.transitions[0].finish()
  await settled()
  assert.deepEqual(p.state(), DARK, "the older flip's callback must not undo the newer")
  assert.equal(p.html.dataset.themeFlip, "", "only the newest flip clears the attribute")
  p.later[0][0]()
  assert.equal(p.html.dataset.themeFlip, undefined)
})

test("set by value reaches that theme from either side and from a pending flip", async () => {
  const p = page("dark")
  p.theme.set("light")
  p.doc.transitions[0].finish()
  await settled()
  assert.deepEqual(p.state(), LIGHT)

  p.theme.set("dark")
  p.theme.set("dark")
  assert.equal(p.doc.transitions.length, 2, "asking again for the theme on its way opens nothing")
  p.doc.transitions[1].finish()
  await settled()
  assert.deepEqual(p.state(), DARK)
})

test("set to the theme the page is in opens no transition, and mends a drifted store", () => {
  const p = page("dark")
  p.theme.value = "light" // a host wrote the class and storage directly
  p.store.values.theme = "light"
  p.theme.set("dark")
  assert.equal(p.doc.transitions.length, 0)
  assert.deepEqual(p.state(), DARK)
  assert.equal(p.html.dataset.themeFlip, undefined)
})

test("set to the shown theme during its crossfade leaves the crossfade's attribute on", async () => {
  const p = page("dark")
  p.theme.set("light")
  p.doc.transitions[0].run()
  p.theme.set("light")
  assert.equal(p.html.dataset.themeFlip, "", "clearing it mid-crossfade would swap in the page motions")
  p.doc.transitions[0].finish()
  await settled()
  assert.equal(p.html.dataset.themeFlip, undefined)
})

test("set refuses anything but the two themes", () => {
  const p = page("dark")
  for (const bad of ["watermark", "", null, undefined]) p.theme.set(bad)
  assert.equal(p.doc.transitions.length, 0)
  assert.deepEqual(p.state(), DARK)
})

test("toggle reads the root's class, so a host's direct write counts", async () => {
  const p = page("dark")
  p.html.set.delete("dark") // logo_gallery's fallback, and hub theme_context
  p.theme.toggle()
  p.doc.transitions[0].finish()
  await settled()
  assert.deepEqual(p.state(), DARK)
})

test("registration installs theme and devMode from storage", () => {
  const Alpine = fakeAlpine()
  const html = root([]) // the pre-paint script left a light reader's root light
  registerStudioStores(Alpine, { storage: storage({ devMode: "true", theme: "light" }), root: html, later: () => {} })

  assert.equal(Alpine.store("devMode"), true)
  assert.equal(Alpine.store("theme").value, "light")
  assert.equal(Alpine.store("theme").isDark, false)

  Alpine.store("theme").toggle() // no document in env: the instant path
  assert.equal(Alpine.store("theme").value, "dark")
  assert.equal(Alpine.store("theme").isDark, true)
})

test("registration is idempotent: a second path leaves the first one's stores alone", () => {
  const Alpine = fakeAlpine()
  const env = { storage: storage(), root: root(["dark"]), later: () => {} }
  registerStudioStores(Alpine, env)
  const theme = Alpine.store("theme")
  Alpine.store("devMode", true) // a reader flipped it before the second path ran

  registerStudioStores(Alpine, env)
  assert.equal(Alpine.store("theme"), theme, "the theme store was replaced")
  assert.equal(Alpine.store("devMode"), true, "a false devMode overwrote the live value")
  assert.deepEqual(Alpine.writes, ["devMode", "theme", "devMode"])
})

test("a host's own store of the same name wins", () => {
  const Alpine = fakeAlpine()
  const hostTheme = { value: "host" }
  Alpine.store("theme", hostTheme)
  registerStudioStores(Alpine, { storage: storage(), root: root([]), later: () => {} })
  assert.equal(Alpine.store("theme"), hostTheme)
  assert.equal(Alpine.store("devMode"), false)
})

test("installing from both paths adds one alpine:init listener, which registers both stores", () => {
  const doc = fakeDocument()
  const win = { localStorage: storage(), setTimeout: () => {}, matchMedia: () => ({ matches: false }), getComputedStyle: () => ({}) }
  installStudioStores(doc, win)
  installStudioStores(doc, win)
  assert.equal(doc.listeners["alpine:init"].length, 1)

  win.Alpine = fakeAlpine()
  doc.fire("alpine:init")
  assert.deepEqual(Object.keys(win.Alpine.stores).sort(), ["devMode", "theme"])
  assert.equal(win.Alpine.store("theme").isDark, true)
})

test("a second document gets its own listener", () => {
  const win = { localStorage: storage(), setTimeout: () => {} }
  const first = fakeDocument()
  const second = fakeDocument()
  installStudioStores(first, win)
  installStudioStores(second, win)
  assert.equal(second.listeners["alpine:init"].length, 1)
})
