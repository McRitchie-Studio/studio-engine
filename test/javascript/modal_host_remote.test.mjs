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
  REMOTE_MODAL_ATTR, LOAD_DELAY_MS
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
  const doc = {
    page,
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
    setTimeout: (fn, ms) => setTimeout(fn, ms),
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
