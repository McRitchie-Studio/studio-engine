// studio/toast: the toast queue behind layouts/studio/_flash ($store.toasts).
//
// THE API IS THE `toast` WINDOW EVENT, from any page that renders the partial:
//
//   window.dispatchEvent(new CustomEvent("toast", { detail: {
//     type: "notice",            "notice" or "alert"
//     title: "Header",           "Success" / "Error" when omitted
//     message: "Subtext",
//     image: "/avatar.jpg",      an icon when omitted
//     dismissible: true,         the X button
//     buttons: [{ label, style, onclick }],
//     duration: 4000,            ms; 0 stays; 0 by default when it has buttons
//     blurShadow: false          a frosted halo behind the card
//   } }))
//
// The partial renders markup only. Its root carries
//
//   data-studio-controller="toast"
//   data-toast-initial-value='[{"type":"notice","message":"Saved"}]'
//
// and its Alpine bindings read $store.toasts. studio/controllers/toast_controller
// binds the queue to the element's lifetime.
//
// WHEN THE STORE REGISTERS. Alpine evaluates $store.toasts as it starts, before
// Stimulus connects a controller, so the store registers from this module on
// alpine:init, and only when Alpine has none (a host's own wins). The module
// also owns the `toast` listener and seeds each rendered root's flash messages
// (on alpine:initialized and on turbo:load), so a page whose Stimulus boot
// failed still shows its flash and its toasts. The controller seeds the same
// root on connect; an element is seeded once.
//
// WHY THIS IS ITS OWN ENTRY POINT. layouts/studio/_head imports this module by
// its own nonced module tag as well as through the boot graph, like
// studio/alpine_stores. It imports nothing, and test/javascript/toast.test.mjs
// holds it to that.

// The queue keeps this many toasts; the oldest leaves when one more arrives.
export const TOAST_CAP = 5
// A toast with no duration of its own, and no buttons, leaves after this long.
export const DEFAULT_DURATION_MS = 4000
// The leave transition's length (.toast-wrapper in layouts/studio/_flash): a
// dismissed toast is spliced out this long after it starts to shrink.
export const LEAVE_MS = 400
// Flash messages enter one after another: the first after SEED_DELAY_MS, each
// later one SEED_STAGGER_MS behind the last.
export const SEED_DELAY_MS = 50
export const SEED_STAGGER_MS = 100

export const TOAST_ROOT = '[data-studio-controller~="toast"]'
const INITIAL_ATTRIBUTE = "data-toast-initial-value"

// How long a toast stays. A toast with buttons waits for its reader.
export function toastDuration(detail) {
  const buttons = (detail && detail.buttons) || []
  if (detail && detail.duration != null) return detail.duration
  return buttons.length ? 0 : DEFAULT_DURATION_MS
}

// The queue entry for a `toast` event's detail. It enters invisible; the queue
// flips `visible` a tick later so the enter transition runs.
export function buildToast(detail, id) {
  const source = detail || {}
  const type = source.type || "notice"
  return {
    id,
    type,
    title: source.title || (type === "notice" ? "Success" : "Error"),
    message: source.message || "",
    image: source.image || null,
    dismissible: source.dismissible !== false,
    blurShadow: source.blurShadow || false,
    buttons: source.buttons || [],
    visible: false
  }
}

const visibleCount = (toasts) => toasts.filter((toast) => toast.visible).length

// The inline style of the toast at `index`: full, a collapsed peek strip under
// the newest, or hidden beyond the third.
export function toastStyle(toasts, index, expanded) {
  const toast = toasts[index]
  if (!toast || !toast.visible) {
    return "opacity: 0; transform: scale(0.7); max-height: 0; margin-top: 0; padding: 0; overflow: hidden;"
  }

  const collapsed = !expanded && visibleCount(toasts) > 1
  if (!collapsed || index === 0) {
    return "opacity: 1; transform: scale(1) translateY(0); margin-top: " + (index > 0 ? "0.35rem" : "0") + "; max-height: 20rem;"
  }

  if (index <= 2) {
    const scale = 1 - (index * 0.03)
    const opacity = 0.7 - ((index - 1) * 0.15)
    return "display: flex; flex-direction: column; justify-content: flex-end; transform: scale(" + scale +
      ") translateY(0); max-height: 0.5rem; overflow: hidden; opacity: " + opacity +
      "; margin-top: 0.15rem; pointer-events: auto; cursor: pointer;"
  }

  return "max-height: 0; overflow: hidden; opacity: 0; margin-top: 0; pointer-events: none;"
}

export function toastShadowClass(toasts, index) {
  if (visibleCount(toasts) <= 1) return "toast-shadow-all"
  return index === 0 ? "toast-shadow-top" : "toast-shadow-bottom"
}

