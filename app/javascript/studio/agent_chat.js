// studio/agent_chat: the shared agent chat's thread (studio/agent_chat/_chat;
// docs/AGENT_CHAT.md). The hub holds the conversation; this page asks its own
// app for it (GET /agent_chat/turns, POST /agent_chat/messages), which proxies.
//
// The look is the ERB: each turn is a clone of a <template data-agent-chat-template>
// (studio/agent_chat/_turn), filled with text nodes, never HTML (MARKDOWN below).
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
//   REVEAL   the composer sticks over the window's bottom, so on a short window the
//            thread's end sits under it. On load and after a new turn the page
//            scrolls that end clear of the composer, with the same manners as
//            FOLLOW: not for an empty thread, not for a reader who scrolled the page
//            up (revealFollowing, until their own send), and never during a hold,
//            when it waits for the button to be let go.
//   REFRESH  the public hook for code outside the chat (studio/agent_chat_voice, a
//            host's own composer): dispatch studio:agent-chat:refresh on the
//            chat's section, optionally with {detail: {turn}}, a turn the app
//            just answered. The turn shows at once, the chat follows it, and it
//            polls now; a poll already in flight is followed by one more, so a
//            refresh is never swallowed.
//   SENT     a typed send the app took dispatches studio:agent-chat:sent on the
//            chat's section, {detail: {turn}}; studio/agent_chat_voice clears its
//            old line on it.
//   HELD     a turn the hub holds (status "held": stored, no automatic answer is
//            coming) is settled and says so, and never asks for a resend. A hub
//            that still reports it as "failed" gets the failed line.
//   TYPING   the typing line shows while the hub says an answer is pending:
//            "thinking", then "typing" once a turn's status is "typing".
//   OPENER   data-agent-chat-opener on the section: words the chat sends as the
//            visitor's first message once its thread has loaded, so the agent
//            starts answering at once (studio/talk_to_agent sets it as its modal
//            opens). Sent once per data-agent-chat-opener-key per tab
//            (sessionStorage): opening the same topic again shows the thread and
//            sends nothing. A send the app refuses puts the words in the box.
//            A visitor who sends before the thread loads gets the opener posted
//            first, then their words; it is never dropped and never sent twice.
//   MARKDOWN an agent turn's words show a small, safe Markdown subset (bold,
//            italics, code, http(s) links, lists, line breaks), built as nodes,
//            never HTML; a visitor's words stay plain text (markdownBlocks).
//   TYPE-IN  data-agent-chat-reveal="true" on the section: an agent answer that
//            arrives while the chat is open types itself in (revealPlan, about
//            REVEAL_CPS characters a second, REVEAL_MIN_MS to REVEAL_MAX_MS), as
//            the hub's agent_reveal does. The thread loaded on open, and every
//            answer under prefers-reduced-motion, shows at once. While it types
//            the log is aria-busy, so a screen reader hears the answer once.
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
export const REVEAL_GAP_PX = 12
export const INVALID_TOKEN = "invalid_token"
export const EXPIRED_MESSAGE = "This page has expired. Copy your message, then reload the page to send it."
export const RECORDER_STATE_EVENT = "studio:voice-recorder:state"
const HOLDING = "[data-voice-recorder-state='recording'],[data-voice-recorder-state='starting']"
export const REFRESH_EVENT = "studio:agent-chat:refresh"
export const SENT_EVENT = "studio:agent-chat:sent"
export const OPENER_STORAGE_PREFIX = "studio:agent-chat:opener:"
export const REVEAL_CPS = 420
export const REVEAL_MIN_MS = 450
export const REVEAL_MAX_MS = 2600
export const REVEAL_FRAME_MS = 32
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

// How many pixels of the thread's end the composer (or the window's bottom) hides;
// zero or less when it is clear of both. Rects are the elements' own.
export function coveredPx(endRect, composerRect, windowHeight) {
  return endRect.bottom - Math.min(composerRect.top, windowHeight)
}

// The page's authenticity token: the form's own field, else the csrf meta.
export function csrfToken(form, doc = globalThis.document) {
  const field = form && form.querySelector("input[name='authenticity_token']")
  if (field && field.value) return field.value
  const meta = doc && doc.querySelector("meta[name='csrf-token']")
  return meta ? meta.getAttribute("content") : null
}

