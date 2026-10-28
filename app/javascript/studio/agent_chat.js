// studio/agent_chat: the shared agent chat's thread (studio/agent_chat/_chat;
// docs/AGENT_CHAT.md). The hub holds the conversation; this page asks its own
// app for it (GET /agent_chat/turns, POST /agent_chat/messages), which proxies.
//
// The look is the ERB: each turn is a clone of a <template data-agent-chat-template>
// (studio/agent_chat/_turn), filled with textContent, never HTML.
//
//   LOAD     on connect, the thread's latest turns; a failure shows the offline
//            notice with Try again (and retries itself, slowly).
//   POLL     answers arrive by polling, as on the hub's /build: every POLL_MS
//            while an answer is pending, slowing to SLOW_MS once it has waited
//            SLOW_AFTER_MS (a hub that is down is not hammered); every IDLE_MS
//            otherwise, and not at all while the tab is hidden (it asks at once
//            when the tab comes back). Each poll asks
//            for turns AFTER the last settled one (afterCursor), so a turn still
//            pending is asked about again until it settles.
//   SEND     Enter sends, Shift+Enter is a new line. The words stay in the box
//            until the app answers 201; a refusal shows its reason above them.
//   FOLLOW   the thread stays at its end while the reader is within FOLLOW_PX of
//            it, and always after their own send (the hub's chat_follow rule).
//   TYPING   the typing line shows while the hub says an answer is pending:
//            "thinking", then "typing" once a turn's status is "typing".
//
// It imports nothing, so test/javascript/agent_chat.test.mjs loads it as a
// data: module; studio/controllers/agent_chat_controller mounts it.

export const POLL_MS = 2500
export const SLOW_MS = 10000
export const SLOW_AFTER_MS = 120000
export const IDLE_MS = 30000
export const OFFLINE_MS = 15000
export const FOLLOW_PX = 20
export const LIMIT = 50
const UNSETTLED = new Set(["pending", "typing"])

export function settled(turn) {
  return !UNSETTLED.has(String(turn && turn.status))
}

// A turn's identity is its id AND its role: the hub answers one message row as
// two turns with the row's id, the visitor's words ("user") and, once answered,
// the agent's ("agent"). Keyed by id alone, the answer would replace the words.
export function turnKey(turn) {
  return `${turn.id}:${turn.role === "agent" ? "agent" : "user"}`
}

// Merge `incoming` turns into `turns` (both oldest first): a known (id, role) is
// replaced in place. A new agent turn goes right after its own user turn (same
// id), so when the visitor sends A then B before A is answered, A's answer sits
// under A, not under B. Any other new turn is appended. Returns a new array.
export function mergeTurns(turns, incoming) {
  const merged = turns.slice()
  for (const turn of incoming || []) {
    if (!turn || turn.id == null) continue
    const key = turnKey(turn)
    const at = merged.findIndex((known) => turnKey(known) === key)
    if (at !== -1) { merged[at] = turn; continue }
    const own = turn.role === "agent" ? merged.findIndex((known) => turnKey(known) === `${turn.id}:user`) : -1
    if (own !== -1) merged.splice(own + 1, 0, turn)
    else merged.push(turn)
  }
  return merged
}

// The `after` a poll sends: the id of the last turn before the first one still
// unsettled (so that one is asked about again), or of the last turn when all
// are settled. null asks for the latest turns. `after` is a hub ROW id (rows
// with id > after): an unsettled row's user turn is itself unsettled, so the
// cursor lands on an earlier row and the pending row is asked about again.
export function afterCursor(turns) {
  const first = turns.findIndex((turn) => !settled(turn))
  if (first === -1) return turns.length ? String(turns[turns.length - 1].id) : null
  return first === 0 ? null : String(turns[first - 1].id)
}

