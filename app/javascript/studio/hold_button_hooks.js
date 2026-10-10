// studio/hold_button_hooks: how one hold button asks its page the timeline's
// questions (studio/hold_button). It dispatches events on the button, which
// bubble:
//
//   hold-button:guard     at the press. preventDefault() refuses the hold.
//   hold-button:start     the hold began.
//   hold-button:validate  at validate_at. event.detail.waitUntil(answer)
//                         takes a boolean or a promise of one; a false or
//                         failed answer aborts the hold.
//   hold-button:early     at early_action_at. preventDefault() takes the
//                         action over: the hold never completes.
//   hold-button:success   at the full duration. preventDefault() keeps the
//                         button in its holding state for the listener to
//                         resolve; otherwise it shows its success face.
//
// Every event's detail carries { id }, the button's hold_id.
//
//   <div @hold-button:guard="ready || $event.preventDefault()"
//        @hold-button:success="submit()">
//     <%= render "studio/hold_button", hold_id: "confirm" %>
//   </div>
//
// It evaluates nothing. A button that carries one of REMOVED_HOOKS' attributes
// was written for the JavaScript-string locals this module no longer runs: every
// press on it is refused and says so on the console.
//
// With an [x-data] ancestor a press is also refused while that scope's
// `submitting` is true, so a second hold cannot double-submit.
//
// It imports nothing; test/javascript/hold_button_hooks.test.mjs loads it as a
// data: module.

// Attribute => [the removed local that wrote it, the event that answers now].
// Studio::HoldButton::REMOVED_LOCALS is the same table for the partial.
export const REMOVED_HOOKS = {
  "data-guard": ["guard", "hold-button:guard"],
  "data-on-hold-start": ["on_hold_start", "hold-button:start"],
  "data-validate": ["validate", "hold-button:validate"],
  "data-early-action": ["early_action", "hold-button:early"],
  "data-early-action-guard": ["early_action_guard", "hold-button:early"],
  "data-on-success": ["on_success", "hold-button:success"]
}

// The hooks a Hold takes, for one button.
export function holdHooks(button, { win } = {}) {
  const host = win || globalThis
  const id = () => button.getAttribute("data-hold-id") || "hold"

  const fire = (name, detail = {}) => {
    const event = new host.CustomEvent(`hold-button:${name}`, {
      bubbles: true, cancelable: true, detail: { id: id(), ...detail }
    })
    button.dispatchEvent(event)
    return event
  }

  // True, and reported, when the button carries a removed hook.
  const stale = () => {
    const found = Object.keys(REMOVED_HOOKS).filter((attribute) => button.hasAttribute(attribute))
    for (const attribute of found) {
      const [local, event] = REMOVED_HOOKS[attribute]
      host.console.error(`[hold:${id()}] ${attribute} (the ${local}: local) is no longer evaluated; ` +
                         `answer ${event} instead. The hold is refused.`)
    }
    return found.length > 0
  }

  return {
    // Refused by a removed hook, by the scope's `submitting`, or by a
    // hold-button:guard listener.
    guard() {
      if (stale()) return false
      const found = host.Alpine ? button.closest("[x-data]") : null
      if (found) {
        const data = host.Alpine.$data(found)
        if (data && data.submitting) return false
      }
      return !fire("guard").defaultPrevented
    },

    started() {
      fire("start")
    },

    // True unless a hold-button:validate listener says no. Rejects when one
    // fails, which aborts the hold.
    validate() {
      const answers = []
      fire("validate", { waitUntil: (answer) => { answers.push(answer) } })
      return Promise.all(answers).then((all) => all.every(Boolean))
    },

    // True when a hold-button:early listener took the action over.
    early() {
      return fire("early").defaultPrevented
    },

    // True when a listener owns the button's state from here.
    completed() {
      return fire("success").defaultPrevented
    }
  }
}
