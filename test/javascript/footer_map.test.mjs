// [unit] studio/footer_map: what a map element asks for, and the install's
// order: nothing before `load`, nothing until the map nears the viewport,
// Leaflet fetched once, the fallback restored before a Turbo snapshot. Loaded
// from source as a data: module, like nav_collapse.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/footer_map.js", import.meta.url), "utf8")
const { MAPS, TILES, mapOptions, installFooterMaps } = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("only an engine-rendered map is armed, and the tiles are keyless", () => {
  assert.equal(MAPS, "[data-footer-map][data-leaflet-js]")
  assert.equal(TILES, "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
})

test("map options: the point, the zoom with its default, and the controls", () => {
  assert.deepEqual(mapOptions({ lat: "39.7392", lng: "-104.9903", zoom: "13", controls: "true" }),
                   { at: [39.7392, -104.9903], zoom: 13, zoomControl: true })
  assert.deepEqual(mapOptions({ lat: "1", lng: "2", zoom: "", controls: "false" }), { at: [1, 2], zoom: 15, zoomControl: false })
  assert.equal(mapOptions({ lat: "", lng: "2" }), null)
  assert.equal(mapOptions({ lat: "1", lng: "north" }), null)
})

class Watcher {
  static all = []
  constructor(callback, options) { this.callback = callback; this.options = options; this.live = true; Watcher.all.push(this) }
  observe(target) { this.target = target }
  disconnect() { this.live = false }
}

function fakeLeaflet() {
  const calls = { maps: [], removed: 0 }
  const layer = { addTo() { return this } }
  return {
    calls,
    Browser: { mobile: false },
    map(el, options) {
      const map = {
        options, handlers: {},
        attributionControl: { setPrefix() {} },
        scrollWheelZoom: { on: false, enable() { this.on = true }, disable() { this.on = false } },
        on(name, fn) { this.handlers[name] = fn },
        remove() { calls.removed++ }
      }
      calls.maps.push(map)
      return map
    },
    tileLayer: () => layer,
    marker: () => layer,
    divIcon: (options) => options
  }
}

function fakeWindow(extra = {}) {
  const listeners = {}
  return {
    listeners,
    IntersectionObserver: Watcher,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    fire(name) { (listeners[name] || []).forEach((fn) => fn()) },
    ...extra
  }
}

function fakeDocument(maps, readyState = "complete") {
  const listeners = {}
  const head = { children: [], appendChild(node) { this.children.push(node) } }
  return {
    listeners, head, readyState, maps,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    fire(name) { (listeners[name] || []).forEach((fn) => fn()) },
    querySelector(selector) {
      return selector === "link[data-studio-leaflet]" ? head.children.find((n) => n.tag === "link") || null : null
    },
    querySelectorAll: (selector) => (selector === MAPS ? maps : []),
    createElement: (tag) => ({ tag, attrs: {}, setAttribute(name, value) { this.attrs[name] = value }, remove() { this.removed = true } })
  }
}

function mapElement() {
  const fallback = { removed: 0, remove() { this.removed++ } }
  const el = {
    fallback, appended: [],
    isConnected: true,
    dataset: { lat: "39.7", lng: "-104.9", zoom: "14", controls: "true", leafletJs: "/assets/leaflet.js", leafletCss: "/assets/leaflet.css" },
    querySelector(selector) { return selector === ".ftr-map-fallback" && !this.mounted ? fallback : null },
    appendChild(node) { this.appended.push(node) }
  }
  return el
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

test("install: nothing is watched before `load`, and it installs once", () => {
  Watcher.all = []
  const win = fakeWindow()
  const doc = fakeDocument([mapElement()], "interactive")

  const arm = installFooterMaps(win, doc)
  assert.equal(win.__studioFooterMapsArmed, true)
  assert.equal(Watcher.all.length, 0)
  assert.equal(installFooterMaps(win, doc), arm, "a second install answers the same arm and adds no listener")
  assert.equal(doc.listeners["turbo:load"].length, 1)

  doc.readyState = "complete"
  win.fire("load")
  assert.equal(Watcher.all.length, 1)
  assert.equal(Watcher.all[0].options.rootMargin, "400px")
  assert.equal(doc.head.children.length, 0, "Leaflet is not fetched until the map nears the viewport")
})

test("near the viewport: the stylesheet and Leaflet are fetched once, and the map mounts over its fallback", async () => {
  Watcher.all = []
  const win = fakeWindow()
  const el = mapElement()
  const second = mapElement()
  const doc = fakeDocument([el, second])
  installFooterMaps(win, doc)

  Watcher.all[0].callback([{ isIntersecting: true }])
  Watcher.all[1].callback([{ isIntersecting: true }])
  const script = doc.head.children.find((n) => n.tag === "script")
  assert.deepEqual(doc.head.children.map((n) => n.tag), ["link", "script"], "two maps, one stylesheet and one script")
  assert.equal(script.src, "/assets/leaflet.js")
  assert.equal(doc.head.children[0].href, "/assets/leaflet.css")

  win.L = fakeLeaflet()
  script.onload()
  await settle()

  assert.equal(win.L.calls.maps.length, 2)
  assert.deepEqual(win.L.calls.maps[0].options.center, [39.7, -104.9])
  assert.equal(win.L.calls.maps[0].options.zoom, 14)
  assert.equal(win.L.calls.maps[0].options.scrollWheelZoom, false)
  assert.equal(win.L.calls.maps[0].options.dragging, true)
  assert.equal(el.fallback.removed, 1)
  assert.equal(el.__footerMap, win.L.calls.maps[0])

  // Page scroll stays page scroll until the visitor commits to the map.
  el.__footerMap.handlers.click()
  assert.equal(el.__footerMap.scrollWheelZoom.on, true)
  el.__footerMap.handlers.mouseout()
  assert.equal(el.__footerMap.scrollWheelZoom.on, false)
})

test("a phone gets no one-finger drag", async () => {
  Watcher.all = []
  const leaflet = fakeLeaflet()
  leaflet.Browser.mobile = true
  const win = fakeWindow({ L: leaflet })
  installFooterMaps(win, fakeDocument([mapElement()]))

  Watcher.all[0].callback([{ isIntersecting: true }])
  await settle()

  assert.equal(leaflet.calls.maps[0].options.dragging, false)
  assert.equal(leaflet.calls.maps[0].options.touchZoom, true)
})

test("a failed Leaflet fetch leaves the fallback and is not remembered", async () => {
  Watcher.all = []
  const win = fakeWindow()
  const el = mapElement()
  const doc = fakeDocument([el])
  const arm = installFooterMaps(win, doc)

  Watcher.all[0].callback([{ isIntersecting: true }])
  const failed = doc.head.children.find((n) => n.tag === "script")
  failed.onerror()
  await settle()
  assert.equal(failed.removed, true)
  assert.equal(el.fallback.removed, 0, "the link is still the whole map")
  assert.equal(el.__footerMap, undefined)

  arm()
  Watcher.all[1].callback([{ isIntersecting: true }])
  assert.equal(doc.head.children.filter((n) => n.tag === "script").length, 2, "the next visit tries again")
})

test("before a Turbo snapshot the map is taken down and its fallback put back", async () => {
  Watcher.all = []
  const leaflet = fakeLeaflet()
  const win = fakeWindow({ L: leaflet })
  const el = mapElement()
  const doc = fakeDocument([el])
  installFooterMaps(win, doc)
  Watcher.all[0].callback([{ isIntersecting: true }])
  await settle()
  el.mounted = true

  doc.fire("turbo:before-cache")

  assert.equal(leaflet.calls.removed, 1)
  assert.equal(el.__footerMap, null)
  assert.deepEqual(el.appended, [el.fallback])
})

test("with no IntersectionObserver the map is fetched as soon as it is armed", () => {
  const win = fakeWindow({ IntersectionObserver: undefined })
  const doc = fakeDocument([mapElement()])
  installFooterMaps(win, doc)
  assert.deepEqual(doc.head.children.map((n) => n.tag), ["link", "script"])
})
