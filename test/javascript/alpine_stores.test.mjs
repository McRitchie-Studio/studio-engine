// [unit] studio/alpine_stores: the theme and devMode stores, the theme value
// and toggle behind them, and the registration that runs from two paths. Loaded
// from source as a data: module, like head_chrome.test.mjs; the module imports
// nothing, which is what lets it load when studio/application does not.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/alpine_stores.js", import.meta.url), "utf8")
const { storedTheme, toggleTheme, registerStudioStores, installStudioStores } =
  await import(`data:text/javascript,${encodeURIComponent(source)}`)

const storage = (initial = {}) => {
  const values = { ...initial }
  return { values, getItem: (k) => (k in values ? values[k] : null), setItem: (k, v) => { values[k] = String(v) } }
}

const root = (classes) => {
  const set = new Set(classes)
  return {
    set,
    classList: {
      add: (c) => set.add(c),
      remove: (c) => set.delete(c),
      contains: (c) => set.has(c),
      toggle: (c) => (set.has(c) ? (set.delete(c), false) : (set.add(c), true))
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

test("the stored theme is dark unless the reader chose light", () => {
  assert.equal(storedTheme(storage()), "dark")
  assert.equal(storedTheme(storage({ theme: "light" })), "light")
})

test("toggling flips the root, stores the result, and clears the transition later", () => {
  const html = root(["dark"])
  const store = storage({ theme: "dark" })
  const later = []
  assert.equal(toggleTheme(html, store, (fn, ms) => later.push([fn, ms])), "light")
  assert.equal(html.set.has("dark"), false)
  assert.equal(store.values.theme, "light")
  assert.equal(html.set.has("theme-transition"), true, "the transition class is on while the colours move")
  assert.equal(later[0][1], 300)
  later[0][0]()
  assert.equal(html.set.has("theme-transition"), false)

  assert.equal(toggleTheme(html, store, () => {}), "dark")
  assert.equal(store.values.theme, "dark")
})

test("registration installs theme and devMode from storage", () => {
  const Alpine = fakeAlpine()
  const html = root([]) // the pre-paint script left a light reader's root light
  registerStudioStores(Alpine, { storage: storage({ devMode: "true", theme: "light" }), root: html, later: () => {} })

  assert.equal(Alpine.store("devMode"), true)
  assert.equal(Alpine.store("theme").value, "light")
  assert.equal(Alpine.store("theme").isDark, false)

  Alpine.store("theme").toggle()
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
  const win = { localStorage: storage(), setTimeout: () => {} }
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
