// studio/talk_to_agent: the talk-to-agent modal (studio/agent_chat/_talk_modal;
// docs/AGENT_CHAT.md, "Talk to an agent in a modal"). It wraps the shared agent
// chat, studio/agent_chat, in the page-scoped modal host; it is not a second
// chat.
//
//   LINKS    any element carrying data-studio-talk-to-agent opens the modal:
//
//              <a href="/chat" data-studio-talk-to-agent data-talk-soul="alex"
//                 data-talk-topic="Pro" data-talk-opener="Tell me about Pro.">
//
//            The click is taken only when the soul is this modal's, no modifier
//            key is held and the host's Alpine store is there. Otherwise the
//            link does what its href says, so a page whose modal failed to load
//            still reaches the chat.
//   OPEN     the store opens TALK_MODAL_ID; the panel the host clones in asks
//            for its chat (PANEL_EVENT), and this module fills it with a fresh
//            copy of the chat from the partial's <template>, marked with the
//            link's opener (data-agent-chat-opener, keyed by soul and topic)
//            and the type-in. studio/agent_chat then loads the thread and sends
//            the opener, so the agent is answering while the card animates in.
//   CLOSE    the host drops the panel; the chat's controller disconnects and
//            stops polling. The thread stays on the hub: the next open shows it.
//
// It imports nothing, so test/javascript/talk_to_agent.test.mjs loads it as a
// data: module; studio/controllers/talk_to_agent_controller mounts it.

export const TALK_SELECTOR = "[data-studio-talk-to-agent]"
export const TALK_MODAL_ID = "talk-to-agent"
export const PANEL_EVENT = "studio:talk-to-agent:panel"
export const TOPIC_MAX = 80
export const OPENER_MAX = 500

function clean(value, max) {
  return String(value ?? "").replace(/\s+/g, " ").trim().slice(0, max)
}

// What a link asks for: {soul, topic, opener}. The opener defaults to a plain
// line naming the topic; with no topic and no opener there is nothing to send.
export function talkFrom(link) {
  const data = (link && link.dataset) || {}
  const topic = clean(data.talkTopic, TOPIC_MAX)
  const opener = clean(data.talkOpener, OPENER_MAX) || (topic ? `I'd like to talk about ${topic}.` : "")
  return { soul: clean(data.talkSoul, 64), topic, opener }
}

// The key an opener is sent once under (per tab): the soul and the topic.
export function openerKey(soul, topic) {
  return `${soul}:${topic || "general"}`
}

// Whether this click is the modal's to take: a plain primary click.
export function plainClick(event) {
  if (!event) return false
  if (event.defaultPrevented) return false
  if (event.button != null && event.button !== 0) return false
  return !(event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
}

// The dialog's accessible name and the header's words.
export function dialogTitle(name, topic) {
  return topic ? `Talk to ${name} about ${topic}` : `Talk to ${name}`
}

export function mountTalkToAgent(root, {
  doc = globalThis.document,
  store = (name) => (globalThis.Alpine && typeof globalThis.Alpine.store === "function" ? globalThis.Alpine.store(name) : null)
} = {}) {
  const soul = root.dataset.talkToAgentSoul
  const name = root.dataset.talkToAgentName || "the agent"
  const storeName = root.dataset.talkToAgentStore
  let current = null

  function onClick(event) {
    const link = event.target && event.target.closest ? event.target.closest(TALK_SELECTOR) : null
    if (!link || !plainClick(event)) return
    const asked = talkFrom(link)
    if (asked.soul !== soul) return
    const modals = store(storeName)
    if (!modals || typeof modals.open !== "function") return
    event.preventDefault()
    current = asked
    modals.open(TALK_MODAL_ID, { title: dialogTitle(name, asked.topic), topic: asked.topic })
  }

  // The host cloned the panel in: give it a fresh chat for the link that opened it.
  function onPanel(event) {
    const panel = event.target
    const template = root.querySelector("template[data-talk-to-agent-chat]")
    const slot = panel && panel.querySelector ? panel.querySelector("[data-talk-to-agent-slot]") : null
    if (!template || !slot || !template.content || !template.content.firstElementChild) return
    const asked = current || { topic: "", opener: "" }
    const heading = panel.querySelector("[data-talk-to-agent-title]")
    if (heading) heading.textContent = dialogTitle(name, asked.topic)
    const chat = template.content.firstElementChild.cloneNode(true)
    if (asked.opener) {
      chat.dataset.agentChatOpener = asked.opener
      chat.dataset.agentChatOpenerKey = openerKey(soul, asked.topic)
    }
    chat.dataset.agentChatReveal = "true"
    slot.replaceChildren(chat)
  }

  doc && doc.addEventListener && doc.addEventListener("click", onClick)
  root.addEventListener(PANEL_EVENT, onPanel)
  root.dataset.talkToAgentReady = "true"

  return {
    open(link) { onClick({ target: link, button: 0, preventDefault() {} }) },
    get current() { return current },
    destroy() {
      doc && doc.removeEventListener && doc.removeEventListener("click", onClick)
      root.removeEventListener(PANEL_EVENT, onPanel)
      delete root.dataset.talkToAgentReady
    }
  }
}
