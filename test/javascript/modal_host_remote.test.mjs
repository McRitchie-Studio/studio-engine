// [unit] studio/modal_host's on-demand modals (Studio.modals): the shared
// store's open() fetches an advertised id once, inserts its <template x-if>
// into the host, shows the loading card only for a slow fetch, falls back to
// the error card, never inserts twice across a Turbo visit, and leaves every
// id the host does not advertise on the old synchronous path.
//
// Loaded from source as a data: module, like modal_host.test.mjs. The DOM is a
// small fake: the module touches only querySelector(All), createElement,
// children, get/setAttribute, appendChild and innerHTML.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/modal_host.js", import.meta.url), "utf8")
const {
  createModalStore, remoteConfig, remoteTemplate, insertRemoteModal, remoteModalUrl,
  fragmentHasScript, REMOTE_MODAL_ATTR, LOAD_DELAY_MS, DEFAULT_FETCH_TIMEOUT_MS, REMOTE_ERROR_TEXT
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

const element = (tag, attrs = {}) => ({
  tagName: tag.toUpperCase(),
  attrs: { ...attrs },
  children: [],
  html: "",
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null },
  setAttribute(name, value) { this.attrs[name] = String(value) },
  appendChild(child) { this.children.push(child); return child },
  removeChild(child) { this.children = this.children.filter((c) => c !== child); return child },
  set innerHTML(v) { this.html = v },
  get innerHTML() { return this.html }
})

const CONFIG = { url: "/_studio/modals/__id__", ids: ["rules", "wallet", "auth"], prefetch: ["auth"] }

// A page: a host template (with its content card) and the cards on screen.
const fakePage = (config = CONFIG) => {
  const innerCard = element("div", { "data-modal-host-card": "" })
  const host = config === null ? null : element("template", { "data-modal-host-remote-value": JSON.stringify(config) })
  if (host) host.content = { querySelector: (sel) => (sel === "[data-modal-host-card]" ? innerCard : null) }
  return { host, innerCard, liveCards: [] }
}

const fakeDocument = (page) => {
  const classes = new Set()
  const listeners = {}
  const doc = {
    page,
    addEventListener(name, fn) { (listeners[name] ||= []).push(fn) },
    dispatch(name) { (listeners[name] || []).forEach((fn) => fn({})) },
    body: { classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) } },
    activeElement: null,
    contains: () => false,
    createElement: (tag) => element(tag),
    querySelector(sel) {
      return sel === "template[data-modal-host-remote-value]" ? this.page.host : null
    },
    querySelectorAll(sel) {
      return sel === "[data-modal-host-card]" ? this.page.liveCards : []
    },
    // A Turbo visit: a new body and a new host.
    visit(nextPage) {
      this.page = nextPage
      this.body = { classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) } }
    }
  }
  return doc
}

// fetch, answered by hand: each call records a request and a settle function.
const fakeFetch = () => {
  const calls = []
  const fetch = (url, init) => new Promise((resolve, reject) => {
    calls.push({
      url, init,
      ok: (body, id) => resolve({ ok: true, status: 200, headers: { get: (h) => (h === "X-Studio-Modal" ? id : null) }, text: () => Promise.resolve(body) }),
      status: (code, headers = {}) => resolve({ ok: code < 300, status: code, headers: { get: (h) => headers[h] ?? null }, text: () => Promise.resolve("<html>login</html>") }),
      reject
    })
  })
  return { calls, fetch }
}

const setup = ({ page = fakePage() } = {}) => {
  const idleCalls = []
  const f = fakeFetch()
  const win = {
    // Timers of a second or more (the fetch timeout) never hold the runner open.
    setTimeout: (fn, ms) => { const t = setTimeout(fn, ms); if (ms >= 1000) t.unref(); return t },
    AbortController,
    clearTimeout: (t) => clearTimeout(t),
    fetch: f.fetch,
    StudioModals: { MIN_LOAD_MS: 60 },
    requestIdleCallback: (fn) => idleCalls.push(fn)
  }
  const doc = fakeDocument(page)
  const store = createModalStore({ doc, win })
  return { doc, win, store, page, fetches: f.calls, idleCalls }
}

