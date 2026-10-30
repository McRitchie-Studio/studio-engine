// [unit] components/_theme_toggle's :aria-pressed, evaluated against the real
// theme store (studio/alpine_stores.js), flips when the toggle runs
// (/tasks/engine-theme-toggle-labels). The expression is read from the partial
// itself, so a drift in either file fails here.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const partial = readFileSync(new URL("../../app/views/components/_theme_toggle.html.erb", import.meta.url), "utf8")
const storeSource = readFileSync(new URL("../../app/javascript/studio/alpine_stores.js", import.meta.url), "utf8")
const { registerStudioStores } = await import(`data:text/javascript,${encodeURIComponent(storeSource)}`)

const pressedExpr = partial.match(/:aria-pressed="([^"]+)"/)?.[1]
const clickExpr = partial.match(/@click="([^"]+)"/)?.[1]

const storage = (initial = {}) => {
  const values = { ...initial }
  return { getItem: (k) => (k in values ? values[k] : null), setItem: (k, v) => { values[k] = String(v) } }
}

const root = (classes) => {
  const set = new Set(classes)
  return {
    classList: {
      add: (c) => set.add(c),
      remove: (c) => set.delete(c),
      contains: (c) => set.has(c),
      toggle: (c) => (set.has(c) ? (set.delete(c), false) : (set.add(c), true))
    }
  }
}

// Alpine evaluates a binding with $store in scope; this does the same.
const evaluate = (expr, $store) => new Function("$store", `return (${expr})`)($store)

const mount = (theme) => {
  const stores = {}
  const Alpine = { store: (name, value) => (value === undefined ? stores[name] : (stores[name] = value)) }
  registerStudioStores(Alpine, { storage: storage({ theme }), root: root(theme === "dark" ? ["dark"] : []), later: () => {} })
  return stores
}

test("the partial binds aria-pressed and toggles the theme store", () => {
  assert.ok(pressedExpr, "no :aria-pressed binding on the toggle")
  assert.equal(clickExpr, "$store.theme.toggle()")
})

test("aria-pressed reads the string Alpine keeps, never a boolean it might drop", () => {
  for (const theme of ["dark", "light"]) {
    assert.equal(typeof evaluate(pressedExpr, mount(theme)), "string")
  }
})

test("aria-pressed is true in dark, false in light, and flips with each toggle", () => {
  const $store = mount("dark")
  assert.equal(evaluate(pressedExpr, $store), "true")

  evaluate(clickExpr, $store)
  assert.equal(evaluate(pressedExpr, $store), "false")

  evaluate(clickExpr, $store)
  assert.equal(evaluate(pressedExpr, $store), "true")
})

test("a light reader starts unpressed", () => {
  assert.equal(evaluate(pressedExpr, mount("light")), "false")
})
