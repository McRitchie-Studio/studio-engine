// [unit] studio/agent_chat: how the thread merges turns, which `after` a poll
// sends, how often it polls, the typing phase, the follow rule and the CSRF
// token. Loaded from source as a data: module, like knowledge_transcript.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/agent_chat.js", import.meta.url), "utf8")
const {
  settled, mergeTurns, turnKey, afterCursor, pollDelay, typingPhase, isFollowing, csrfToken, turnsUrl, mountAgentChat, coveredPx,
  REVEAL_GAP_PX, RECORDER_STATE_EVENT, EXPIRED_MESSAGE, POLL_MS, SLOW_MS, SLOW_AFTER_MS, IDLE_MS, OFFLINE_MS, LIMIT, REFRESH_EVENT, SENT_EVENT,
  revealPlan, openerStorageKey, OPENER_STORAGE_PREFIX, REVEAL_MIN_MS, REVEAL_MAX_MS, REVEAL_CPS,
  markdownInline, markdownBlocks, renderMarkdown, safeHref
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

const turn = (id, status = "answered", role = "user") => ({ id, role, status, text: `t${id}` })

test("the module imports nothing", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
})

test("the module never writes a turn's text as HTML", () => {
  assert.doesNotMatch(source, /innerHTML|insertAdjacentHTML|outerHTML/)
})

test("settled: pending and typing are unsettled; answered, failed and anything else settled", () => {
  assert.equal(settled(turn(1, "pending")), false)
  assert.equal(settled(turn(1, "typing")), false)
  assert.equal(settled(turn(1, "answered")), true)
  assert.equal(settled(turn(1, "failed")), true)
})

test("mergeTurns replaces a known id in place and appends a new one", () => {
  const merged = mergeTurns([turn(1), turn(2, "pending")], [turn(2, "answered"), turn(3, "answered", "agent")])
  assert.deepEqual(merged.map((t) => [t.id, t.status]), [[1, "answered"], [2, "answered"], [3, "answered"]])
})

test("mergeTurns matches ids as strings and drops turns with no id", () => {
  const merged = mergeTurns([turn(7)], [{ ...turn("7"), status: "failed" }, { role: "agent", text: "x" }, null])
  assert.equal(merged.length, 1)
  assert.equal(merged[0].status, "failed")
})

test("mergeTurns keeps a user turn and an agent turn that share a hub row id (turns are keyed by id and role)", () => {
  // The hub answers one agent_messages row as TWO turns with the row's id: the
  // visitor's words and, once answered, the agent's.
  const asked = [turn(9, "pending", "user")]
  const answered = [turn(9, "answered", "user"), { ...turn(9, "answered", "agent"), text: "reply" }]
  const merged = mergeTurns(asked, answered)
  assert.deepEqual(merged.map((t) => [t.id, t.role, t.status]), [[9, "user", "answered"], [9, "agent", "answered"]])
  assert.equal(merged[0].text, "t9", "the visitor's own words survive the answer")
  assert.equal(turnKey(merged[0]), "9:user")
  assert.equal(turnKey(merged[1]), "9:agent")
})

test("mergeTurns places an agent turn right after its own user turn, not at the end", () => {
  // The visitor sent A (row 1) then B (row 2) before A was answered.
  const sent = [turn(1, "pending", "user"), turn(2, "pending", "user")]
  const merged = mergeTurns(sent, [turn(1, "answered", "user"), { ...turn(1, "answered", "agent"), text: "answer to A" }])
  assert.deepEqual(merged.map(turnKey), ["1:user", "1:agent", "2:user"])
})

test("mergeTurns appends an agent turn whose user turn it has not seen", () => {
  const merged = mergeTurns([turn(1, "answered", "user")], [turn(3, "answered", "agent")])
  assert.deepEqual(merged.map(turnKey), ["1:user", "3:agent"])
})

test("mergeTurns does not mutate its input", () => {
  const turns = [turn(1)]
  mergeTurns(turns, [turn(2)])
  assert.equal(turns.length, 1)
})

test("afterCursor: null for an empty thread, the last id when all are settled", () => {
  assert.equal(afterCursor([]), null)
  assert.equal(afterCursor([turn(1), turn(2)]), "2")
})

test("afterCursor asks again about the first unsettled turn", () => {
  assert.equal(afterCursor([turn(1), turn(2), turn(3, "pending"), turn(4, "typing")]), "2")
  assert.equal(afterCursor([turn(1, "pending")]), null, "the first turn unsettled: the latest turns")
})

test("afterCursor with the hub's shared row ids: an answered row's two turns, then a pending row", () => {
  const turns = [turn(5, "answered", "user"), turn(5, "answered", "agent"), turn(6, "pending", "user")]
  assert.equal(afterCursor(turns), "5", "rows after 5: the pending row 6 is asked about again")
})