const markup = '<div class="p-6"><h2>Rules</h2></div>'

test("an id the host does not advertise opens synchronously and fetches nothing", () => {
  const { store, fetches } = setup()
  store.open("plain", { title: "Plain" })
  assert.equal(store.current().id, "plain")
  assert.deepEqual(store._remote, {})
  assert.equal(fetches.length, 0)
})

test("a page with no advertised config opens every id synchronously", () => {
  const { store, fetches } = setup({ page: fakePage(null) })
  store.open("rules")
  assert.equal(store.current().id, "rules")
  assert.equal(fetches.length, 0)
})

test("an advertised id fetches once, inserts its template, then opens", async () => {
  const { store, fetches, page } = setup()
  store.open("rules", { title: "Rules" })
  assert.equal(store.current(), null, "nothing opens before the fragment is here")
  assert.equal(fetches.length, 1)
  assert.equal(fetches[0].url, "/_studio/modals/rules")
  assert.equal(fetches[0].init.credentials, "same-origin")
  fetches[0].ok(markup, "rules")
  await sleep(5)

  assert.equal(store.current().id, "rules")
  assert.equal(store.current().props.title, "Rules")
  assert.deepEqual(store._remote, {}, "a fast fetch never shows the loading card")
  const inserted = page.innerCard.children
  assert.equal(inserted.length, 1)
  assert.equal(inserted[0].getAttribute(REMOTE_MODAL_ATTR), "rules")
  assert.equal(inserted[0].getAttribute("x-if"), "$store.modals.current()?.id === 'rules' && !$store.modals._remote['rules']")
  assert.equal(inserted[0].innerHTML, markup)

  // Closed and opened again: synchronous, no second fetch, no second template.
  store.closeAll()
  store.open("rules")
  assert.equal(store.current().id, "rules")
  assert.equal(fetches.length, 1)
  assert.equal(page.innerCard.children.length, 1)
})

test("two opens while the fetch is in flight share one request", async () => {
  const { store, fetches } = setup()
  store.open("rules")
  store.open("rules")
  assert.equal(fetches.length, 1)
  fetches[0].ok(markup, "rules")
  await sleep(5)
  assert.equal(store.stack.length, 2)
})

test("a card already on screen gets the template too, so a stacked open shows", async () => {
  const page = fakePage()
  const live = element("div", { "data-modal-host-card": "" })
  page.liveCards.push(live)
  const { store, fetches } = setup({ page })
  store.open("plain")
  store.open("rules")
  fetches[0].ok(markup, "rules")
  await sleep(5)
  assert.equal(live.children.length, 1)
  assert.equal(page.innerCard.children.length, 1)
  assert.deepEqual(store.stack.map((e) => e.id), ["plain", "rules"])
})

test("a slow fetch opens the loading card, holds it, then clears it", async () => {
  const { store, fetches } = setup()
  store.open("wallet", { title: "Wallet" })
  await sleep(LOAD_DELAY_MS + 20)
  assert.equal(store.current().id, "wallet")
  assert.equal(store._remote.wallet, "loading")

  fetches[0].ok(markup, "wallet")
  await sleep(5)
  assert.equal(store._remote.wallet, "loading", "held for MIN_LOAD_MS")
  await sleep(80)
  assert.equal(store._remote.wallet, undefined)
  assert.equal(store.stack.length, 1, "the same entry, not a second one")
})

test("a failed fetch opens the error card and the next open retries", async () => {
  const { store, fetches } = setup()
  store.open("rules")
  fetches[0].status(500)
  await sleep(5)
  assert.equal(store.current().id, "rules")
  assert.equal(store._remote.rules, "error")

  store.closeAll()
  store.open("rules")
  assert.equal(fetches.length, 2, "a failure is not cached")
  assert.equal(store._remote.rules, undefined, "the retry clears the old error")
  fetches[1].ok(markup, "rules")
  await sleep(5)
  assert.equal(store.current().id, "rules")
  assert.equal(store._remote.rules, undefined)
})

test("a network rejection is the error card, not an unhandled rejection", async () => {
  const { store, fetches } = setup()
  store.open("rules")
  fetches[0].reject(new TypeError("Failed to fetch"))
  await sleep(5)
  assert.equal(store._remote.rules, "error")
})

