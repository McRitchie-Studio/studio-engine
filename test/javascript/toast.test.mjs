// [unit] studio/toast: the toast queue ($store.toasts), its cap and timers, the
// peek-stack styles, the flash a rendered root seeds, and the registration that
// runs from the module. Loaded from source as a data: module, like
// modal_host.test.mjs; the module imports nothing, which is what lets the head
// load it when studio/application does not.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/toast.js", import.meta.url), "utf8")
const {
  TOAST_CAP, DEFAULT_DURATION_MS, LEAVE_MS, SEED_DELAY_MS, SEED_STAGGER_MS, TOAST_ROOT,
  toastDuration, buildToast, toastStyle, toastShadowClass, createToastStore, initialToasts,
  registerToastStore, seedToasts, seedAllToasts, forgetInitialToasts, leavePage, raiseToast, installToast
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

// A window whose clock the test turns by hand: timers fire in due order when
// advance() passes them, so no test waits on the real four seconds.
const fakeWindow = (extra = {}) => {
  let now = 0
  let seq = 0
  let timers = []
  const listeners = {}
  const win = {
    listeners,
    setTimeout(fn, ms) { timers.push({ fn, at: now + (ms || 0), seq: seq += 1 }); return seq },
    advance(ms) {
      const until = now + ms
      for (;;) {
        const due = timers.filter((t) => t.at <= until).sort((a, b) => a.at - b.at || a.seq - b.seq)[0]
        if (!due) break
        timers = timers.filter((t) => t !== due)
        now = due.at
        due.fn()
      }
      now = until
    },
    pending: () => timers.length,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    fire(name, event = {}) { (listeners[name] || []).forEach((fn) => fn(event)) },
    ...extra
  }
  return win
}

// Alpine.store as Alpine has it: one argument reads, two register.
const fakeAlpine = () => {
  const stores = {}
  return {
    stores,
    version: "3.16.1",
    store(name, value) {
      if (value === undefined) return stores[name]
      stores[name] = value
    }
  }
}

const fakeDocument = (roots = []) => {
  const listeners = {}
  return {
    listeners,
    roots,
    addEventListener(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
    fire(name, event = {}) { (listeners[name] || []).forEach((fn) => fn(event)) },
    querySelectorAll(selector) { return selector === TOAST_ROOT ? this.roots : [] }
  }
}

// A rendered toast root, as layouts/studio/_flash writes it.
const rootElement = (initial) => {
  const attrs = initial === undefined ? {} : { "data-toast-initial-value": initial }
  return {
    attrs,
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    hasAttribute: (name) => name in attrs,
    setAttribute: (name, value) => { attrs[name] = value }
  }
}

const queue = () => {
  const win = fakeWindow()
  return { win, store: createToastStore({ win }) }
}

const visible = (store) => store.toasts.filter((toast) => toast.visible).map((toast) => toast.message)

test("the module imports nothing, so its own module tag survives a failed boot", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("a toast's duration: its own, four seconds by default, and none when it has buttons", () => {
  assert.equal(DEFAULT_DURATION_MS, 4000)
  assert.equal(LEAVE_MS, 400, "the .toast-wrapper leave transition is 0.4s")
  assert.equal(toastDuration({}), 4000)
  assert.equal(toastDuration({ duration: 9000 }), 9000)
  assert.equal(toastDuration({ duration: 0 }), 0)
  assert.equal(toastDuration({ buttons: [{ label: "Undo" }] }), 0)
  assert.equal(toastDuration({ buttons: [{ label: "Undo" }], duration: 2500 }), 2500)
  assert.equal(toastDuration({ buttons: [] }), 4000)
  assert.equal(toastDuration(undefined), 4000)
})

test("a queue entry fills the title from the type and enters invisible", () => {
  assert.deepEqual(buildToast({ message: "Saved" }, 7), {
    id: 7, type: "notice", title: "Success", message: "Saved", image: null,
    dismissible: true, blurShadow: false, buttons: [], visible: false
  })
  assert.equal(buildToast({ type: "alert" }, 1).title, "Error")
  assert.equal(buildToast({ type: "alert", title: "Link expired" }, 1).title, "Link expired")
  assert.equal(buildToast({ dismissible: false }, 1).dismissible, false)
  assert.equal(buildToast({ image: "/a.jpg", blurShadow: true }, 1).image, "/a.jpg")
  assert.equal(buildToast({ blurShadow: true }, 1).blurShadow, true)
  assert.equal(buildToast(undefined, 1).type, "notice")
})

test("add puts the newest first, shows it a tick later and dismisses it at its duration", () => {
  const { win, store } = queue()

  store.add({ message: "first" })
  assert.equal(store.toasts.length, 1)
  assert.deepEqual(visible(store), [], "it enters invisible, so the enter transition has a start")
  win.advance(0)
  assert.deepEqual(visible(store), ["first"])

  store.add({ message: "second" })
  win.advance(0)
  assert.deepEqual(store.toasts.map((toast) => toast.message), ["second", "first"])

  win.advance(DEFAULT_DURATION_MS - 1)
  assert.deepEqual(visible(store), ["second", "first"], "not before its four seconds")
  win.advance(1)
  assert.deepEqual(visible(store), [], "both start to leave at four seconds")
  assert.equal(store.toasts.length, 2, "and stay in the queue for the leave transition")
  win.advance(LEAVE_MS)
  assert.equal(store.toasts.length, 0)
})

test("the queue keeps five toasts: a sixth drops the oldest", () => {
  const { win, store } = queue()
  assert.equal(TOAST_CAP, 5)

  for (let n = 1; n <= 6; n += 1) store.add({ message: `t${n}`, duration: 0 })
  win.advance(0)

  assert.deepEqual(store.toasts.map((toast) => toast.message), ["t6", "t5", "t4", "t3", "t2"])
})

test("a toast with buttons stays until it is dismissed", () => {
  const { win, store } = queue()

  const id = store.add({ message: "undo?", buttons: [{ label: "Undo" }] })
  win.advance(60_000)
  assert.deepEqual(visible(store), ["undo?"])

  store.dismiss(id)
  assert.deepEqual(visible(store), [])
  win.advance(LEAVE_MS - 1)
  assert.equal(store.toasts.length, 1)
  win.advance(1)
  assert.equal(store.toasts.length, 0)
})

test("dismiss ignores an unknown toast and one that is already leaving", () => {
  const { win, store } = queue()
  const id = store.add({ message: "one", duration: 0 })
  win.advance(0)

  store.dismiss(999)
  assert.deepEqual(visible(store), ["one"])

  store.dismiss(id)
  const waiting = win.pending()
  store.dismiss(id)
  assert.equal(win.pending(), waiting, "a second dismiss schedules no second removal")
})

test("a new toast collapses an expanded stack; a click on a peeked toast expands it", () => {
  const { win, store } = queue()
  store.add({ message: "one", duration: 0 })
  store.add({ message: "two", duration: 0 })
  win.advance(0)

  store.handlePeekClick(0)
  assert.equal(store.expanded, false, "the newest toast is not a peek strip")
  store.handlePeekClick(1)
  assert.equal(store.expanded, true)

  store.add({ message: "three", duration: 0 })
  assert.equal(store.expanded, false)
})

test("the stack collapses again once one visible toast is left", () => {
  const { win, store } = queue()
  const first = store.add({ message: "one", duration: 0 })
  store.add({ message: "two", duration: 0 })
  win.advance(0)
  store.handlePeekClick(1)

  store.dismiss(first)
  win.advance(LEAVE_MS)

  assert.equal(store.expanded, false)
  assert.deepEqual(visible(store), ["two"])
})

test("a single toast cannot expand", () => {
  const { win, store } = queue()
  store.add({ message: "one", duration: 0 })
  win.advance(0)
  store.handlePeekClick(1)
  assert.equal(store.expanded, false)
})

test("styles: full for the newest, a peek strip for the next two, hidden beyond, shrunk when leaving", () => {
  const toasts = [1, 2, 3, 4].map((id) => ({ id, visible: true }))

  assert.equal(toastStyle(toasts, 0, false), "opacity: 1; transform: scale(1) translateY(0); margin-top: 0; max-height: 20rem;")
  assert.match(toastStyle(toasts, 1, false), /scale\(0\.97\).*max-height: 0\.5rem.*opacity: 0\.7;.*cursor: pointer/)
  assert.match(toastStyle(toasts, 2, false), /scale\(0\.94\).*opacity: 0\.5(5|49+\d*);/)
  assert.equal(toastStyle(toasts, 3, false), "max-height: 0; overflow: hidden; opacity: 0; margin-top: 0; pointer-events: none;")

  assert.equal(toastStyle(toasts, 2, true), "opacity: 1; transform: scale(1) translateY(0); margin-top: 0.35rem; max-height: 20rem;",
               "expanded, every toast is full with a gap above it")

  const leaving = [{ id: 1, visible: false }, { id: 2, visible: true }]
  assert.match(toastStyle(leaving, 0, false), /^opacity: 0; transform: scale\(0\.7\); max-height: 0;/)
  assert.equal(toastStyle(leaving, 1, false), "opacity: 1; transform: scale(1) translateY(0); margin-top: 0.35rem; max-height: 20rem;",
               "one visible toast is never a peek strip")
})

test("shadows: all round for one toast, top for the newest of several, bottom for the rest", () => {
  const one = [{ visible: true }]
  const two = [{ visible: true }, { visible: true }]
  assert.equal(toastShadowClass(one, 0), "toast-shadow-all")
  assert.equal(toastShadowClass(two, 0), "toast-shadow-top")
  assert.equal(toastShadowClass(two, 1), "toast-shadow-bottom")
  assert.equal(toastShadowClass([{ visible: true }, { visible: false }], 1), "toast-shadow-all")
})

test("the store's own style and shadow read its queue", () => {
  const { win, store } = queue()
  store.add({ message: "one", duration: 0 })
  store.add({ message: "two", duration: 0 })
  win.advance(0)

  assert.equal(store.hasVisible(), true)
  assert.equal(store.toastShadowClass(0), "toast-shadow-top")
  assert.match(store.toastStyle(1), /max-height: 0\.5rem/)
  store.expanded = true
  assert.match(store.toastStyle(1), /max-height: 20rem/)
})

test("a root's flash: its JSON attribute, and nothing when it is absent or unreadable", () => {
  assert.deepEqual(initialToasts(rootElement('[{"type":"notice","message":"Saved"}]')), [{ type: "notice", message: "Saved" }])
  assert.deepEqual(initialToasts(rootElement()), [])
  assert.deepEqual(initialToasts(rootElement("")), [])
  assert.deepEqual(initialToasts(rootElement("{not json")), [])
  assert.deepEqual(initialToasts(rootElement('{"type":"notice"}')), [], "an object is not a list of messages")
  assert.deepEqual(initialToasts(null), [])
})

test("seed staggers the flash: the first after 50ms, each next 100ms later", () => {
  const { win, store } = queue()
  store.seed([{ message: "a" }, { message: "b" }])

  win.advance(SEED_DELAY_MS - 1)
  assert.equal(store.toasts.length, 0)
  win.advance(1)
  assert.deepEqual(store.toasts.map((toast) => toast.message), ["a"])
  win.advance(SEED_STAGGER_MS)
  assert.deepEqual(store.toasts.map((toast) => toast.message), ["b", "a"])
})

test("clear empties the queue and drops a flash still waiting to enter", () => {
  const { win, store } = queue()
  store.add({ message: "showing" })
  win.advance(0)
  store.seed([{ message: "late" }])

  store.clear()
  assert.deepEqual(store.toasts, [])
  assert.equal(store.expanded, false)

  win.advance(SEED_DELAY_MS + 10)
  assert.deepEqual(store.toasts, [], "the waiting flash belonged to the page that left")
})

test("registerToastStore registers once, keeps a host's own store, and waits for Alpine", () => {
  const win = fakeWindow()
  assert.equal(registerToastStore(undefined, { win }), null)

  const Alpine = fakeAlpine()
  const store = registerToastStore(Alpine, { win })
  assert.equal(typeof store.add, "function")
  assert.equal(registerToastStore(Alpine, { win }), store, "a second call registers nothing new")

  const hosted = fakeAlpine()
  const own = { toasts: [], add() {} }
  hosted.store("toasts", own)
  assert.equal(registerToastStore(hosted, { win }), own)
})

test("a root is seeded once, by whichever path reaches it first", () => {
  const win = fakeWindow({ Alpine: fakeAlpine() })
  const root = rootElement('[{"type":"alert","message":"Nope"}]')

  assert.equal(seedToasts(root, { win }), true)
  assert.equal(seedToasts(root, { win }), false)
  win.advance(1000)

  assert.deepEqual(win.Alpine.store("toasts").toasts.map((toast) => [toast.type, toast.message]), [["alert", "Nope"]])
})

test("a root met before Alpine exists is left for a later path", () => {
  const win = fakeWindow()
  const root = rootElement('[{"message":"Saved"}]')

  assert.equal(seedToasts(root, { win }), false)
  win.Alpine = fakeAlpine()
  assert.equal(seedToasts(root, { win }), true)
  win.advance(1000)
  assert.equal(win.Alpine.store("toasts").toasts.length, 1)
})

test("a root loses its flash before Turbo caches the page", () => {
  const root = rootElement('[{"message":"Saved"}]')
  forgetInitialToasts(root)
  assert.deepEqual(initialToasts(root), [])

  const bare = rootElement()
  forgetInitialToasts(bare)
  assert.equal(bare.hasAttribute("data-toast-initial-value"), false, "a root with no flash gains no attribute")
})

test("a toast raised before Alpine exists is dropped and does not throw", () => {
  const win = fakeWindow()
  assert.equal(raiseToast({ message: "early" }, { win }), null)
})

test("installToast: the store on alpine:init, the flash once Alpine has walked the page", () => {
  const root = rootElement('[{"message":"Saved"}]')
  const doc = fakeDocument([root])
  const win = fakeWindow()

  assert.equal(installToast({ win, doc }), true)
  assert.equal(installToast({ win, doc }), false, "a second install adds no second listener")
  assert.equal(win.listeners.toast.length, 1)

  win.Alpine = fakeAlpine()
  doc.fire("alpine:init")
  const store = win.Alpine.store("toasts")
  assert.equal(typeof store.add, "function")
  assert.equal(store.toasts.length, 0, "the flash waits for Alpine to walk the page")

  doc.fire("alpine:initialized")
  win.advance(1000)
  assert.deepEqual(store.toasts.map((toast) => toast.message), ["Saved"])

  doc.fire("turbo:load")
  win.advance(1000)
  assert.equal(store.toasts.length, 1, "turbo:load on the same root seeds nothing more")
})

test("installToast: with no alpine:initialized to hear, turbo:load seeds the root", () => {
  const doc = fakeDocument([rootElement('[{"message":"Saved"}]')])
  const win = fakeWindow()
  installToast({ win, doc })
  win.Alpine = fakeAlpine()
  doc.fire("alpine:init")

  doc.fire("turbo:load")
  win.advance(1000)

  assert.deepEqual(win.Alpine.store("toasts").toasts.map((toast) => toast.message), ["Saved"])
})

test("the `toast` window event adds to the queue", () => {
  const doc = fakeDocument()
  const win = fakeWindow({ Alpine: fakeAlpine() })
  installToast({ win, doc })

  win.fire("toast", { detail: { type: "alert", title: "Blocked", message: "Not here", duration: 0 } })
  win.fire("toast", {})
  win.advance(0)

  const store = win.Alpine.store("toasts")
  assert.deepEqual(store.toasts.map((toast) => toast.title), ["Success", "Blocked"])
})

test("a Turbo visit: the leaving page's queue and flash go, the arriving root is seeded", () => {
  const leaving = rootElement('[{"message":"Old page"}]')
  const doc = fakeDocument([leaving])
  const win = fakeWindow({ Alpine: fakeAlpine() })
  installToast({ win, doc })
  win.advance(1000)
  const store = win.Alpine.store("toasts")
  assert.deepEqual(store.toasts.map((toast) => toast.message), ["Old page"], "Alpine was already up, so install seeds")

  doc.fire("turbo:before-cache")
  assert.deepEqual(store.toasts, [])
  assert.deepEqual(initialToasts(leaving), [], "the cached snapshot replays no flash")

  const arriving = rootElement('[{"message":"New page"}]')
  doc.roots = [arriving]
  doc.fire("turbo:load")
  win.advance(1000)
  assert.deepEqual(store.toasts.map((toast) => toast.message), ["New page"])
})

test("leavePage and seedAllToasts tolerate a page with no Alpine and no roots", () => {
  const win = fakeWindow()
  assert.doesNotThrow(() => leavePage({ win, doc: fakeDocument() }))
  assert.doesNotThrow(() => seedAllToasts({ win, doc: fakeDocument() }))
  assert.equal(installToast({ win: fakeWindow(), doc: null }), false)
})