test("pollDelay: fast while waiting, slow after a long wait, idle when nothing waits, slow when offline", () => {
  assert.equal(pollDelay({ waiting: true, waitingSince: 1000, now: 1000 }), POLL_MS)
  assert.equal(pollDelay({ waiting: true, waitingSince: 0, now: SLOW_AFTER_MS + 1 }), SLOW_MS)
  assert.equal(pollDelay({ waiting: false, waitingSince: null, now: 5 }), IDLE_MS)
  assert.equal(pollDelay({ waiting: true, waitingSince: 0, now: 0, offline: true }), OFFLINE_MS)
  assert.ok(POLL_MS < SLOW_MS && SLOW_MS < IDLE_MS)
})

test("typingPhase: typing once any turn says so, else thinking", () => {
  assert.equal(typingPhase([turn(1, "pending")]), "thinking")
  assert.equal(typingPhase([turn(1, "pending"), turn(2, "typing", "agent")]), "typing")
})

test("isFollowing: within the follow distance of the end", () => {
  assert.equal(isFollowing({ scrollHeight: 1000, clientHeight: 400, scrollTop: 590 }), true)
  assert.equal(isFollowing({ scrollHeight: 1000, clientHeight: 400, scrollTop: 500 }), false)
})

test("csrfToken: the form's own field, else the csrf meta, else null", () => {
  const form = { querySelector: () => ({ value: "from-form" }) }
  const doc = { querySelector: () => ({ getAttribute: () => "from-meta" }) }
  assert.equal(csrfToken(form, doc), "from-form")
  assert.equal(csrfToken({ querySelector: () => null }, doc), "from-meta")
  assert.equal(csrfToken({ querySelector: () => null }, { querySelector: () => null }), null)
})

test("turnsUrl carries soul, limit and after, and appends to a URL with a query", () => {
  assert.equal(turnsUrl("/agent_chat/turns", { soul: "alex", after: null }), `/agent_chat/turns?soul=alex&limit=${LIMIT}`)
  assert.equal(turnsUrl("/agent_chat/turns", { soul: "alex", after: "12" }), `/agent_chat/turns?soul=alex&limit=${LIMIT}&after=12`)
  assert.equal(turnsUrl("/x?y=1", { soul: "a b", after: null, limit: 5 }), "/x?y=1&soul=a+b&limit=5")
})

// ---- the public refresh hook ---------------------------------------------------

// A stand-in chat section with no templates: what the hook does is visible on the
// returned state and the fetches it makes.
function standIn() {
  const listeners = {}
  const log = { addEventListener() {}, removeEventListener() {}, querySelectorAll: () => [], scrollHeight: 0, clientHeight: 0, scrollTop: 0 }
  const typing = { hidden: true }
  const parts = { "[data-agent-chat-log]": log, "[data-agent-chat-typing]": typing }
  const root = {
    dataset: { agentChatSoul: "alex", agentChatName: "Alex", agentChatTurnsUrl: "/agent_chat/turns" },
    querySelector: (selector) => parts[selector] || null,
    addEventListener: (type, fn) => { listeners[type] = fn },
    removeEventListener: (type) => { delete listeners[type] }
  }
  return { root, listeners, typing }
}

function deferredFetch() {
  const asks = []
  const fetcher = (url) => new Promise((resolve) => {
    asks.push({ url, answer: (turns = [], pending = false) => resolve({ ok: true, json: async () => ({ turns, pending }) }) })
  })
  return { asks, fetcher }
}

const flush = () => new Promise((resolve) => setImmediate(resolve))

function mountStandIn(page, fetcher) {
  const timers = []
  const chat = mountAgentChat(page.root, { fetch: fetcher, doc: null, setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length }, clearTimer: () => {} })
  return { chat, timers }
}

test("the refresh event polls now", async () => {
  assert.equal(REFRESH_EVENT, "studio:agent-chat:refresh")
  const page = standIn()
  const { asks, fetcher } = deferredFetch()
  mountStandIn(page, fetcher)
  asks[0].answer()
  await flush()
  assert.equal(asks.length, 1)

  page.listeners[REFRESH_EVENT]({ detail: null })
  assert.equal(asks.length, 2, "no wait for the idle poll")
})

test("a refresh during a poll is not swallowed: one more poll follows it", async () => {
  const page = standIn()
  const { asks, fetcher } = deferredFetch()
  const { chat } = mountStandIn(page, fetcher)

  chat.refresh()
  chat.refresh()
  assert.equal(asks.length, 1, "still one poll in flight")

  asks[0].answer()
  await flush()
  assert.equal(asks.length, 2, "the second poll goes as soon as the first lands")
  asks[1].answer()
  await flush()
  assert.equal(asks.length, 2, "and only one")
})

test("a refresh with a turn shows it at once as waiting, and the next poll asks about it", async () => {
  const page = standIn()
  const { asks, fetcher } = deferredFetch()
  const { chat } = mountStandIn(page, fetcher)
  asks[0].answer([turn(1)])
  await flush()

  page.listeners[REFRESH_EVENT]({ detail: { turn: turn(2, "pending") } })

  assert.deepEqual(chat.state.turns.map((t) => t.id), [1, 2])
  assert.equal(chat.state.pending, true)
  assert.equal(page.typing.hidden, false, "the typing line shows without waiting for the poll")
  assert.equal(asks.length, 2)
  assert.match(asks[1].url, /after=1(&|$)/, "the unsettled turn is asked about again")
})