// How a new answer of `length` characters types in: its duration in ms, clamped
// to REVEAL_MIN_MS..REVEAL_MAX_MS, and how many characters show `elapsed` ms in.
export function revealPlan(length, elapsed) {
  const total = Math.max(0, Number(length) || 0)
  const duration = Math.min(REVEAL_MAX_MS, Math.max(REVEAL_MIN_MS, Math.round((total / REVEAL_CPS) * 1000)))
  const shown = elapsed >= duration ? total : Math.floor((total * Math.max(0, elapsed)) / duration)
  return { duration, shown }
}

// The sessionStorage key an opener is remembered under; null with no key.
export function openerStorageKey(key) {
  const name = String(key ?? "").trim()
  return name ? `${OPENER_STORAGE_PREFIX}${name}` : null
}

// sessionStorage, or null where the browser refuses it (a private window, a
// sandboxed frame): the opener is then sent on every open.
function sessionStore() {
  try { return globalThis.sessionStorage || null } catch (_error) { return null }
}

function prefersReducedMotion() {
  try { return Boolean(globalThis.matchMedia && globalThis.matchMedia("(prefers-reduced-motion: reduce)").matches) } catch (_error) { return false }
}

// MARKDOWN: an agent turn's words as a small, safe subset of Markdown, for agent
// turns only (a visitor's words stay plain text). markdownBlocks is pure: it turns
// the words into paragraphs and lists of inline pieces. renderMarkdown builds them
// as DOM nodes with createElement and text nodes, never as HTML, so any other
// markup in the words shows as the characters it is.
//
//   **bold** __bold__   *italics*   `code`   [label](https://…)
//   "- ", "* ", "+ " and "1. " lines make a list; a leading "> " is dropped;
//   any other line break stays a line break.
//
// A link's target must be http: or https: (SAFE_LINK); anything else shows as
// its own text. No _underscore_ italics: snake_case words are common in answers,
// and the regex stays free of lookbehind, which older Safari cannot parse.
export const SAFE_LINK = /^https?:\/\/[^\s<>"'`]+$/i
const INLINE = /\*\*([^\s*](?:[^\n]*?[^\s*])?)\*\*|__([^\s_](?:[^\n]*?[^\s_])?)__|\[([^\]\n]+)\]\(([^()\s]+)\)|`([^`\n]+)`|\*([^*\s](?:[^*\n]*?[^*\s])?)\*/g
const BULLET = /^\s{0,3}[-*+]\s+(.*)$/
const NUMBERED = /^\s{0,3}\d{1,3}[.)]\s+(.*)$/
const QUOTE = /^\s{0,3}>\s?/

export function safeHref(url) {
  const href = String(url ?? "").trim()
  if (!SAFE_LINK.test(href)) return null
  try {
    const parsed = new URL(href)
    return parsed.protocol === "http:" || parsed.protocol === "https:" ? href : null
  } catch (_error) { return null }
}

// Inline pieces: {text} | {strong: [...]} | {em: [...]} | {code} | {link, href}.
export function markdownInline(text) {
  const pieces = []
  const words = String(text ?? "")
  let at = 0
  // A fresh regex per call: bold and italics recurse, and a shared /g regex's
  // lastIndex would jump.
  const inline = new RegExp(INLINE.source, "g")
  for (let match = inline.exec(words); match; match = inline.exec(words)) {
    const [whole, bold, bold2, label, url, code, em] = match
    let piece = null
    if (bold != null || bold2 != null) piece = { strong: markdownInline(bold ?? bold2) }
    else if (label != null) { const href = safeHref(url); if (href) piece = { link: label, href } }
    else if (code != null) piece = { code }
    else piece = { em: markdownInline(em) }
    if (!piece) continue
    if (match.index > at) pieces.push({ text: words.slice(at, match.index) })
    pieces.push(piece)
    at = match.index + whole.length
  }
  if (at < words.length) pieces.push({ text: words.slice(at) })
  return pieces
}

// Blocks: {lines: [inline, ...]} for a run of text lines, {list: "ul"|"ol", items: [inline, ...]}.
export function markdownBlocks(text) {
  const blocks = []
  for (const raw of String(text ?? "").split(/\r?\n/)) {
    const line = raw.replace(QUOTE, "")
    const bullet = line.match(BULLET)
    const numbered = bullet ? null : line.match(NUMBERED)
    const kind = bullet ? "ul" : numbered ? "ol" : null
    const last = blocks.at(-1)
    if (kind) {
      const item = markdownInline((bullet || numbered)[1])
      if (last && last.list === kind) last.items.push(item)
      else blocks.push({ list: kind, items: [item] })
    } else if (last && last.lines) {
      last.lines.push(markdownInline(line))
    } else {
      blocks.push({ lines: [markdownInline(line)] })
    }
  }
  return blocks
}

function inlineNodes(d, pieces) {
  return pieces.map((piece) => {
    if (piece.text != null) return d.createTextNode(piece.text)
    if (piece.code != null) { const el = d.createElement("code"); el.textContent = piece.code; return el }
    if (piece.link != null) {
      const el = d.createElement("a")
      el.setAttribute("href", piece.href)
      el.setAttribute("target", "_blank")
      el.setAttribute("rel", "noopener noreferrer nofollow")
      el.style.textDecoration = "underline"
      el.textContent = piece.link
      return el
    }
    const el = d.createElement(piece.strong ? "strong" : "em")
    el.append(...inlineNodes(d, piece.strong || piece.em))
    return el
  })
}

// Fills `el` with the words as Markdown nodes. Where the element cannot build
// nodes (no document), the words go in as text, as before.
export function renderMarkdown(el, words, doc = globalThis.document) {
  const d = (el && el.ownerDocument) || doc
  if (!el || !d || typeof d.createElement !== "function" || typeof el.replaceChildren !== "function") {
    if (el) el.textContent = String(words ?? "")
    return
  }
  const nodes = []
  for (const block of markdownBlocks(words)) {
    if (block.list) {
      const list = d.createElement(block.list)
      list.style.paddingLeft = "1.25rem"
      list.style.listStyle = block.list === "ul" ? "disc" : "decimal"
      for (const item of block.items) {
        const li = d.createElement("li")
        li.append(...inlineNodes(d, item))
        list.append(li)
      }
      nodes.push(list)
    } else {
      // The text keeps its own line breaks (the turn's text is pre-wrap); a list
      // sits on its own lines, so no break is added next to one.
      block.lines.forEach((line, index) => {
        if (index > 0) nodes.push(d.createTextNode("\n"))
        nodes.push(...inlineNodes(d, line))
      })
    }
  }
  el.replaceChildren(...nodes)
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
  clearTimer = (id) => globalThis.clearTimeout(id),
  CustomEventClass = globalThis.CustomEvent,
  storage = sessionStore(),
  reducedMotion = prefersReducedMotion
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
  const opener = String(root.dataset.agentChatOpener || "").trim()
  const openerKey = openerStorageKey(root.dataset.agentChatOpenerKey)
  const typeIn = root.dataset.agentChatReveal === "true"

  const state = { turns: [], pending: false, waitingSince: null, offline: false, inFlight: false, pollAgain: false, sending: false, timer: null, alive: true, following: true, revealFollowing: true, revealOwed: false, loaded: false, typing: new Map(), openerPhase: "owed", openerPost: null }

  const onScroll = () => { state.following = isFollowing(log) }
  log.addEventListener("scroll", onScroll, { passive: true })

  function toEnd() { log.scrollTop = log.scrollHeight }

  // The last thing in the thread's column above the composer that is showing.
  function threadEnd() {
    return [offlineNote, typing].find((el) => el && el.hidden === false) || log
  }

  function windowHeight() {
    return doc && doc.documentElement ? doc.documentElement.clientHeight : 0
  }

  function covered() {
    const end = threadEnd()
    if (!form || !end.getBoundingClientRect || !form.getBoundingClientRect) return 0
    return coveredPx(end.getBoundingClientRect(), form.getBoundingClientRect(), windowHeight())
  }

  // scrollIntoView, not window.scrollBy: a host may scroll an inner container. The
  // margin is what the composer takes off the bottom of the window once it sticks:
  // its height and its sticky bottom, not its top now, because a composer lower down
  // the page is not stuck until this scroll has run. Instant, so a host's smooth
  // scrolling cannot leave the page moving when a hold begins.
  function revealEnd() {
    if (root.querySelector(HOLDING)) { state.revealOwed = true; return }
    state.revealOwed = false
    if (!state.turns.length || covered() <= 0) return
    const end = threadEnd()
    const stuckAt = parseFloat(globalThis.getComputedStyle?.(form).bottom) || 0
    end.style.scrollMarginBottom = `${form.getBoundingClientRect().height + stuckAt + REVEAL_GAP_PX}px`
    end.scrollIntoView({ block: "end", behavior: "instant" })
    end.style.scrollMarginBottom = ""
  }

  // A scroll of the page or a host's container says whether the reader is still at
  // the thread's end. The log's own scroll, the box's and the picker's say nothing:
  // only something that holds the chat can move it. A reveal passes this too, and
  // ends there.
  const onPageScroll = (event) => {
    if (!event.target || !event.target.contains || !event.target.contains(root)) return
    state.revealFollowing = covered() <= FOLLOW_PX
  }

  const onRecorderState = () => {
    if (state.revealOwed && !root.querySelector(HOLDING) && state.following && state.revealFollowing) revealEnd()
  }

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
      const words = String(turn.text ?? "")
      const agent = turn.role === "agent"
      if (text && state.typing.has(key)) {
        if (state.typing.get(key).words !== words) { stopTyping(key); showWords(text, words, agent) }
      } else if (text && shownWords(text, agent) !== words) {
        if (typeIn && state.loaded && agent && words && !reducedMotion()) startTyping(key, text, words)
        else showWords(text, words, agent)
      }
      const failed = node.querySelector("[data-agent-chat-failed]")
      if (failed) failed.hidden = turn.status !== "failed"
      const held = node.querySelector("[data-agent-chat-held]")
      if (held) held.hidden = turn.status !== "held"
    }
    const waiting = state.pending || state.turns.some((turn) => !settled(turn))
    if (typing) typing.hidden = !waiting
    if (phase) phase.dataset.phase = typingPhase(state.turns)
    if (follow) {
      toEnd()
      if (state.revealFollowing) revealEnd()
    }
  }

  // What a turn's text element shows: an agent's words as Markdown, a visitor's
  // as text. `shown` remembers the words behind each element, since an agent's
  // rendered text no longer reads back as its Markdown.
  const shown = new WeakMap()
  function showWords(el, words, agent) {
    shown.set(el, words)
    if (agent) renderMarkdown(el, words, doc)
    else el.textContent = words
  }
  // An agent turn the page rendered itself (studio/agent_chat/_turn prints raw
  // words) has no entry, so it is rendered once as Markdown.
  function shownWords(el, agent) {
    if (shown.has(el)) return shown.get(el)
    return agent ? null : el.textContent
  }

  // TYPE-IN: one answer's words, filled in REVEAL_FRAME_MS steps.
  function startTyping(key, el, words) {
    const started = now()
    const entry = { words, timer: null }
    state.typing.set(key, entry)
    showWords(el, "", true)
    if (log && log.setAttribute) log.setAttribute("aria-busy", "true")
    const step = () => {
      if (!state.alive || state.typing.get(key) !== entry) return
      const { shown: count } = revealPlan(words.length, now() - started)
      showWords(el, words.slice(0, count), true)
      if (state.following) toEnd()
      if (count >= words.length) { stopTyping(key); return }
      entry.timer = setTimer(step, REVEAL_FRAME_MS)
    }
    step()
  }

  function stopTyping(key) {
    const entry = state.typing.get(key)
    if (!entry) return
    clearTimer(entry.timer)
    state.typing.delete(key)
    if (!state.typing.size && log && log.removeAttribute) log.removeAttribute("aria-busy")
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
      if (!state.loaded) {
        state.loaded = true
        sendOpener()
      }
    } catch (_error) {
      setOffline(true)
    } finally {
      state.inFlight = false
      if (state.pollAgain) {
        state.pollAgain = false
        if (state.alive) poll()
      } else {
        schedule()
      }
    }
  }

  // The public refresh hook (REFRESH above). Returns poll's promise, or nothing
  // when the poll in flight will be followed by another.
  function refresh({ turn } = {}) {
    if (!state.alive) return undefined
    if (turn) {
      state.turns = mergeTurns(state.turns, [turn])
      state.pending = turn.status !== "held"
      state.following = true
      state.revealFollowing = true
      state.waitingSince = now()
      setOffline(false)
      render()
      toEnd()
    }
    if (state.inFlight) {
      state.pollAgain = true
      return undefined
    }
    clearTimer(state.timer)
    return poll()
  }

  function onRefresh(event) {
    refresh(event.detail || {})
  }

  // OPENER: the section's opener, once per key per tab. It goes once the thread
  // has loaded, or at once, AHEAD of the visitor's words, when they send before the
  // thread loads (submit). The tab remembers it as its POST starts (so a chat
  // mounted again mid-flight cannot send it twice) and forgets it if that POST
  // fails; nothing marks it without posting it. While another send is in flight it
  // stays owed, unmarked, and the next send carries it first.
  function sendOpener() {
    if (!opener || state.openerPhase !== "owed") return state.openerPost || undefined
    if (openerKey && storage) {
      try {
        if (storage.getItem(openerKey)) { state.openerPhase = "done"; return undefined }
      } catch (_error) { /* a refused store sends it anyway */ }
    }
    // The thread already ends with these words from the visitor (another tab
    // sent them): showing it is enough.
    const last = state.turns.filter((turn) => turn.role !== "agent").at(-1)
    if (last && String(last.text ?? "").trim() === opener) { state.openerPhase = "done"; return undefined }
    if (state.sending) return undefined
    state.openerPhase = "posting"
    if (openerKey && storage) {
      try { storage.setItem(openerKey, "1") } catch (_error) { /* a refused store sends it anyway */ }
    }
    state.openerPost = post(opener, { typed: false }).finally(() => {
      state.openerPhase = "done"
      state.openerPost = null
    })
    return state.openerPost
  }

  function forgetOpener() {
    if (!openerKey || !storage) return
    try { storage.removeItem(openerKey) } catch (_error) { /* nothing to forget */ }
  }

  // A refused or failed opener goes into the box, after anything already typed,
  // so the visitor can send it themselves.
  function keepWords(text) {
    if (!input) return
    const typed = (input.value || "").trim()
    input.value = typed ? `${typed} ${text}` : text
  }

  async function submit(event) {
    if (event) event.preventDefault()
    const text = (input.value || "").trim()
    if (!text) return
    // The opener goes first, even before the thread has loaded, and a send
    // waits for an opener already on its way: the visitor's words are never
    // dropped for it, and they always follow it.
    if (state.openerPhase === "owed") await sendOpener()
    if (state.openerPost) await state.openerPost
    if (state.sending) return
    await post(text, { typed: true })
  }

  // One message to the app: the composer's words (typed) or the opener.
  async function post(text, { typed }) {
    if (state.sending) return
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
        if (typed) input.value = ""
        state.turns = mergeTurns(state.turns, [data.turn])
        state.pending = data.turn.status !== "held"
        state.following = true
        state.revealFollowing = true
        setOffline(false)
        render()
        toEnd()
        if (status) status.textContent = "Sent."
        root.dispatchEvent(new CustomEventClass(SENT_EVENT, { detail: { turn: data.turn } }))
        state.waitingSince = now()
        clearTimer(state.timer)
        state.timer = setTimer(poll, POLL_MS)
      } else {
        if (!typed) { forgetOpener(); keepWords(text) }
        showError(data.reason === INVALID_TOKEN ? EXPIRED_MESSAGE : data.error || `Couldn't send that to ${name}. Try again.`)
        if (status) status.textContent = ""
      }
    } catch (_error) {
      if (!typed) { forgetOpener(); keepWords(text) }
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
  root.addEventListener(REFRESH_EVENT, onRefresh)
  root.addEventListener(RECORDER_STATE_EVENT, onRecorderState)
  doc && doc.addEventListener && doc.addEventListener("visibilitychange", onVisible)
  // Scroll events do not bubble; capture hears the page's and any container's.
  doc && doc.addEventListener && doc.addEventListener("scroll", onPageScroll, { capture: true, passive: true })
  root.dataset.agentChatReady = "true"
  poll()

  return {
    state,
    poll,
    refresh,
    submit,
    sendOpener,
    destroy() {
      state.alive = false
      clearTimer(state.timer)
      for (const key of Array.from(state.typing.keys())) stopTyping(key)
      log.removeEventListener("scroll", onScroll)
      form && form.removeEventListener("submit", submit)
      input && input.removeEventListener("keydown", onKeydown)
      retry && retry.removeEventListener("click", onRetry)
      root.removeEventListener(REFRESH_EVENT, onRefresh)
      root.removeEventListener(RECORDER_STATE_EVENT, onRecorderState)
      doc && doc.removeEventListener && doc.removeEventListener("visibilitychange", onVisible)
      doc && doc.removeEventListener && doc.removeEventListener("scroll", onPageScroll, { capture: true })
      delete root.dataset.agentChatReady
    }
  }
}
