// [unit] studio/link_sidebar: the `sidebars` store's linkTreeOpen flag, what a
// click means to the link sidebar, and the handlers and registration the module
// installs. Loaded from source as a data: module, like modal_host.test.mjs; the
// module imports nothing, which is what lets the head load it when
// studio/application does not.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/link_sidebar.js", import.meta.url), "utf8")
const {
  LINK_SIDEBAR_PANELS, LINK_SIDEBAR_TRIGGERS, ensureLinkSidebarStore, linkSidebarStore, closeLinkSidebar,
  rendersLinkSidebar, registerLinkSidebar, clickIntent, handleLinkSidebarClick, handleLinkSidebarKeydown,
  installLinkSidebar
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

// Alpine.store as Alpine has it: one argument reads, two register.
const fakeAlpine = (stores = {}) => ({
  stores,
  version: "3.16.1",
  store(name, value) {
    if (value === undefined) return stores[name]
    stores[name] = value
  }
})

// A node in a small tree. `is` lists the selectors the node itself matches;
// closest() walks the parents, as the DOM's does.
const el = (is = [], parent = null) => ({
  is,
  parent,
  matches(selector) { return selector.split(",").map((s) => s.trim()).some((s) => this.is.includes(s)) },
  closest(selector) {
    for (let node = this; node; node = node.parent) if (node.matches(selector)) return node
    return null
  }
})

const PANEL = "#studio-link-sidebar"
const MOBILE_PANEL = "#studio-link-sidebar-mobile"
const CLOSE = "[data-link-sidebar-close]"
const TRIGGER = "[data-link-sidebar-trigger]"
const CONTROLS = '[aria-controls~="studio-link-sidebar"]'

const clickOn = (target) => {
  const event = { target, calls: [] }
  for (const name of ["preventDefault", "stopPropagation", "stopImmediatePropagation"]) {
    event[name] = () => event.calls.push(name)
  }
  return event
}

const fakeDocument = ({ panel = true } = {}) => {
  const listeners = {}
  return {
    listeners,
    panel,
    addEventListener(name, fn, capture) { (listeners[name] = listeners[name] || []).push({ fn, capture }) },
    fire(name, event = {}) { (listeners[name] || []).forEach(({ fn }) => fn(event)) },
    querySelector(selector) { return selector === LINK_SIDEBAR_PANELS && this.panel ? {} : null }
  }
}

const fakeWindow = (extra = {}) => {
  const listeners = {}
  return {
    listeners,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    fire(name, event = {}) { (listeners[name] || []).forEach((fn) => fn(event)) },
    ...extra
  }
}

test("the module imports nothing, so its own module tag survives a failed boot", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("the selectors name the two panels and the three trigger kinds", () => {
  assert.equal(LINK_SIDEBAR_PANELS, "#studio-link-sidebar, #studio-link-sidebar-mobile")
  assert.equal(LINK_SIDEBAR_TRIGGERS, "[data-link-sidebar-trigger], [data-username-display], [data-profile-image-toggle]")
})

test("ensure registers a closed flag, once", () => {
  const Alpine = fakeAlpine()
  const sidebars = ensureLinkSidebarStore(Alpine)

  assert.deepEqual(sidebars, { linkTreeOpen: false })
  sidebars.linkTreeOpen = true
  assert.equal(ensureLinkSidebarStore(Alpine), sidebars, "the store is not replaced")
  assert.equal(sidebars.linkTreeOpen, true, "and an open sidebar is not closed by a second registration")
})

test("ensure adds the flag to a host's own sidebars store and keeps the host's keys", () => {
  const Alpine = fakeAlpine({ sidebars: { gearOpen: true } })

  const sidebars = ensureLinkSidebarStore(Alpine)

  assert.deepEqual(sidebars, { gearOpen: true, linkTreeOpen: false })
})

test("before Alpine exists nothing registers and nothing throws", () => {
  assert.equal(ensureLinkSidebarStore(undefined), null)
  assert.equal(linkSidebarStore(undefined), null)
  assert.doesNotThrow(() => closeLinkSidebar(undefined))
  assert.equal(handleLinkSidebarClick(clickOn(el([TRIGGER, CONTROLS])), undefined), null)
})

test("close shuts an open sidebar and registers nothing on a page without one", () => {
  const open = fakeAlpine({ sidebars: { linkTreeOpen: true } })
  closeLinkSidebar(open)
  assert.equal(open.stores.sidebars.linkTreeOpen, false)

  const bare = fakeAlpine()
  closeLinkSidebar(bare)
  assert.deepEqual(bare.stores, {}, "no store appears on a page with no link sidebar")

  const turf = fakeAlpine({ sidebars: { gearOpen: true } })
  closeLinkSidebar(turf)
  assert.deepEqual(turf.stores.sidebars, { gearOpen: true }, "a host's store is left as it was")
})

test("the flag registers only for a document or body that renders the panel", () => {
  const withPanel = fakeDocument()
  const without = fakeDocument({ panel: false })

  assert.equal(rendersLinkSidebar(withPanel), true)
  assert.equal(rendersLinkSidebar(without), false)
  assert.equal(rendersLinkSidebar(null), false)

  const Alpine = fakeAlpine()
  assert.equal(registerLinkSidebar(Alpine, without), null)
  assert.deepEqual(Alpine.stores, {})
  assert.deepEqual(registerLinkSidebar(Alpine, withPanel), { linkTreeOpen: false })
})

test("click intent: the close button of the sidebar's own panels, desktop and mobile", () => {
  const desktop = el([PANEL])
  const mobile = el([MOBILE_PANEL])

  assert.equal(clickIntent(el([], el([CLOSE], desktop))), "close", "a click on the button's icon")
  assert.equal(clickIntent(el([CLOSE], mobile)), "close")
})

test("click intent: another panel's close button is not the sidebar's", () => {
  const hostPanel = el(["#lab-host-panel"])
  assert.equal(clickIntent(el([CLOSE], hostPanel)), "outside")
})

test("click intent: a trigger toggles only when its aria-controls names the panel", () => {
  assert.equal(clickIntent(el([], el([TRIGGER, CONTROLS]))), "toggle")
  assert.equal(clickIntent(el(["[data-username-display]", CONTROLS])), "toggle")
  assert.equal(clickIntent(el(["[data-profile-image-toggle]", CONTROLS])), "toggle")
  assert.equal(clickIntent(el([TRIGGER])), "outside", "a trigger for some other panel")
  assert.equal(clickIntent(el([CONTROLS])), "outside", "aria-controls alone is not a trigger")
})

test("click intent: inside a panel, outside every panel, and no target at all", () => {
  assert.equal(clickIntent(el([], el([PANEL]))), "inside")
  assert.equal(clickIntent(el([], el([MOBILE_PANEL]))), "inside")
  assert.equal(clickIntent(el([], el(["main"]))), "outside")
  assert.equal(clickIntent(null), "outside")
  assert.equal(clickIntent({}), "outside", "a target with no closest(), such as the document")
})

test("a click on the trigger toggles the flag and is claimed whole", () => {
  const Alpine = fakeAlpine()
  const first = clickOn(el([TRIGGER, CONTROLS]))

  assert.equal(handleLinkSidebarClick(first, Alpine), "toggle")
  assert.equal(Alpine.stores.sidebars.linkTreeOpen, true, "the trigger registers the flag it needs")
  assert.deepEqual(first.calls, ["preventDefault", "stopPropagation", "stopImmediatePropagation"],
                   "so the trigger's own @click cannot toggle it back")

  handleLinkSidebarClick(clickOn(el([TRIGGER, CONTROLS])), Alpine)
  assert.equal(Alpine.stores.sidebars.linkTreeOpen, false)
})

test("a click on the sidebar's close button closes it and is claimed", () => {
  const Alpine = fakeAlpine({ sidebars: { linkTreeOpen: true } })
  const event = clickOn(el([CLOSE], el([PANEL])))

  assert.equal(handleLinkSidebarClick(event, Alpine), "close")
  assert.equal(Alpine.stores.sidebars.linkTreeOpen, false)
  assert.equal(event.calls.length, 3)
})

test("a click on another panel's close button is left to that panel", () => {
  const Alpine = fakeAlpine({ sidebars: { linkTreeOpen: false } })
  const event = clickOn(el([CLOSE], el(["#lab-host-panel"])))

  handleLinkSidebarClick(event, Alpine)

  assert.deepEqual(event.calls, [], "the click still reaches the host panel's own handler")
  assert.equal(Alpine.stores.sidebars.linkTreeOpen, false)
})

test("a click outside closes an open sidebar; a click inside leaves it open; neither is claimed", () => {
  const Alpine = fakeAlpine({ sidebars: { linkTreeOpen: true } })

  const inside = clickOn(el([], el([PANEL])))
  assert.equal(handleLinkSidebarClick(inside, Alpine), "inside")
  assert.equal(Alpine.stores.sidebars.linkTreeOpen, true)
  assert.deepEqual(inside.calls, [], "a link in the panel still navigates")

  const outside = clickOn(el([], el(["main"])))
  assert.equal(handleLinkSidebarClick(outside, Alpine), "outside")
  assert.equal(Alpine.stores.sidebars.linkTreeOpen, false)
  assert.deepEqual(outside.calls, [])
})

test("a click on a page with no link sidebar registers no store", () => {
  const Alpine = fakeAlpine()
  handleLinkSidebarClick(clickOn(el([], el(["main"]))), Alpine)
  assert.deepEqual(Alpine.stores, {})
})

test("Escape closes the sidebar; another key does not", () => {
  const Alpine = fakeAlpine({ sidebars: { linkTreeOpen: true } })

  handleLinkSidebarKeydown({ key: "Enter" }, Alpine)
  assert.equal(Alpine.stores.sidebars.linkTreeOpen, true)
  handleLinkSidebarKeydown({ key: "Escape" }, Alpine)
  assert.equal(Alpine.stores.sidebars.linkTreeOpen, false)
})

test("install: the flag registers on alpine:init for a page that renders the panel", () => {
  const doc = fakeDocument()
  const win = fakeWindow()

  assert.equal(installLinkSidebar({ win, doc }), true)
  assert.equal(installLinkSidebar({ win, doc }), false, "a second install adds no second listener")
  assert.equal(doc.listeners.click.length, 1)
  assert.equal(doc.listeners.click[0].capture, true, "the click handler runs in the capture phase")
  assert.equal(doc.listeners.keydown[0].capture, true)

  win.Alpine = fakeAlpine()
  doc.fire("alpine:init")
  assert.deepEqual(win.Alpine.stores.sidebars, { linkTreeOpen: false })
})

test("install: a page without the panel gets the handlers and no store", () => {
  const doc = fakeDocument({ panel: false })
  const win = fakeWindow({ Alpine: fakeAlpine() })
  installLinkSidebar({ win, doc })

  doc.fire("alpine:init")
  doc.fire("turbo:load")
  doc.fire("keydown", { key: "Escape" })
  doc.fire("click", clickOn(el([], el(["main"]))))

  assert.deepEqual(win.Alpine.stores, {})
})

test("install: a Turbo visit registers the flag from the incoming body, before it renders", () => {
  const doc = fakeDocument({ panel: false })
  const win = fakeWindow({ Alpine: fakeAlpine() })
  installLinkSidebar({ win, doc })

  doc.fire("turbo:before-render", { detail: { newBody: fakeDocument({ panel: false }) } })
  assert.deepEqual(win.Alpine.stores, {})
  doc.fire("turbo:before-render", { detail: { newBody: fakeDocument() } })
  assert.deepEqual(win.Alpine.stores.sidebars, { linkTreeOpen: false })
})

test("install: turbo:load registers the flag when nothing earlier did", () => {
  const doc = fakeDocument()
  const win = fakeWindow()
  installLinkSidebar({ win, doc })
  win.Alpine = fakeAlpine()

  doc.fire("turbo:load")

  assert.deepEqual(win.Alpine.stores.sidebars, { linkTreeOpen: false })
})

test("install: Alpine already started registers at once", () => {
  const win = fakeWindow({ Alpine: fakeAlpine() })
  installLinkSidebar({ win, doc: fakeDocument() })
  assert.deepEqual(win.Alpine.stores.sidebars, { linkTreeOpen: false })
})

test("install: the sidebar closes before Turbo caches the page and on a bfcache restore", () => {
  const doc = fakeDocument()
  const win = fakeWindow({ Alpine: fakeAlpine() })
  installLinkSidebar({ win, doc })
  const sidebars = win.Alpine.stores.sidebars

  sidebars.linkTreeOpen = true
  doc.fire("turbo:before-cache")
  assert.equal(sidebars.linkTreeOpen, false)

  sidebars.linkTreeOpen = true
  win.fire("pageshow", { persisted: false })
  assert.equal(sidebars.linkTreeOpen, true, "an ordinary load is not a restore")
  win.fire("pageshow", { persisted: true })
  assert.equal(sidebars.linkTreeOpen, false)
})

test("install: the document handlers toggle, close on Escape and close on an outside click", () => {
  const doc = fakeDocument()
  const win = fakeWindow({ Alpine: fakeAlpine() })
  installLinkSidebar({ win, doc })
  const sidebars = win.Alpine.stores.sidebars

  doc.fire("click", clickOn(el([TRIGGER, CONTROLS])))
  assert.equal(sidebars.linkTreeOpen, true)
  doc.fire("keydown", { key: "Escape" })
  assert.equal(sidebars.linkTreeOpen, false)

  doc.fire("click", clickOn(el([TRIGGER, CONTROLS])))
  doc.fire("click", clickOn(el([], el(["main"]))))
  assert.equal(sidebars.linkTreeOpen, false)
})

test("install: no document, no install", () => {
  assert.equal(installLinkSidebar({ win: fakeWindow(), doc: null }), false)
})