test("after destroy the hook is gone and a refresh does nothing", async () => {
  const page = standIn()
  const { asks, fetcher } = deferredFetch()
  const { chat } = mountStandIn(page, fetcher)
  asks[0].answer()
  await flush()
  chat.destroy()

  assert.equal(page.listeners[REFRESH_EVENT], undefined)
  chat.refresh()
  assert.equal(asks.length, 1)
})

// A chat section with one real turn node, enough to read what render() shows.
function withTurnNode() {
  const page = standIn()
  const lines = { "[data-agent-chat-text]": { textContent: "" }, "[data-agent-chat-failed]": { hidden: true }, "[data-agent-chat-held]": { hidden: true } }
  const node = { dataset: {}, querySelector: (s) => lines[s] || null, after() {} }
  const log = page.root.querySelector("[data-agent-chat-log]")
  log.querySelectorAll = () => (node.dataset.turnKey ? [node] : [])
  log.appendChild = () => {}
  const template = { content: { firstElementChild: { cloneNode: () => node } } }
  const query = page.root.querySelector
  page.root.querySelector = (s) => (s.startsWith("template") ? template : query(s))
  return { page, node, lines }
}

// CONTROL: restore `turn.status !== "failed"` alone, with no held line, and the
// first assert fails: a held turn shows nothing, or tells the person to resend.
test("a held turn says it was received and never tells the person to send it again", async () => {
  const { page, lines } = withTurnNode()
  const { asks, fetcher } = deferredFetch()
  mountStandIn(page, fetcher)
  asks[0].answer([turn(1, "held")])
  await flush()
  assert.equal(lines["[data-agent-chat-held]"].hidden, false)
  assert.equal(lines["[data-agent-chat-failed]"].hidden, true, "no failed line")
  assert.equal(page.typing.hidden, true, "a held turn is settled: no answer is pending")
})

test("a hub still sending failed keeps the failed line and no held line", async () => {
  const { page, lines } = withTurnNode()
  const { asks, fetcher } = deferredFetch()
  mountStandIn(page, fetcher)
  asks[0].answer([turn(1, "failed")])
  await flush()
  assert.equal(lines["[data-agent-chat-failed]"].hidden, false)
  assert.equal(lines["[data-agent-chat-held]"].hidden, true)
})

test("held is settled, and a poll's cursor moves past it", () => {
  assert.equal(settled(turn(1, "held")), true)
  assert.equal(afterCursor([turn(1, "held")]), "1")
})

test("a refresh with a held turn shows no typing line", async () => {
  const { page } = withTurnNode()
  const { asks, fetcher } = deferredFetch()
  const { chat } = mountStandIn(page, fetcher)
  asks[0].answer()
  await flush()
  chat.refresh({ turn: turn(1, "held") })
  assert.equal(page.typing.hidden, true)
})

function composerFor(page, answerWith) {
  const input = { value: "typed words", addEventListener() {}, removeEventListener() {} }
  const form = { getAttribute: () => "/agent_chat/messages", querySelector: () => null, addEventListener() {}, removeEventListener() {} }
  const query = page.root.querySelector
  page.root.querySelector = (s) => (s === "[data-agent-chat-form]" ? form : s === "[data-agent-chat-input]" ? input : query(s))
  const events = []
  page.root.dispatchEvent = (event) => events.push(event)
  const fetcher = async (url, init) => (init && init.method === "POST" ? answerWith : { ok: true, json: async () => ({ turns: [], pending: false }) })
  return { events, fetcher, input }
}

class SentEvent { constructor(type, init = {}) { this.type = type; this.detail = init.detail } }

test("a typed send the app took tells the page; a refused one does not", async () => {
  assert.equal(SENT_EVENT, "studio:agent-chat:sent")
  const page = standIn()
  const sent = composerFor(page, { status: 201, json: async () => ({ turn: turn(9, "pending") }) })
  const { chat } = (() => {
    const timers = []
    return { chat: mountAgentChat(page.root, { fetch: sent.fetcher, doc: null, CustomEventClass: SentEvent, setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length }, clearTimer: () => {} }) }
  })()
  await chat.submit()
  assert.deepEqual(sent.events.map((event) => event.type), [SENT_EVENT])
  assert.equal(sent.events[0].detail.turn.id, 9)

  const other = standIn()
  const refused = composerFor(other, { status: 429, json: async () => ({ error: "Slow down." }) })
  const second = mountAgentChat(other.root, { fetch: refused.fetcher, doc: null, CustomEventClass: SentEvent, setTimer: () => 0, clearTimer: () => {} })
  await second.submit()
  assert.deepEqual(refused.events, [], "the voice line may still be the one that explains the box")
})

// ---- the thread's end stays clear of the composer ---------------------------------