// $store.toasts. Methods read `this`, so they run on Alpine's reactive proxy
// when Alpine calls them and on the plain object in a test.
export function createToastStore({ win } = {}) {
  const host = win || globalThis
  const later = (fn, ms) => host.setTimeout(fn, ms)
  const nextTick = (fn) => {
    const alpine = host.Alpine
    if (alpine && typeof alpine.nextTick === "function") alpine.nextTick(fn)
    else later(fn, 0)
  }

  return {
    toasts: [],
    expanded: false,
    _nextId: 0,
    _page: 0,

    add(detail) {
      const id = ++this._nextId
      this.toasts.unshift(buildToast(detail, id))
      while (this.toasts.length > TOAST_CAP) this.toasts.pop()
      this.expanded = false

      nextTick(() => {
        const toast = this.toasts.find((entry) => entry.id === id)
        if (toast) toast.visible = true
      })

      const duration = toastDuration(detail)
      if (duration > 0) later(() => this.dismiss(id), duration)
      return id
    },

    // Each message after the last, as the flash arrives. A message still
    // waiting when its page leaves (clear) is dropped.
    seed(messages) {
      const page = this._page;
      (messages || []).forEach((message, index) => {
        later(() => { if (this._page === page) this.add(message) }, index * SEED_STAGGER_MS + SEED_DELAY_MS)
      })
    },

    dismiss(id) {
      const toast = this.toasts.find((entry) => entry.id === id)
      if (!toast || !toast.visible) return
      toast.visible = false
      later(() => {
        this.toasts = this.toasts.filter((entry) => entry.id !== id)
        if (visibleCount(this.toasts) <= 1) this.expanded = false
      }, LEAVE_MS)
    },

    // The queue leaves with its page. A timer that fires later finds no toast.
    clear() {
      this._page += 1
      this.toasts = []
      this.expanded = false
    },

    hasVisible() { return this.toasts.some((toast) => toast.visible) },

    handlePeekClick(index) {
      if (!this.expanded && index > 0 && this.toasts.length > 1) this.expanded = true
    },

    toastStyle(index) { return toastStyle(this.toasts, index, this.expanded) },
    toastShadowClass(index) { return toastShadowClass(this.toasts, index) }
  }
}

// The flash messages a rendered root carries. Anything unreadable is no flash.
export function initialToasts(element) {
  const raw = element && element.getAttribute ? element.getAttribute(INITIAL_ATTRIBUTE) : null
  if (!raw) return []
  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch (_error) {
    return []
  }
}

// Registers $store.toasts unless Alpine already has one. Returns the store
// Alpine holds (its reactive proxy), or null before Alpine exists.
export function registerToastStore(Alpine, deps = {}) {
  if (!Alpine || typeof Alpine.store !== "function") return null
  if (!Alpine.store("toasts")) Alpine.store("toasts", createToastStore(deps))
  return Alpine.store("toasts")
}

const seeded = new WeakSet()

// Queues a root's flash messages, once per element. False when there is no
// store yet, so a later path seeds it.
export function seedToasts(element, { win } = {}) {
  const host = win || globalThis
  if (!element || seeded.has(element)) return false
  const store = registerToastStore(host.Alpine, { win: host })
  if (!store) return false
  seeded.add(element)
  store.seed(initialToasts(element))
  return true
}

// A cached Turbo snapshot keeps the root's flash attribute, and a restored page
// would replay it. Emptied here, before the snapshot is taken.
export function forgetInitialToasts(element) {
  if (element && element.hasAttribute && element.hasAttribute(INITIAL_ATTRIBUTE)) {
    element.setAttribute(INITIAL_ATTRIBUTE, "[]")
  }
}

const toastRoots = (root) =>
  (root && typeof root.querySelectorAll === "function" ? Array.from(root.querySelectorAll(TOAST_ROOT)) : [])

export function seedAllToasts({ win, doc } = {}) {
  const host = win || globalThis
  toastRoots(doc || host.document).forEach((element) => seedToasts(element, { win: host }))
}

// The page is leaving for Turbo's cache: its queue goes, and its roots forget
// their flash.
export function leavePage({ win, doc } = {}) {
  const host = win || globalThis
  const store = host.Alpine && typeof host.Alpine.store === "function" ? host.Alpine.store("toasts") : null
  if (store && typeof store.clear === "function") store.clear()
  toastRoots(doc || host.document).forEach(forgetInitialToasts)
}

// The `toast` event's handler. A toast raised before Alpine exists is dropped,
// as it was when the listener was an Alpine binding.
export function raiseToast(detail, { win } = {}) {
  const host = win || globalThis
  const store = registerToastStore(host.Alpine, { win: host })
  if (!store) return null
  return store.add(detail || {})
}

const installed = new WeakSet()

// Once per window: a second call adds no second listener.
export function installToast({ win, doc } = {}) {
  const host = win || globalThis
  const root = doc || host.document
  if (!root || typeof root.addEventListener !== "function") return false
  if (installed.has(host)) return false
  installed.add(host)

  root.addEventListener("alpine:init", () => registerToastStore(host.Alpine, { win: host }))
  root.addEventListener("alpine:initialized", () => seedAllToasts({ win: host, doc: root }))
  root.addEventListener("turbo:load", () => seedAllToasts({ win: host, doc: root }))
  root.addEventListener("turbo:before-cache", () => leavePage({ win: host, doc: root }))
  host.addEventListener("toast", (event) => raiseToast(event.detail, { win: host }))

  // Alpine already started (a host that loads it ahead of the module tags).
  if (host.Alpine && host.Alpine.version) {
    registerToastStore(host.Alpine, { win: host })
    seedAllToasts({ win: host, doc: root })
  }
  return true
}

if (typeof window !== "undefined") installToast({ win: window, doc: document })