test("an answer that is not the fragment (a redirect to a page, a 401) is an error", async () => {
  const { store, fetches, page } = setup()
  store.open("rules")
  fetches[0].status(200) // no X-Studio-Modal: a host filter's page
  await sleep(5)
  assert.equal(store._remote.rules, "error")
  assert.equal(page.innerCard.children.length, 0)

  store.closeAll()
  store.open("wallet")
  fetches[1].status(401)
  await sleep(5)
  assert.equal(store._remote.wallet, "error")
})

test("a slow fetch that then fails swaps the loading card for the error card", async () => {
  const { store, fetches } = setup()
  store.open("rules")
  await sleep(LOAD_DELAY_MS + 20)
  assert.equal(store._remote.rules, "loading")
  fetches[0].status(503)
  await sleep(5)
  assert.equal(store._remote.rules, "error")
  assert.equal(store.stack.length, 1)
})

test("a Turbo visit re-inserts from the cache once, and never duplicates a snapshot's copy", async () => {
  const { store, fetches, doc } = setup()
  store.open("rules")
  fetches[0].ok(markup, "rules")
  await sleep(5)
  store.closeAll()

  // A fresh page: its host has no inserted template.
  const fresh = fakePage()
  doc.visit(fresh)
  store.open("rules")
  assert.equal(store.current().id, "rules", "synchronous from the cache")
  assert.equal(fetches.length, 1)
  assert.equal(fresh.innerCard.children.length, 1)
  store.closeAll()
  store.open("rules")
  assert.equal(fresh.innerCard.children.length, 1, "inserted once per host")

  // A snapshot restore: the clone already carries the template.
  const restored = fakePage()
  restored.innerCard.appendChild(remoteTemplate(doc, "rules", markup))
  doc.visit(restored)
  store.closeAll()
  store.open("rules")
  assert.equal(restored.innerCard.children.length, 1)
})

test("a fetch that lands after a Turbo visit opens nothing on the new page", async () => {
  const { store, fetches, doc } = setup()
  store.open("rules")
  doc.visit(fakePage())
  fetches[0].ok(markup, "rules")
  await sleep(LOAD_DELAY_MS + 20)
  assert.equal(store.current(), null)
  assert.deepEqual(store._remote, {})
})

test("prefetch loads the flagged ids when the browser idles, and open then needs no wait", async () => {
  const { store, fetches, idleCalls, page } = setup()
  assert.equal(fetches.length, 0, "nothing before idle")
  assert.equal(idleCalls.length, 1)
  idleCalls[0]()
  assert.deepEqual(fetches.map((c) => c.url), ["/_studio/modals/auth"])
  fetches[0].ok(markup, "auth")
  await sleep(5)
  assert.equal(page.innerCard.children.length, 0, "prefetch caches, it does not insert")

  store.open("auth")
  assert.equal(store.current().id, "auth")
  assert.equal(fetches.length, 1)
  assert.equal(page.innerCard.children.length, 1)
})

test("a failed prefetch is swallowed and the open retries", async () => {
  const { store, fetches, idleCalls } = setup()
  idleCalls[0]()
  fetches[0].reject(new TypeError("offline"))
  await sleep(5)
  store.open("auth")
  assert.equal(fetches.length, 2)
})

test("remoteConfig refuses a malformed advertisement", () => {
  const bad = fakePage()
  bad.host.attrs["data-modal-host-remote-value"] = "{not json"
  assert.equal(remoteConfig(fakeDocument(bad)), null)
  const noIds = fakePage({ url: "/x/__id__" })
  assert.equal(remoteConfig(fakeDocument(noIds)), null)
  assert.deepEqual(remoteConfig(fakeDocument(fakePage({ url: "/x/__id__", ids: [] }))).prefetch, [])
})

test("insertRemoteModal answers false on a page with no marked card", () => {
  const doc = fakeDocument({ host: null, innerCard: null, liveCards: [] })
  assert.equal(insertRemoteModal(doc, "rules", markup), false)
})

test("remoteModalUrl fills the id into the advertised template", () => {
  assert.equal(remoteModalUrl({ url: "/app/_studio/modals/__id__" }, "contest-rules"), "/app/_studio/modals/contest-rules")
})