test("coveredPx: what the composer, or the window's bottom when it is lower, hides", () => {
  assert.equal(coveredPx({ bottom: 660 }, { top: 598 }, 844), 62)
  assert.equal(coveredPx({ bottom: 500 }, { top: 598 }, 844), -98)
  assert.equal(coveredPx({ bottom: 900 }, { top: 1000 }, 844), 56, "a composer below the fold hides nothing; the window does")
})

// A stand-in with measurable boxes. `end` is where the log's bottom is now; scrolling
// the page moves it, as a real page does.
function measured({ end = 660, composer = 598, composerHeight = 246, holding = false } = {}) {
  const page = standIn()
  const box = { end }
  const scrolls = []
  const log = page.root.querySelector("[data-agent-chat-log]")
  log.style = {}
  log.getBoundingClientRect = () => ({ bottom: box.end })
  log.scrollIntoView = (options) => {
    scrolls.push({ ...options, margin: log.style.scrollMarginBottom })
    box.end = composer - REVEAL_GAP_PX
  }
  // The typing line, once it shows, is the thread's end.
  Object.assign(page.typing, { style: log.style, getBoundingClientRect: log.getBoundingClientRect, scrollIntoView: log.scrollIntoView })
  const form = { getAttribute: () => "/m", getBoundingClientRect: () => ({ top: composer, height: composerHeight }), addEventListener() {}, removeEventListener() {} }
  const realQuery = page.root.querySelector
  const hold = { holding }
  page.root.querySelector = (selector) => {
    if (selector === "[data-agent-chat-form]") return form
    if (selector.includes("data-voice-recorder-state")) return hold.holding ? {} : null
    return realQuery(selector)
  }
  const listeners = {}
  const doc = {
    visibilityState: "visible",
    documentElement: { clientHeight: 844 },
    querySelector: () => null,
    contains: () => true,
    addEventListener: (type, fn) => { listeners[type] = fn },
    removeEventListener: (type) => { delete listeners[type] }
  }
  return { page, box, scrolls, hold, doc, docListeners: listeners }
}

function mountMeasured(setup, turns = [turn(1)]) {
  const fetcher = async () => ({ ok: true, json: async () => ({ turns, pending: false }) })
  return mountAgentChat(setup.page.root, { fetch: fetcher, doc: setup.doc, setTimer: () => 0, clearTimer: () => {} })
}

test("load: a thread whose end is under the composer scrolls it clear, by the composer's height and a gap", async () => {
  const setup = measured()
  mountMeasured(setup)
  await flush()
  assert.deepEqual(setup.scrolls, [{ block: "end", behavior: "instant", margin: `${844 - 598 + REVEAL_GAP_PX}px` }])
  assert.equal(setup.page.root.querySelector("[data-agent-chat-log]").style.scrollMarginBottom, "", "the margin does not stay")
})

test("load: a composer not stuck yet still leaves room for its height and its sticky bottom", async () => {
  const setup = measured({ end: 1400, composer: 1300, composerHeight: 240 })
  const real = globalThis.getComputedStyle
  globalThis.getComputedStyle = () => ({ bottom: "8px" })
  try {
    mountMeasured(setup)
    await flush()
  } finally {
    globalThis.getComputedStyle = real
  }
  assert.equal(setup.scrolls[0].margin, `${240 + 8 + REVEAL_GAP_PX}px`)
})

test("load: an end already clear, or an empty thread, does not scroll the page", async () => {
  const clear = measured({ end: 500 })
  mountMeasured(clear)
  await flush()
  assert.deepEqual(clear.scrolls, [])

  const empty = measured()
  mountMeasured(empty, [])
  await flush()
  assert.deepEqual(empty.scrolls, [])
})

test("a reader who scrolled the page up is not moved by a reply; their own turn brings them back", async () => {
  const setup = measured()
  const chat = mountMeasured(setup)
  await flush()
  setup.scrolls.length = 0

  setup.box.end = 900 // they scrolled up: the end is far under the composer
  setup.docListeners.scroll({ target: { contains: () => false } })
  assert.equal(chat.state.revealFollowing, true, "the log's own scroll says nothing: it does not hold the chat")
  setup.docListeners.scroll({ target: setup.doc })
  assert.equal(chat.state.revealFollowing, false)
  await chat.poll()
  assert.deepEqual(setup.scrolls, [], "a poll's render leaves them where they read")

  chat.refresh({ turn: turn(2) })
  assert.equal(setup.scrolls.length, 1)
  assert.equal(chat.state.revealFollowing, true)
})

test("a reader scrolled up inside the thread is not moved", async () => {
  const setup = measured({ end: 500 })
  const chat = mountMeasured(setup)
  await flush()
  chat.state.following = false
  setup.box.end = 700
  await chat.poll()
  assert.deepEqual(setup.scrolls, [])
})

