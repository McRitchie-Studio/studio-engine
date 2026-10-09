// [unit] studio/geo_settings: the client mirror of Studio::Geo.blocked?, and the
// repaint the geo manager makes from its own checkboxes. Loaded from source as
// a data: module, like nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/geo_settings.js", import.meta.url), "utf8")
const {
  geoBlocked, visitorOf, rulesOf, paintGeo, COUNTRY_BOXES, SUBDIVISION_BOXES, ENABLED_BOX
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

const colorado = { country: "US", subdivision: "CO", home: "US", failClosed: true }
const rules = (over = {}) => ({ enabled: true, countries: [], subdivisions: [], ...over })

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("a gate that is off blocks nobody, whatever it lists", () => {
  assert.equal(geoBlocked(rules({ enabled: false, countries: ["US"], subdivisions: ["CO"] }), colorado), false)
})

test("a banned country blocks its visitors", () => {
  assert.equal(geoBlocked(rules({ countries: ["US"] }), colorado), true)
  assert.equal(geoBlocked(rules({ countries: ["CA"] }), colorado), false)
})

test("a banned subdivision blocks only a home-country visitor in it", () => {
  assert.equal(geoBlocked(rules({ subdivisions: ["CO"] }), colorado), true)
  assert.equal(geoBlocked(rules({ subdivisions: ["WA"] }), colorado), false)
  assert.equal(geoBlocked(rules({ subdivisions: ["CO"] }), { ...colorado, country: "CA" }), false,
               "another country's CO is not the home country's")
})

test("fail closed: a home-country visitor with no region is blocked once region rules exist", () => {
  const unknown = { ...colorado, subdivision: "" }
  assert.equal(geoBlocked(rules({ subdivisions: ["WA"] }), unknown), true)
  assert.equal(geoBlocked(rules(), unknown), false, "no region rules, nothing to fail closed on")
  assert.equal(geoBlocked(rules({ subdivisions: ["WA"] }), { ...unknown, failClosed: false }), false)
  assert.equal(geoBlocked(rules({ subdivisions: ["WA"] }), { ...unknown, country: "CA" }), false,
               "a visitor outside the home country is never failed closed")
  assert.equal(geoBlocked(rules({ subdivisions: ["WA"] }), colorado), false, "a known region is judged on itself")
})

// A page with checkboxes, summary rows and count nodes; and a document with
// badges and a root.
function box(value, checked, art = true) {
  const node = {
    value, checked,
    closest: (selector) => (selector === "label" ? {
      querySelector: () => (art ? { cloneNode: () => ({ art: value }) } : null)
    } : null)
  }
  return node
}

function summaryRow() {
  const row = {
    children: [],
    querySelectorAll(selector) {
      return selector === ".geo-chip" ? this.children.filter((c) => c.chip).map((chip) => ({
        remove: () => { row.children = row.children.filter((c) => c !== chip) }
      })) : []
    },
    querySelector: () => null,
    insertBefore(chip) { this.children.push(chip) }
  }
  return row
}

function fakePage({ enabled = true, countries = [], subdivisions = [], dataset }) {
  const rows = { states: summaryRow(), countries: summaryRow() }
  const counts = { states: [{}, {}], countries: [{}] }
  return {
    dataset, rows, counts,
    querySelector(selector) {
      if (selector === ENABLED_BOX) return { checked: enabled }
      const row = selector.match(/^\[data-geo-summary="(\w+)"\]$/)
      return row ? rows[row[1]] : null
    },
    querySelectorAll(selector) {
      const count = selector.match(/^\[data-geo-summary-count="(\w+)"\]$/)
      if (count) return counts[count[1]]
      const checked = selector.endsWith(":checked")
      const base = checked ? selector.slice(0, -":checked".length) : selector
      const all = base === COUNTRY_BOXES ? countries : base === SUBDIVISION_BOXES ? subdivisions : []
      return checked ? all.filter((b) => b.checked) : all
    }
  }
}

function fakeDocument(badges = []) {
  const root = { attributes: {}, setAttribute(name, value) { this.attributes[name] = value } }
  return {
    documentElement: root,
    createElement: () => ({ chip: true, nodes: [], appendChild(node) { this.nodes.push(node) } }),
    createTextNode: (text) => ({ text }),
    querySelectorAll: (selector) => (selector === "[data-geo-badge]" ? badges : [])
  }
}

const badge = (country, subdivision) => ({
  dataset: { country, subdivision },
  attributes: {},
  setAttribute(name, value) { this.attributes[name] = value }
})

const dataset = { geoHome: "US", geoCountry: "US", geoSubdivision: "CO", geoFailClosed: "true" }

test("the visitor is read from the page's data attributes", () => {
  assert.deepEqual(visitorOf({ dataset }), colorado)
  assert.equal(visitorOf({ dataset: { ...dataset, geoFailClosed: "false" } }).failClosed, false)
})

test("the rules are read from the checked boxes", () => {
  const page = fakePage({ dataset, countries: [box("CA", true), box("MX", false)], subdivisions: [box("WA", true)] })
  assert.deepEqual(rulesOf(page), { enabled: true, countries: ["CA"], subdivisions: ["WA"] })
})

test("paint: ticking the visitor's own region blocks the root and the visitor's own badge only", () => {
  const mine = badge("US", "CO")
  const specimen = badge("US", "WA")
  const doc = fakeDocument([mine, specimen])
  const page = fakePage({ dataset, subdivisions: [box("WA", true), box("CO", true), box("AZ", false)] })

  assert.equal(paintGeo(page, doc), true)

  assert.equal(doc.documentElement.attributes["data-geo-preview"], "blocked")
  assert.equal(mine.attributes["data-blocked"], "true")
  assert.deepEqual(specimen.attributes, {}, "a badge for another place keeps what it was given")
})

test("paint: the summary lists the checked squares in order, with their flag, and both counts agree", () => {
  const doc = fakeDocument()
  const page = fakePage({ dataset, subdivisions: [box("WA", true), box("CO", true), box("AZ", false)], countries: [box("CA", true, false)] })

  assert.equal(paintGeo(page, doc), true)

  const states = page.rows.states.children
  assert.deepEqual(states.map((chip) => chip.nodes), [[{ art: "CO" }, { text: "CO" }], [{ art: "WA" }, { text: "WA" }]])
  assert.deepEqual(page.counts.states.map((el) => el.textContent), [2, 2])
  assert.deepEqual(page.rows.countries.children.map((chip) => chip.nodes), [[{ text: "CA" }]], "a square with no artwork still lists")
  assert.deepEqual(page.counts.countries.map((el) => el.textContent), [1])
})

test("paint: a second paint replaces the chips and does not add to them", () => {
  const doc = fakeDocument()
  const boxes = [box("CO", true), box("WA", true)]
  const page = fakePage({ dataset, subdivisions: boxes })

  paintGeo(page, doc)
  boxes[1].checked = false
  paintGeo(page, doc)

  assert.equal(page.rows.states.children.length, 1)
  assert.deepEqual(page.counts.states.map((el) => el.textContent), [1, 1])
})

test("paint: with the gate off the visitor is allowed", () => {
  const mine = badge("US", "CO")
  const doc = fakeDocument([mine])
  const page = fakePage({ dataset, enabled: false, subdivisions: [box("CO", true)] })

  assert.equal(paintGeo(page, doc), false)
  assert.equal(doc.documentElement.attributes["data-geo-preview"], "allowed")
  assert.equal(mine.attributes["data-blocked"], "false")
})