// ---- engine-modals-fetch-hardening ------------------------------------------

const withConfig = (extra) => fakePage({ ...CONFIG, ...extra })

test("a fetch that never answers times out into the error card, and the request is aborted", async () => {
  const { store, fetches } = setup({ page: withConfig({ timeout_ms: LOAD_DELAY_MS + 80 }) })
  store.open("rules", { dismissible: false })
  await sleep(LOAD_DELAY_MS + 20)
  assert.equal(store._remote.rules, "loading")
  await sleep(100)
  assert.equal(store._remote.rules, "error")
  assert.equal(fetches[0].init.signal.aborted, true)
  assert.equal(store.remoteErrorText(), REMOTE_ERROR_TEXT, "no debug: the generic line")

  // Close works on a dismissible: false card: the error card calls close().
  store.close()
  await sleep(260)
  assert.equal(store.current(), null)

  // A late answer after the timeout changes nothing.
  fetches[0].ok(markup, "rules")
  await sleep(5)
  assert.equal(store.current(), null)
})

test("the timeout defaults to DEFAULT_FETCH_TIMEOUT_MS when the host names none", () => {
  assert.equal(DEFAULT_FETCH_TIMEOUT_MS, 8000)
  assert.equal(remoteConfig(fakeDocument(fakePage())).timeout_ms, 8000)
  assert.equal(remoteConfig(fakeDocument(withConfig({ timeout_ms: 12000 }))).timeout_ms, 12000)
})

test("with debug, the error card names the reason", async () => {
  const { store } = setup({ page: withConfig({ timeout_ms: 30, debug: true }) })
  store.open("rules")
  await sleep(60)
  assert.equal(store._remote.rules, "error")
  assert.match(store.remoteErrorText(), /rules did not answer in 30ms/)
})

test("Try again re-runs the fetch with the entry in place, then shows the modal", async () => {
  const { store, fetches, page } = setup()
  store.open("rules", { dismissible: false })
  fetches[0].status(503)
  await sleep(5)
  const entry = store.current()
  assert.equal(store._remote.rules, "error")

  store.retryRemote()
  assert.equal(fetches.length, 2)
  assert.equal(store._remote.rules, "loading", "the loading card shows at once")
  assert.equal(store.current(), entry, "the same entry, not a second one")
  fetches[1].ok(markup, "rules")
  await sleep(80)
  assert.equal(store._remote.rules, undefined)
  assert.equal(store.stack.length, 1)
  assert.equal(page.innerCard.children.length, 1)

  store.retryRemote() // nothing to retry: a no-op
  assert.equal(fetches.length, 2)
})

test("a fragment carrying a <script> is refused: error card, nothing inserted, nothing cached", async () => {
  const { store, fetches, page } = setup({ page: withConfig({ debug: true }) })
  const errors = []
  const original = console.error
  console.error = (...args) => errors.push(args)
  try {
    store.open("rules")
    fetches[0].ok('<div><script>alert(1)</script></div>', "rules")
    await sleep(5)
  } finally {
    console.error = original
  }
  assert.equal(store._remote.rules, "error")
  assert.equal(page.innerCard.children.length, 0)
  assert.match(store.remoteErrorText(), /carries a <script>/)
  assert.deepEqual(errors, [], "no console output")

  store.closeAll()
  store.open("rules")
  assert.equal(fetches.length, 2, "a refused fragment is not cached")
})

test("without debug, a refused fragment shows only the generic line", async () => {
  const { store, fetches } = setup()
  store.open("rules")
  fetches[0].ok("<SCRIPT src=/x.js></SCRIPT>", "rules")
  await sleep(5)
  assert.equal(store._remote.rules, "error")
  assert.equal(store.remoteErrorText(), REMOTE_ERROR_TEXT)
})

test("fragmentHasScript matches a script element in any case, and nothing else", () => {
  assert.equal(fragmentHasScript("<script>x</script>"), true)
  assert.equal(fragmentHasScript('<ScRiPt type="module">'), true)
  assert.equal(fragmentHasScript("<script/>"), true)
  assert.equal(fragmentHasScript("<div>no scripts here</div>"), false)
  assert.equal(fragmentHasScript("<noscript>x</noscript>"), false)
})