test("during a hold nothing scrolls; the owed reveal is paid when the button is let go", async () => {
  const setup = measured({ holding: true })
  const chat = mountMeasured(setup)
  await flush()
  assert.deepEqual(setup.scrolls, [])
  assert.equal(chat.state.revealOwed, true)

  setup.page.listeners[RECORDER_STATE_EVENT]()
  assert.deepEqual(setup.scrolls, [], "a state change inside the hold pays nothing")

  setup.hold.holding = false
  setup.page.listeners[RECORDER_STATE_EVENT]()
  assert.equal(setup.scrolls.length, 1)
  assert.equal(chat.state.revealOwed, false)

  setup.page.listeners[RECORDER_STATE_EVENT]()
  assert.equal(setup.scrolls.length, 1, "once")
})

test("destroy removes the page's and the recorder's listeners", async () => {
  const setup = measured()
  const chat = mountMeasured(setup)
  await flush()
  assert.equal(typeof setup.docListeners.scroll, "function")
  chat.destroy()
  assert.equal(setup.docListeners.scroll, undefined)
  assert.equal(setup.page.listeners[RECORDER_STATE_EVENT], undefined)
})

test("the thread's end is the typing line while it shows, and the offline notice over it", async () => {
  const setup = measured({ end: 500 })
  const offline = { hidden: true, style: {}, scrollIntoView() { offline.scrolled = true }, getBoundingClientRect: () => ({ bottom: 700 }) }
  const query = setup.page.root.querySelector
  setup.page.root.querySelector = (selector) => (selector === "[data-agent-chat-offline]" ? offline : query(selector))
  const chat = mountMeasured(setup)
  await flush()
  assert.equal(offline.scrolled, undefined)

  offline.hidden = false
  await chat.refresh({ turn: turn(2) })
  assert.equal(offline.hidden, true, "a turn that landed clears the notice")
})

test("a typed send refused for its token keeps the words and says to reload", async () => {
  const page = standIn()
  const input = { value: "my words", addEventListener() {}, removeEventListener() {} }
  const error = { hidden: true, textContent: "" }
  const form = { getAttribute: () => "/agent_chat/messages", querySelector: () => null, addEventListener() {}, removeEventListener() {} }
  const query = page.root.querySelector
  const parts = { "[data-agent-chat-input]": input, "[data-agent-chat-error]": error, "[data-agent-chat-form]": form }
  page.root.querySelector = (selector) => parts[selector] || query(selector)
  const fetcher = async (url) => (String(url).includes("turns")
    ? { ok: true, json: async () => ({ turns: [], pending: false }) }
    : { status: 422, json: async () => ({ error: "This page has expired. Reload it, then try again.", reason: "invalid_token" }) })
  const chat = mountAgentChat(page.root, { fetch: fetcher, doc: { querySelector: () => null }, setTimer: () => 0, clearTimer: () => {} })
  await chat.submit()
  assert.equal(input.value, "my words")
  assert.equal(error.textContent, EXPIRED_MESSAGE)
  assert.match(error.textContent, /reload/i)
})

// ---- the opener and the type-in (studio/talk_to_agent) ---------------------------

test("revealPlan: about REVEAL_CPS a second, clamped, and whole at the end", () => {
  assert.equal(revealPlan(42, 0).duration, REVEAL_MIN_MS, "a short answer still takes the floor")
  assert.equal(revealPlan(100000, 0).duration, REVEAL_MAX_MS, "a long one never takes longer than the cap")
  assert.equal(revealPlan(REVEAL_CPS, 0).duration, 1000)
  assert.equal(revealPlan(420, 500).shown, 210)
  assert.equal(revealPlan(420, 5000).shown, 420)
  assert.equal(revealPlan(420, -5).shown, 0)
})

test("openerStorageKey: prefixed, and null with no key", () => {
  assert.equal(openerStorageKey("alex:Pro"), `${OPENER_STORAGE_PREFIX}alex:Pro`)
  assert.equal(openerStorageKey(""), null)
  assert.equal(openerStorageKey(undefined), null)
})

function memoryStorage() {
  const items = new Map()
  return { items, getItem: (k) => (items.has(k) ? items.get(k) : null), setItem: (k, v) => items.set(k, String(v)), removeItem: (k) => items.delete(k) }
}

// A stand-in with a composer whose POSTs are recorded and answered with `answer`.
function openerPage(answer, dataset = {}) {
  const page = standIn()
  Object.assign(page.root.dataset, { agentChatOpener: "Tell me about Pro.", agentChatOpenerKey: "alex:Pro" }, dataset)
  const input = { value: "", addEventListener() {}, removeEventListener() {} }
  const form = { getAttribute: () => "/agent_chat/messages", querySelector: () => null, addEventListener() {}, removeEventListener() {} }
  const query = page.root.querySelector
  page.root.querySelector = (s) => (s === "[data-agent-chat-form]" ? form : s === "[data-agent-chat-input]" ? input : query(s))
  page.root.dispatchEvent = () => {}
  const posts = []
  const fetcher = async (url, init) => {
    if (init && init.method === "POST") { posts.push(JSON.parse(init.body)); return answer }
    return { ok: true, json: async () => ({ turns: [], pending: false }) }
  }
  return { page, input, posts, fetcher }
}

