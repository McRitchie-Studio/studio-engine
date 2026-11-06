// [unit] studio/talk_to_agent: which clicks the modal takes, what a link asks
// for, and how the opened panel gets its chat. Loaded from source as a data:
// module, like agent_chat.test.mjs.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const source = readFileSync(new URL("../../app/javascript/studio/talk_to_agent.js", import.meta.url), "utf8")
const {
  talkFrom, openerKey, plainClick, dialogTitle, mountTalkToAgent, TALK_SELECTOR, TALK_MODAL_ID, PANEL_EVENT, TOPIC_MAX, OPENER_MAX
} = await import(`data:text/javascript,${encodeURIComponent(source)}`)

test("the module imports nothing and never writes HTML", () => {
  assert.doesNotMatch(source, /^\s*import\s/m)
  assert.doesNotMatch(source, /innerHTML|insertAdjacentHTML|outerHTML/)
})

test("talkFrom reads soul, topic and opener, and defaults the opener from the topic", () => {
  assert.deepEqual(talkFrom({ dataset: { talkSoul: "alex", talkTopic: " Pro ", talkOpener: "Tell me\n about Pro." } }),
                   { soul: "alex", topic: "Pro", opener: "Tell me about Pro." })
  assert.equal(talkFrom({ dataset: { talkSoul: "alex", talkTopic: "Team" } }).opener, "I'd like to talk about Team.")
  assert.equal(talkFrom({ dataset: { talkSoul: "alex" } }).opener, "", "no topic and no opener: nothing to send")
  assert.equal(talkFrom(null).soul, "")
})

test("talkFrom caps the topic and the opener", () => {
  const long = "x".repeat(2000)
  const asked = talkFrom({ dataset: { talkSoul: "alex", talkTopic: long, talkOpener: long } })
  assert.equal(asked.topic.length, TOPIC_MAX)
  assert.equal(asked.opener.length, OPENER_MAX)
})

test("openerKey is per soul and topic", () => {
  assert.equal(openerKey("alex", "Pro"), "alex:Pro")
  assert.equal(openerKey("alex", ""), "alex:general")
})

test("plainClick: only an unmodified primary click", () => {
  assert.equal(plainClick({ button: 0 }), true)
  assert.equal(plainClick({ button: 1 }), false, "a middle click opens a tab")
  assert.equal(plainClick({ button: 0, metaKey: true }), false)
  assert.equal(plainClick({ button: 0, ctrlKey: true }), false)
  assert.equal(plainClick({ button: 0, shiftKey: true }), false)
  assert.equal(plainClick({ button: 0, defaultPrevented: true }), false)
  assert.equal(plainClick(null), false)
})

test("dialogTitle names the agent and the topic", () => {
  assert.equal(dialogTitle("Alex", "Pro"), "Talk to Alex about Pro")
  assert.equal(dialogTitle("Alex", ""), "Talk to Alex")
})

// ---- the mounted modal ----------------------------------------------------------

function page({ withStore = true } = {}) {
  const docListeners = {}
  const doc = { addEventListener: (type, fn) => { docListeners[type] = fn }, removeEventListener: (type) => { delete docListeners[type] } }
  const opened = []
  const store = withStore ? { open: (id, props) => opened.push({ id, props }) } : null
  const rootListeners = {}
  const chat = { dataset: {}, cloneNode() { const copy = { dataset: {} }; this.copies.push(copy); return copy }, copies: [] }
  const template = { content: { firstElementChild: chat } }
  const root = {
    dataset: { talkToAgentSoul: "alex", talkToAgentName: "Alex", talkToAgentStore: "studioTalkToAgent" },
    querySelector: (s) => (s === "template[data-talk-to-agent-chat]" ? template : null),
    addEventListener: (type, fn) => { rootListeners[type] = fn },
    removeEventListener: (type) => { delete rootListeners[type] }
  }
  const talk = mountTalkToAgent(root, { doc, store: () => store })
  return { talk, root, doc, docListeners, rootListeners, opened, chat }
}

function linkFor(dataset) {
  const link = { dataset }
  link.closest = (selector) => (selector === TALK_SELECTOR ? link : null)
  return link
}

function click(target, extra = {}) {
  const event = { target, button: 0, defaultPrevented: false, preventDefault() { this.defaultPrevented = true }, ...extra }
  return event
}

function panel() {
  const slot = { children: [], replaceChildren(...nodes) { this.children = nodes } }
  const title = { textContent: "Talk to Alex" }
  return { slot, title, querySelector: (s) => (s === "[data-talk-to-agent-slot]" ? slot : s === "[data-talk-to-agent-title]" ? title : null) }
}

test("a plain click on a link for this soul opens the modal and takes the click", () => {
  const p = page()
  const event = click(linkFor({ talkSoul: "alex", talkTopic: "Pro" }))
  p.docListeners.click(event)
  assert.equal(event.defaultPrevented, true)
  assert.deepEqual(p.opened, [{ id: TALK_MODAL_ID, props: { title: "Talk to Alex about Pro", topic: "Pro" } }])
})

test("the link keeps its href: another soul, a modified click, no store, or no link", () => {
  const p = page()
  const other = click(linkFor({ talkSoul: "turf_monster", talkTopic: "Pro" }))
  p.docListeners.click(other)
  const modified = click(linkFor({ talkSoul: "alex", talkTopic: "Pro" }), { metaKey: true })
  p.docListeners.click(modified)
  const nothing = click({ closest: () => null })
  p.docListeners.click(nothing)
  assert.equal(other.defaultPrevented, false)
  assert.equal(modified.defaultPrevented, false)
  assert.equal(nothing.defaultPrevented, false)
  assert.equal(p.opened.length, 0)

  const bare = page({ withStore: false })
  const event = click(linkFor({ talkSoul: "alex", talkTopic: "Pro" }))
  bare.docListeners.click(event)
  assert.equal(event.defaultPrevented, false, "a page whose host never registered follows the link")
})

// CONTROL: drop the opener lines from onPanel and the first two asserts fail:
// the modal opens on a chat that waits for the visitor to type.
test("the opened panel gets a fresh chat carrying the link's opener, its key and the type-in", () => {
  const p = page()
  p.docListeners.click(click(linkFor({ talkSoul: "alex", talkTopic: "Pro", talkOpener: "Tell me about Pro." })))
  const opened = panel()
  p.rootListeners[PANEL_EVENT]({ target: opened })
  const chat = opened.slot.children[0]
  assert.equal(chat.dataset.agentChatOpener, "Tell me about Pro.")
  assert.equal(chat.dataset.agentChatOpenerKey, "alex:Pro")
  assert.equal(chat.dataset.agentChatReveal, "true")
  assert.equal(opened.title.textContent, "Talk to Alex about Pro")
  assert.equal(p.chat.dataset.agentChatOpener, undefined, "the template itself is never marked")

  p.docListeners.click(click(linkFor({ talkSoul: "alex", talkTopic: "Team" })))
  const again = panel()
  p.rootListeners[PANEL_EVENT]({ target: again })
  assert.notEqual(again.slot.children[0], chat, "each open is a new copy")
  assert.equal(again.slot.children[0].dataset.agentChatOpener, "I'd like to talk about Team.")
})

test("destroy removes both listeners", () => {
  const p = page()
  p.talk.destroy()
  assert.equal(p.docListeners.click, undefined)
  assert.equal(p.rootListeners[PANEL_EVENT], undefined)
  assert.equal(p.root.dataset.talkToAgentReady, undefined)
})
