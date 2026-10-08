// studio/link_sidebar: the open flag behind components/_link_sidebar
// ($store.sidebars.linkTreeOpen) and the document handlers that flip it.
//
// The panel's open and closed state is the store flag alone, through x-show and
// x-transition. Nothing here sets `display`: an inline display:none makes
// Alpine skip the enter transition, and the panel pops instead of sliding.
//
// The partial renders markup only, plus one anchor for its controller:
//
//   <template data-studio-controller="link-sidebar"></template>
//
// WHEN THE STORE REGISTERS. The panel's x-show reads $store.sidebars as Alpine
// starts, before Stimulus connects a controller, so the flag is registered from
// this module, on a page that renders the panel and only there:
//
//   1. alpine:init, on a full load.
//   2. turbo:before-render, for the incoming body, before Alpine sees it.
//   3. turbo:load, and the controller's connect(), for markup that arrived any
//      other way.
//
// A host with its own `sidebars` store keeps it and gains the flag
// (turf-monster's holds gearOpen).
//
// THE DOCUMENT HANDLERS run in the capture phase, so the trigger works for a
// click that lands before Alpine has bound it. They are installed once, on
// every page, and do nothing where no link sidebar is rendered.
//
// WHY THIS IS ITS OWN ENTRY POINT. layouts/studio/_head imports this module by
// its own nonced module tag as well as through the boot graph, like
// studio/alpine_stores. It imports nothing, and
// test/javascript/link_sidebar.test.mjs holds it to that.

// The panels components/_link_sidebar renders: the scope of every click this
// module claims.
export const LINK_SIDEBAR_PANELS = "#studio-link-sidebar, #studio-link-sidebar-mobile"
// A control that may toggle the sidebar, when its aria-controls names the panel.
export const LINK_SIDEBAR_TRIGGERS = "[data-link-sidebar-trigger], [data-username-display], [data-profile-image-toggle]"
const CONTROLS_PANEL = '[aria-controls~="studio-link-sidebar"]'
const CLOSE_BUTTON = "[data-link-sidebar-close]"

// Registers the flag: a new `sidebars` store, or one more key on the host's.
// Null before Alpine exists.
export function ensureLinkSidebarStore(Alpine) {
  if (!Alpine || typeof Alpine.store !== "function") return null

  const sidebars = Alpine.store("sidebars")
  if (!sidebars) {
    Alpine.store("sidebars", { linkTreeOpen: false })
    return Alpine.store("sidebars")
  }
  if (typeof sidebars.linkTreeOpen === "undefined") sidebars.linkTreeOpen = false
  return sidebars
}

// The store as it stands. Reading it registers nothing, so a page with no link
// sidebar gains no store from a click or a key press.
export function linkSidebarStore(Alpine) {
  if (!Alpine || typeof Alpine.store !== "function") return null
  return Alpine.store("sidebars") || null
}

export function closeLinkSidebar(Alpine) {
  const sidebars = linkSidebarStore(Alpine)
  if (sidebars && sidebars.linkTreeOpen) sidebars.linkTreeOpen = false
}

export function rendersLinkSidebar(root) {
  return !!(root && typeof root.querySelector === "function" && root.querySelector(LINK_SIDEBAR_PANELS))
}

// Path 1, 2 and 3 above: the flag for a document or body that renders the panel.
export function registerLinkSidebar(Alpine, root) {
  return rendersLinkSidebar(root) ? ensureLinkSidebarStore(Alpine) : null
}

// What a click on `target` means to the link sidebar:
//
//   "close"   the close button of one of ITS panels. components/_sidebar_panel
//             is shared and stamps every panel's close button
//             data-link-sidebar-close, so the button counts only inside a panel
//             this component renders; another panel's is left to that panel.
//   "toggle"  a trigger whose aria-controls names the panel.
//   "inside"  anywhere else in one of its panels.
//   "outside" the rest of the page.
export function clickIntent(target) {
  if (!target || typeof target.closest !== "function") return "outside"

  const closeButton = target.closest(CLOSE_BUTTON)
  if (closeButton && closeButton.closest(LINK_SIDEBAR_PANELS)) return "close"

  const trigger = target.closest(LINK_SIDEBAR_TRIGGERS)
  if (trigger && trigger.matches(CONTROLS_PANEL)) return "toggle"

  return target.closest(LINK_SIDEBAR_PANELS) ? "inside" : "outside"
}

const claim = (event) => {
  event.preventDefault()
  event.stopPropagation()
  event.stopImmediatePropagation()
}

// The capture-phase click. A claimed click reaches no other listener, so the
// trigger's own Alpine @click cannot toggle the flag a second time.
export function handleLinkSidebarClick(event, Alpine) {
  const intent = clickIntent(event.target)

  if (intent === "close") {
    claim(event)
    closeLinkSidebar(Alpine)
    return intent
  }

  if (intent === "toggle") {
    const sidebars = ensureLinkSidebarStore(Alpine)
    if (!sidebars) return null
    claim(event)
    sidebars.linkTreeOpen = !sidebars.linkTreeOpen
    return intent
  }

  if (intent === "outside") closeLinkSidebar(Alpine)
  return intent
}

export function handleLinkSidebarKeydown(event, Alpine) {
  if (event.key === "Escape") closeLinkSidebar(Alpine)
}

const installed = new WeakSet()

// Once per window: a second call adds no second listener.
export function installLinkSidebar({ win, doc } = {}) {
  const host = win || globalThis
  const root = doc || host.document
  if (!root || typeof root.addEventListener !== "function") return false
  if (installed.has(host)) return false
  installed.add(host)

  const register = () => registerLinkSidebar(host.Alpine, root)
  root.addEventListener("alpine:init", register)
  root.addEventListener("turbo:load", register)
  root.addEventListener("turbo:before-render", (event) => {
    registerLinkSidebar(host.Alpine, event.detail && event.detail.newBody)
  })
  // A page restored from Turbo's cache or the bfcache comes back closed.
  root.addEventListener("turbo:before-cache", () => closeLinkSidebar(host.Alpine))
  host.addEventListener("pageshow", (event) => { if (event.persisted) closeLinkSidebar(host.Alpine) })
  root.addEventListener("click", (event) => handleLinkSidebarClick(event, host.Alpine), true)
  root.addEventListener("keydown", (event) => handleLinkSidebarKeydown(event, host.Alpine), true)

  // Alpine already started (a host that loads it ahead of the module tags).
  if (host.Alpine && host.Alpine.version) register()
  return true
}

if (typeof window !== "undefined") installLinkSidebar({ win: window, doc: document })