const mountOpener = (setup, storage) => mountAgentChat(setup.page.root, {
  fetch: setup.fetcher, doc: null, storage, CustomEventClass: SentEvent, setTimer: () => 0, clearTimer: () => {}
})

// CONTROL: remove the sendOpener() call from poll and the first assert fails:
// the modal opens on a silent chat.
test("the opener is sent once the thread loads, and once per key per tab", async () => {
  const storage = memoryStorage()
  const first = openerPage({ status: 201, json: async () => ({ turn: turn(5, "pending") }) })
  const chat = mountOpener(first, storage)
  await flush()
  await flush()
  assert.deepEqual(first.posts, [{ soul: "alex", text: "Tell me about Pro." }])
  assert.equal(chat.state.pending, true, "the agent is answering: the typing line shows")

  const again = openerPage({ status: 201, json: async () => ({ turn: turn(6, "pending") }) })
  mountOpener(again, storage)
  await flush()
  await flush()
  assert.deepEqual(again.posts, [], "the same topic opened again shows the thread and sends nothing")

  const other = openerPage({ status: 201, json: async () => ({ turn: turn(7, "pending") }) }, { agentChatOpenerKey: "alex:Team", agentChatOpener: "Team?" })
  mountOpener(other, storage)
  await flush()
  await flush()
  assert.deepEqual(other.posts.map((p) => p.text), ["Team?"], "another topic sends its own")
})

test("no opener, nothing sent", async () => {
  const setup = openerPage({ status: 201, json: async () => ({ turn: turn(5) }) }, { agentChatOpener: "" })
  mountOpener(setup, memoryStorage())
  await flush()
  await flush()
  assert.deepEqual(setup.posts, [])
})

test("a refused opener goes into the box and is not remembered", async () => {
  const storage = memoryStorage()
  const setup = openerPage({ status: 429, json: async () => ({ error: "Slow down." }) })
  mountOpener(setup, storage)
  await flush()
  await flush()
  assert.equal(setup.posts.length, 1)
  assert.equal(setup.input.value, "Tell me about Pro.", "the visitor can send it themselves")
  assert.equal(storage.items.size, 0, "the next open tries again")
})

// A chat with one agent turn node, the type-in on, and a clock the test moves.
function typingPage({ reveal = "true", reduced = false } = {}) {
  const { page, lines } = withTurnNode()
  page.root.dataset.agentChatReveal = reveal
  const log = page.root.querySelector("[data-agent-chat-log]")
  log.setAttribute = (k, v) => { log[k] = v }
  log.removeAttribute = (k) => { delete log[k] }
  let clock = 0
  const timers = []
  const { asks, fetcher } = deferredFetch()
  const chat = mountAgentChat(page.root, {
    fetch: fetcher, doc: null, now: () => clock, storage: null, reducedMotion: () => reduced,
    setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length }, clearTimer: () => {}
  })
  return { chat, asks, lines, log, timers, advance: (ms) => { clock += ms } }
}

const answer = (text) => ({ id: 1, role: "agent", status: "answered", text })

// CONTROL: make startTyping set the whole text at once and the "part way" assert fails.
test("an answer that arrives after the load types itself in; the log is busy until it is done", async () => {
  const t = typingPage()
  t.asks[0].answer([])
  await flush()
  t.chat.refresh()
  t.asks[1].answer([answer("x".repeat(420))])
  await flush()
  const text = t.lines["[data-agent-chat-text]"]
  assert.equal(text.textContent, "", "the first frame shows nothing yet")
  assert.equal(t.log["aria-busy"], "true")
  t.advance(500)
  t.timers.filter((x) => x.ms === 32).at(-1).fn()
  assert.equal(text.textContent.length, 210, "part way")
  t.advance(1000)
  t.timers.filter((x) => x.ms === 32).at(-1).fn()
  assert.equal(text.textContent.length, 420, "whole at the end")
  assert.equal(t.log["aria-busy"], undefined)
})

test("the thread loaded on open, a reveal that is off, and reduced motion all show at once", async () => {
  const loaded = typingPage()
  loaded.asks[0].answer([answer("history")])
  await flush()
  assert.equal(loaded.lines["[data-agent-chat-text]"].textContent, "history")

  for (const options of [{ reveal: "false" }, { reduced: true }]) {
    const t = typingPage(options)
    t.asks[0].answer([])
    await flush()
    t.chat.refresh()
    t.asks[1].answer([answer("now")])
    await flush()
    assert.equal(t.lines["[data-agent-chat-text]"].textContent, "now", JSON.stringify(options))
  }
})

test("an opener the thread already ends with is not sent again (another tab sent it)", async () => {
  const setup = openerPage({ status: 201, json: async () => ({ turn: turn(9, "pending") }) })
  setup.fetcher = ((post) => async (url, init) => (init && init.method === "POST"
    ? post(url, init)
    : { ok: true, json: async () => ({ turns: [{ id: 3, role: "user", status: "answered", text: "Tell me about Pro." }], pending: false }) }))(setup.fetcher)
  mountOpener(setup, memoryStorage())
  await flush()
  await flush()
  assert.deepEqual(setup.posts, [])
})