test("a session change drops the cache: the next open refetches", async () => {
  const { store, fetches, doc } = setup({ page: withConfig({ session: "s1" }) })
  store.open("rules")
  fetches[0].ok(markup, "rules")
  await sleep(5)
  store.closeAll()

  // Same session, by Turbo: from the cache.
  doc.visit(withConfig({ session: "s1" }))
  store.open("rules")
  assert.equal(fetches.length, 1)
  store.closeAll()

  // Signed out (or in, or another user), by Turbo: a fresh fetch.
  const next = withConfig({ session: "s2" })
  doc.visit(next)
  store.open("rules")
  assert.equal(store.current(), null, "not opened from the stale cache")
  assert.equal(fetches.length, 2)
  fetches[1].ok("<div>fresh</div>", "rules")
  await sleep(5)
  assert.equal(next.innerCard.children[0].innerHTML, "<div>fresh</div>")
})

test("a session change removes templates already inserted on the page", async () => {
  const page = withConfig({ session: "s1" })
  const live = element("div", { "data-modal-host-card": "" })
  page.liveCards.push(live)
  const { store, fetches, doc } = setup({ page })
  store.open("rules")
  fetches[0].ok(markup, "rules")
  await sleep(5)
  store.closeAll()
  assert.equal(page.innerCard.children.length, 1)
  assert.equal(live.children.length, 1)

  // A snapshot restore that carries the old insert, under a new session.
  const restored = withConfig({ session: "s2" })
  restored.innerCard.appendChild(remoteTemplate(doc, "rules", markup))
  restored.innerCard.appendChild(element("p"))
  doc.visit(restored)
  store.open("rules")
  assert.equal(restored.innerCard.children.length, 1, "the stale insert is gone, other children stay")
  assert.equal(restored.innerCard.children[0].tagName, "P")
  assert.equal(fetches.length, 2)
})

test("a fetch in flight across a session change caches nothing", async () => {
  const { store, fetches, doc, idleCalls } = setup({ page: withConfig({ session: "s1" }) })
  idleCalls[0]() // prefetches auth under s1
  assert.equal(fetches.length, 1)

  doc.visit(withConfig({ session: "s2" }))
  store.open("auth")
  assert.equal(fetches.length, 2, "the s1 request is not shared with s2")
  fetches[0].ok("<div>old user</div>", "auth")
  fetches[1].ok("<div>new user</div>", "auth")
  await sleep(5)
  store.closeAll()

  const again = withConfig({ session: "s2" })
  doc.visit(again)
  store.open("auth")
  assert.equal(store.current().id, "auth", "from the cache")
  assert.equal(fetches.length, 2)
  assert.equal(again.innerCard.children[0].innerHTML, "<div>new user</div>")
})

test("prefetch runs again after a Turbo visit", async () => {
  const { store, fetches, doc, idleCalls } = setup({ page: withConfig({ prefetch: [] }) })
  assert.equal(idleCalls.length, 1)
  idleCalls[0]()
  assert.equal(fetches.length, 0, "the first page flags nothing")

  doc.visit(withConfig({ prefetch: ["auth"] }))
  doc.dispatch("turbo:load")
  assert.equal(idleCalls.length, 2, "turbo:load schedules a prefetch")
  idleCalls[1]()
  assert.deepEqual(fetches.map((c) => c.url), ["/_studio/modals/auth"])

  // A second turbo:load while that fetch is in flight shares it.
  doc.dispatch("turbo:load")
  idleCalls[2]()
  assert.equal(fetches.length, 1)
  fetches[0].ok(markup, "auth")
  await sleep(5)
  store.open("auth")
  assert.equal(store.current().id, "auth")
})

test("studio/session's session:changed drops the cache at once", async () => {
  const { store, fetches, doc, page } = setup()
  store.open("rules")
  fetches[0].ok(markup, "rules")
  await sleep(5)
  store.closeAll()
  assert.equal(page.innerCard.children.length, 1)

  doc.dispatch("session:changed")
  assert.equal(page.innerCard.children.length, 0, "the inserted template is removed")
  store.open("rules")
  assert.equal(fetches.length, 2)
})
