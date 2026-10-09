// [unit] studio/link_preview_card: what the live card shows for a field, and
// the repaint. Loaded from source as a data: module, like nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/link_preview_card.js", import.meta.url), "utf8")
const { cardText, fallbacksOf, paintCard } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("a typed value shows trimmed; a blank one shows the fallback", () => {
  assert.equal(cardText("  Hello  ", "Fallback"), "Hello")
  assert.equal(cardText("", "Fallback"), "Fallback")
  assert.equal(cardText("   ", "Fallback"), "Fallback", "whitespace is blank, as the server treats it")
  assert.equal(cardText(null, undefined), "")
})

test("the fallbacks come from the page, blank when it carries none", () => {
  assert.deepEqual(fallbacksOf({ dataset: { fallbackTitle: "App", fallbackDescription: "About" } }),
                   { title: "App", description: "About" })
  assert.deepEqual(fallbacksOf({ dataset: {} }), { title: "", description: "" })
})

function fakePage() {
  const nodes = { title: {}, description: {} }
  return {
    nodes,
    dataset: { fallbackTitle: "Studio", fallbackDescription: "The default words" },
    querySelector(selector) {
      const match = selector.match(/^\[data-link-preview-card-(\w+)\]$/)
      return match ? nodes[match[1]] || null : null
    }
  }
}

test("paint writes the input's own card node", () => {
  const page = fakePage()

  assert.equal(paintCard(page, { value: " A title ", dataset: { linkPreviewInput: "title" } }), "A title")
  assert.equal(page.nodes.title.textContent, "A title")
  assert.equal(page.nodes.description.textContent, undefined, "the other node is untouched")
})

test("paint falls back to that field's own fallback when it is cleared", () => {
  const page = fakePage()

  paintCard(page, { value: "", dataset: { linkPreviewInput: "description" } })

  assert.equal(page.nodes.description.textContent, "The default words")
})

test("paint ignores an input that feeds no card node", () => {
  const page = fakePage()

  assert.equal(paintCard(page, { value: "x", dataset: { linkPreviewInput: "image" } }), null)
  assert.equal(paintCard(page, { value: "x", dataset: {} }), null)
  assert.equal(paintCard(page, null), null)
})