test("a closed chat stops: destroy clears its poll and any answer still typing", async () => {
  const t = typingPage()
  t.asks[0].answer([])
  await flush()
  t.chat.refresh()
  t.asks[1].answer([answer("x".repeat(420))])
  await flush()
  t.chat.destroy()
  assert.equal(t.chat.state.typing.size, 0)
  assert.equal(t.chat.state.alive, false)
  assert.equal(t.log["aria-busy"], undefined)
})

// ---- the opener races (Carl's review of talk-to-agent-modal) ---------------------

// An opener page whose GET (the thread load) and POSTs wait for the test.
function racePage() {
  const setup = openerPage(null)
  const loads = []
  const posts = []
  setup.fetcher = (url, init) => new Promise((resolve) => {
    if (init && init.method === "POST") {
      const body = JSON.parse(init.body)
      posts.push({ body, answer: (id) => resolve({ status: 201, json: async () => ({ turn: { ...turn(id, "pending"), text: body.text } }) }) })
    } else {
      loads.push({ answer: (turns = []) => resolve({ ok: true, json: async () => ({ turns, pending: false }) }) })
    }
  })
  return { ...setup, loads, posts }
}

// CONTROL: restore the old order (mark the store, then post(), which returns at
// once while the visitor's send is in flight) and this fails: the posts are only
// the visitor's words, and the store says the opener went.
test("race 1: the visitor sends before the thread loads; the opener still goes, first, once", async () => {
  const storage = memoryStorage()
  const r = racePage()
  const chat = mountOpener(r, storage)
  r.input.value = "how much is it?"
  const sending = chat.submit()
  await flush()
  assert.deepEqual(r.posts.map((p) => p.body.text), ["Tell me about Pro."], "the opener goes ahead of the visitor's words")
  r.loads[0].answer([])
  await flush()
  assert.equal(r.posts.length, 1, "the load does not send the opener again")
  r.posts[0].answer(5)
  await flush()
  assert.deepEqual(r.posts.map((p) => p.body.text), ["Tell me about Pro.", "how much is it?"])
  r.posts[1].answer(6)
  await sending
  await flush()
  assert.equal(r.posts.length, 2, "never twice")
  assert.equal(r.input.value, "", "the visitor's words went")
  assert.equal(storage.items.size, 1, "remembered: it was posted")
})

// CONTROL: restore `if (!text || state.sending) return` with no wait for the
// opener and this fails: the visitor's words are never posted.
test("race 2: the visitor sends while the load's opener is in flight; both go, in order, once each", async () => {
  const storage = memoryStorage()
  const r = racePage()
  const chat = mountOpener(r, storage)
  r.loads[0].answer([])
  await flush()
  assert.deepEqual(r.posts.map((p) => p.body.text), ["Tell me about Pro."])
  r.input.value = "and Team?"
  const sending = chat.submit()
  await flush()
  assert.equal(r.posts.length, 1, "the visitor's words wait for the opener")
  r.posts[0].answer(5)
  await flush()
  assert.deepEqual(r.posts.map((p) => p.body.text), ["Tell me about Pro.", "and Team?"])
  r.posts[1].answer(6)
  await sending
  chat.sendOpener()
  await flush()
  assert.equal(r.posts.length, 2, "a later sendOpener sends nothing")
})

test("a chat mounted again while the opener is in flight does not send it twice", async () => {
  const storage = memoryStorage()
  const r = racePage()
  mountOpener(r, storage)
  r.loads[0].answer([])
  await flush()
  assert.equal(r.posts.length, 1)
  const again = racePage()
  mountOpener(again, storage)
  again.loads[0].answer([])
  await flush()
  assert.equal(again.posts.length, 0)
})

// ---- Markdown in agent turns -------------------------------------------------------

test("markdownInline: bold, italics, code and http(s) links; anything else is text", () => {
  assert.deepEqual(markdownInline("a **b** c"), [{ text: "a " }, { strong: [{ text: "b" }] }, { text: " c" }])
  assert.deepEqual(markdownInline("__b__ *i*"), [{ strong: [{ text: "b" }] }, { text: " " }, { em: [{ text: "i" }] }])
  assert.deepEqual(markdownInline("**a *b* c**"), [{ strong: [{ text: "a " }, { em: [{ text: "b" }] }, { text: " c" }] }])
  assert.deepEqual(markdownInline("`x<y>`"), [{ code: "x<y>" }])
  assert.deepEqual(markdownInline("see [Pro](https://alex.build/packages)."), [{ text: "see " }, { link: "Pro", href: "https://alex.build/packages" }, { text: "." }])
  assert.deepEqual(markdownInline("[x](javascript:alert(1))"), [{ text: "[x](javascript:alert(1))" }])
  assert.deepEqual(markdownInline("2 * 3 * 4 and snake_case_name"), [{ text: "2 * 3 * 4 and snake_case_name" }])
})

