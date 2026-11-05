// [unit] studio/agent_chat: how the thread merges turns, which `after` a poll
// sends, how often it polls, the typing phase, the follow rule and the CSRF
// token. Loaded from source as a data: module, like knowledge_transcript.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/agent_chat.js", import.meta.url), "utf8")
const {
  settled, mergeTurns, turnKey, afterCursor, pollDelay, typingPhase, isFollowing, csrfToken, turnsUrl, mountAgentChat,
  POLL_MS, SLOW_MS, SLOW_AFTER_MS, IDLE_MS, OFFLINE_MS, LIMIT, REFRESH_EVENT, SENT_EVENT
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