// Milliseconds to the next poll.
export function pollDelay({ waiting, waitingSince, now, offline }) {
  if (offline) return OFFLINE_MS
  if (!waiting) return IDLE_MS
  return now - (waitingSince ?? now) > SLOW_AFTER_MS ? SLOW_MS : POLL_MS
}

export function typingPhase(turns) {
  return turns.some((turn) => turn.status === "typing") ? "typing" : "thinking"
}

export function isFollowing(log, px = FOLLOW_PX) {
  return log.scrollHeight - log.clientHeight - log.scrollTop <= px
}

// The page's authenticity token: the form's own field, else the csrf meta.
export function csrfToken(form, doc = globalThis.document) {
  const field = form && form.querySelector("input[name='authenticity_token']")
  if (field && field.value) return field.value
  const meta = doc && doc.querySelector("meta[name='csrf-token']")
  return meta ? meta.getAttribute("content") : null
}

export function turnsUrl(base, { soul, after, limit = LIMIT }) {
  const params = new URLSearchParams({ soul, limit: String(limit) })
  if (after != null) params.set("after", after)
  return `${base}${base.includes("?") ? "&" : "?"}${params}`
}

export function mountAgentChat(root, {
  fetch: fetcher = globalThis.fetch.bind(globalThis),
  doc = globalThis.document,
  now = () => Date.now(),
  setTimer = (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimer = (id) => globalThis.clearTimeout(id)
} = {}) {
  const $ = (selector) => root.querySelector(selector)
  const log = $("[data-agent-chat-log]")
  const typing = $("[data-agent-chat-typing]")
  const phase = $("[data-agent-chat-phase]")
  const offlineNote = $("[data-agent-chat-offline]")
  const retry = $("[data-agent-chat-retry]")
  const form = $("[data-agent-chat-form]")
  const input = $("[data-agent-chat-input]")
  const send = $("[data-agent-chat-send]")
  const error = $("[data-agent-chat-error]")
  const status = $("[data-agent-chat-status]")
  const soul = root.dataset.agentChatSoul
  const name = root.dataset.agentChatName || "The agent"

  const state = { turns: [], pending: false, waitingSince: null, offline: false, inFlight: false, sending: false, timer: null, alive: true, following: true }

  const onScroll = () => { state.following = isFollowing(log) }
  log.addEventListener("scroll", onScroll, { passive: true })

  function toEnd() { log.scrollTop = log.scrollHeight }

  function setOffline(offline) {
    state.offline = offline
    if (offlineNote) offlineNote.hidden = !offline
  }

  function showError(text) {
    if (!error) return
    error.textContent = text || ""
    error.hidden = !text
  }

  function render() {
    const follow = state.following
    for (const turn of state.turns) {
      const key = turnKey(turn)
      let node = Array.from(log.querySelectorAll("[data-turn-key]")).find((el) => el.dataset.turnKey === key)
      if (!node) {
        const template = root.querySelector(`template[data-agent-chat-template="${turn.role === "agent" ? "agent" : "user"}"]`)
        if (!template) continue
        node = template.content.firstElementChild.cloneNode(true)
        node.dataset.turnId = String(turn.id)
        node.dataset.turnKey = key
        // Placed where mergeTurns put it: after the previous turn's element.
        const index = state.turns.indexOf(turn)
        const prevKey = index > 0 ? turnKey(state.turns[index - 1]) : null
        const prev = prevKey && Array.from(log.querySelectorAll("[data-turn-key]")).find((el) => el.dataset.turnKey === prevKey)
        if (prev) prev.after(node)
        else log.appendChild(node)
      }
      node.dataset.status = turn.status || ""
      const text = node.querySelector("[data-agent-chat-text]")
      if (text && text.textContent !== String(turn.text ?? "")) text.textContent = String(turn.text ?? "")
      const failed = node.querySelector("[data-agent-chat-failed]")
      if (failed) failed.hidden = turn.status !== "failed"
    }
    const waiting = state.pending || state.turns.some((turn) => !settled(turn))
    if (typing) typing.hidden = !waiting
    if (phase) phase.dataset.phase = typingPhase(state.turns)
    if (follow) toEnd()
  }

  function schedule() {
    if (!state.alive) return
    clearTimer(state.timer)
    const waiting = state.pending || state.turns.some((turn) => !settled(turn))
    if (waiting) state.waitingSince = state.waitingSince || now()
    else state.waitingSince = null
    state.timer = setTimer(poll, pollDelay({ waiting, waitingSince: state.waitingSince, now: now(), offline: state.offline }))
  }

  async function poll() {
    if (!state.alive) return
    const hidden = doc && doc.visibilityState === "hidden"
    if (hidden || state.inFlight) { schedule(); return }
    state.inFlight = true
    try {
      const response = await fetcher(turnsUrl(root.dataset.agentChatTurnsUrl, { soul, after: afterCursor(state.turns) }), {
        headers: { Accept: "application/json" }, credentials: "same-origin"
      })
      if (!response.ok) throw new Error(`turns ${response.status}`)
      const data = await response.json()
      state.turns = mergeTurns(state.turns, data.turns)
      state.pending = data.pending === true
      setOffline(false)
      render()
    } catch (_error) {
      setOffline(true)
    } finally {
      state.inFlight = false
      schedule()
    }
  }

  async function submit(event) {
    if (event) event.preventDefault()
    const text = (input.value || "").trim()
    if (!text || state.sending) return
    state.sending = true
    if (send) send.disabled = true
    showError("")
    if (status) status.textContent = `Sending to ${name}…`
    try {
      const headers = { Accept: "application/json", "Content-Type": "application/json" }
      const token = csrfToken(form, doc)
      if (token) headers["X-CSRF-Token"] = token
      const response = await fetcher(form.getAttribute("action"), {
        method: "POST", headers, credentials: "same-origin", body: JSON.stringify({ soul, text })
      })
      let data = {}
      try { data = await response.json() } catch (_e) { data = {} }
      if (response.status === 201 && data.turn) {
        input.value = ""
        state.turns = mergeTurns(state.turns, [data.turn])
        state.pending = true
        state.following = true
        setOffline(false)
        render()
        toEnd()
        if (status) status.textContent = "Sent."
        state.waitingSince = now()
        clearTimer(state.timer)
        state.timer = setTimer(poll, POLL_MS)
      } else {
        showError(data.error || `Couldn't send that to ${name}. Try again.`)
        if (status) status.textContent = ""
      }
    } catch (_error) {
      showError(`Can't reach ${name} right now. Your message is still here; try again in a moment.`)
      if (status) status.textContent = ""
    } finally {
      state.sending = false
      if (send) send.disabled = false
    }
  }

  function onKeydown(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
    event.preventDefault()
    submit()
  }

  function onRetry() {
    clearTimer(state.timer)
    poll()
  }

  // A tab that comes back asks at once rather than waiting out an idle poll.
  function onVisible() {
    if (doc && doc.visibilityState === "visible" && !state.inFlight) { clearTimer(state.timer); poll() }
  }

  form && form.addEventListener("submit", submit)
  input && input.addEventListener("keydown", onKeydown)
  retry && retry.addEventListener("click", onRetry)
  doc && doc.addEventListener && doc.addEventListener("visibilitychange", onVisible)
  root.dataset.agentChatReady = "true"
  poll()

  return {
    state,
    poll,
    submit,
    destroy() {
      state.alive = false
      clearTimer(state.timer)
      log.removeEventListener("scroll", onScroll)
      form && form.removeEventListener("submit", submit)
      input && input.removeEventListener("keydown", onKeydown)
      retry && retry.removeEventListener("click", onRetry)
      doc && doc.removeEventListener && doc.removeEventListener("visibilitychange", onVisible)
      delete root.dataset.agentChatReady
    }
  }
}