test("safeHref: http and https only", () => {
  assert.equal(safeHref("https://a.example/x?y=1"), "https://a.example/x?y=1")
  assert.equal(safeHref("http://a.example"), "http://a.example")
  for (const bad of ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html,<b>", "vbscript:x", "//evil.example", "/relative", "https://a.example/\"onmouseover=alert(1)", "https://a .example", ""]) {
    assert.equal(safeHref(bad), null, bad)
  }
})

test("markdownBlocks: lists, a dropped quote marker, and kept line breaks", () => {
  const blocks = markdownBlocks("> Proposal sent.\nLine two\n- one\n- **two**\n1. first\n2. second\nafter")
  assert.deepEqual(blocks, [
    { lines: [[{ text: "Proposal sent." }], [{ text: "Line two" }]] },
    { list: "ul", items: [[{ text: "one" }], [{ strong: [{ text: "two" }] }]] },
    { list: "ol", items: [[{ text: "first" }], [{ text: "second" }]] },
    { lines: [[{ text: "after" }]] }
  ])
})

// A tiny DOM: elements and text nodes, enough to see what renderMarkdown builds.
function fakeDocument() {
  const d = {
    createTextNode: (text) => ({ nodeType: 3, text, get textContent() { return this.text } }),
    createElement: (tag) => {
      const el = {
        nodeType: 1, tagName: tag.toUpperCase(), children: [], attributes: {}, style: {}, ownerDocument: d,
        setAttribute(k, v) { this.attributes[k] = String(v) },
        append(...nodes) { this.children.push(...nodes) },
        replaceChildren(...nodes) { this.children = nodes },
        get textContent() { return this.children.map((c) => c.textContent).join("") },
        set textContent(v) { this.children = [d.createTextNode(String(v))] }
      }
      return el
    }
  }
  return d
}
const allElements = (el) => el.children.filter((c) => c.nodeType === 1).flatMap((c) => [c, ...allElements(c)])

test("renderMarkdown builds nodes: bold, a list, a safe link", () => {
  const d = fakeDocument()
  const el = d.createElement("div")
  renderMarkdown(el, "**Pro** is $49.\n- one\n- see [docs](https://alex.build/packages)", d)
  const tags = allElements(el).map((e) => e.tagName)
  assert.deepEqual(tags, ["STRONG", "UL", "LI", "LI", "A"])
  const link = allElements(el).find((e) => e.tagName === "A")
  assert.deepEqual(link.attributes, { href: "https://alex.build/packages", target: "_blank", rel: "noopener noreferrer nofollow" })
  assert.equal(el.textContent, "Pro is $49.onesee docs", "no break added beside a list")
})

// CONTROL: drop the safeHref check from markdownInline and this fails: an A with
// a javascript: href appears. The module test above keeps innerHTML out entirely.
test("renderMarkdown: an XSS attempt shows as its own characters", () => {
  const d = fakeDocument()
  const el = d.createElement("div")
  const attack = `<img src=x onerror=alert(1)> **<script>alert(2)</script>** [click](javascript:alert(3)) [a](javascript:void0) [b](data:text/html;base64,PHNjcmlwdD4=) [c](https://a.example/"onmouseover=x) \`<b>\``
  renderMarkdown(el, attack, d)
  const elements = allElements(el)
  assert.deepEqual(elements.map((e) => e.tagName), ["STRONG", "CODE"], "no IMG, SCRIPT, A or B element")
  assert.equal(el.textContent, attack.replace("**<script>alert(2)</script>**", "<script>alert(2)</script>").replace("`<b>`", "<b>"))
  for (const e of elements) assert.deepEqual(e.attributes, {}, "no attribute but a safe link's")
})

test("a rendered agent turn shows Markdown; a visitor's turn keeps its asterisks", async () => {
  const d = fakeDocument()
  const page = standIn()
  const nodes = []
  const log = page.root.querySelector("[data-agent-chat-log]")
  log.querySelectorAll = () => nodes
  log.appendChild = (n) => nodes.push(n)
  const make = () => {
    const lines = { "[data-agent-chat-text]": d.createElement("div"), "[data-agent-chat-failed]": { hidden: true }, "[data-agent-chat-held]": { hidden: true } }
    const node = { dataset: {}, lines, querySelector: (s) => lines[s] || null, after(n) { nodes.push(n) } }
    return node
  }
  const template = { content: { firstElementChild: { cloneNode: make } } }
  const query = page.root.querySelector
  page.root.querySelector = (s) => (s.startsWith("template") ? template : query(s))
  const { asks, fetcher } = deferredFetch()
  mountStandIn(page, fetcher)
  asks[0].answer([{ id: 1, role: "user", status: "answered", text: "is **Pro** good?" }, { id: 1, role: "agent", status: "answered", text: "> **Yes.**" }])
  await flush()
  const [user, agent] = nodes.map((n) => n.lines["[data-agent-chat-text]"])
  assert.equal(user.textContent, "is **Pro** good?")
  assert.deepEqual(allElements(user), [])
  assert.equal(agent.textContent, "Yes.")
  assert.deepEqual(allElements(agent).map((e) => e.tagName), ["STRONG"])
})
