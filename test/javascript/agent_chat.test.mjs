// [unit] studio/agent_chat: how the thread merges turns, which `after` a poll
// sends, how often it polls, the typing phase, the follow rule and the CSRF
// token. Loaded from source as a data: module, like knowledge_transcript.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/agent_chat.js", import.meta.url), "utf8")
const {
  settled, mergeTurns, afterCursor, pollDelay, typingPhase, isFollowing, csrfToken, turnsUrl,
  POLL_MS, SLOW_MS, SLOW_AFTER_MS, IDLE_MS, OFFLINE_MS, LIMIT
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
