// studio/hold_button_hooks: how one hold button asks its page the timeline's
// questions (studio/hold_button). Two voices, both heard on every press:
//
// 1. EVENTS, dispatched on the button and bubbling. This is the API:
//
//      hold-button:guard     at the press. preventDefault() refuses the hold.
//      hold-button:start     the hold began.
//      hold-button:validate  at validate_at. event.detail.waitUntil(answer)
//                            takes a boolean or a promise of one; a false or
//                            failed answer aborts the hold.
//      hold-button:early     at early_action_at. preventDefault() takes the
//                            action over: the hold never completes.
//      hold-button:success   at the full duration. preventDefault() keeps the
//                            button in its holding state for the listener to
//                            resolve; otherwise it shows its success face.
//
//    Every event's detail carries { id }, the button's hold_id.
//
//      <div @hold-button:guard="ready || $event.preventDefault()"
//           @hold-button:success="submit()">
//        <%= render "studio/hold_button", hold_id: "confirm" %>
//      </div>
//
// 2. STRING LOCALS, the partial's guard:, on_hold_start:, validate:,
//    early_action:, early_action_guard: and on_success:, which arrive as
//    data-* attributes and are evaluated against the nearest [x-data] scope
//    with `d` and `data` aliased to its data. They stay while a consumer
//    passes them (turf-monster does), and go when none does.
//
// Either voice can refuse: a hold needs every guard to pass. With an [x-data]
// ancestor a press is also refused while that scope's `submitting` is true, so
// a second hold cannot double-submit.
//
// It imports nothing; test/javascript/hold_button_hooks.test.mjs loads it as a
// data: module.

// How long the button stays in its holding state before a string on_success
// runs.
export const SUCCESS_SETTLE_MS = 500

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

// An expression against an Alpine scope, synchronously.
function evaluate(Alpine, scope, expression) {
  const data = Alpine.$data(scope)
  return Alpine.evaluate(scope, expression, { scope: { d: data, data } })
}

// The same for an expression that may return a promise. Alpine.evaluate
// returns before an async expression settles, so this compiles its own
// function with the names an expression may use.
function evaluateAsync(Alpine, win, scope, expression) {
  const data = Alpine.$data(scope)
  try {
    const fn = new AsyncFunction("d", "data", "Alpine", "window", '"use strict"; return (' + expression + ");")
    return fn(data, data, Alpine, win)
  } catch (error) {
    return Promise.reject(error)
  }
}

// The hooks a Hold takes, for one button.
export function holdHooks(button, { win } = {}) {
  const host = win || globalThis
  const id = () => button.dataset.holdId || "hold"
  const warn = (what, error) => host.console.warn(`[hold:${id()}] ${what}`, error || "")
  const fail = (what, error) => host.console.error(`[hold:${id()}] ${what}`, error)

  const fire = (name, detail = {}) => {
    const event = new host.CustomEvent(`hold-button:${name}`, {
      bubbles: true, cancelable: true, detail: { id: id(), ...detail }
    })
    button.dispatchEvent(event)
    return event
  }

  const scope = () => button.closest("[x-data]")
  // A string local with nothing to evaluate it against cannot answer.
  const scopeFor = (name) => {
    const found = host.Alpine ? scope() : null
    if (!found) warn(`${name}: no Alpine scope to evaluate it in`)
    return found
  }

  return {
    // Refused by the scope's `submitting`, by the guard string, or by a
    // hold-button:guard listener. A guard string that cannot be evaluated
    // refuses: the caller asked for a check that did not run.
    guard() {
      const found = host.Alpine ? scope() : null
      if (found) {
        const data = host.Alpine.$data(found)
        if (data && data.submitting) return false
      }
      const expression = button.dataset.guard
      if (expression) {
        if (!found) { warn("guard: no Alpine scope to evaluate it in; the hold is refused"); return false }
        if (!evaluate(host.Alpine, found, expression)) return false
      }
      return !fire("guard").defaultPrevented
    },

    started() {
      const expression = button.dataset.onHoldStart
      const found = expression ? scopeFor("on_hold_start") : null
      if (found) {
        try { evaluate(host.Alpine, found, expression) } catch (error) { fail("on_hold_start threw", error) }
      }
      fire("start")
    },

    // True unless the validate string or a hold-button:validate listener says
    // no. Rejects when either fails, which aborts the hold.
    validate() {
      const answers = []
      const expression = button.dataset.validate
      if (expression) {
        const found = scopeFor("validate")
        if (found) answers.push(evaluateAsync(host.Alpine, host, found, expression))
      }
      fire("validate", { waitUntil: (answer) => { answers.push(answer) } })
      return Promise.all(answers).then((all) => all.every(Boolean))
    },

    // True when the early action ran, or a hold-button:early listener took
    // the action over.
    early() {
      let taken = false
      const expression = button.dataset.earlyAction
      const found = expression ? scopeFor("early_action") : null
      if (found) {
        const guard = button.dataset.earlyActionGuard
        if (!guard || evaluate(host.Alpine, found, guard)) {
          taken = true
          try { evaluate(host.Alpine, found, expression) } catch (error) { fail("early_action threw", error) }
        }
      }
      return fire("early").defaultPrevented || taken
    },

    // True when a caller owns the button's state from here. A string
    // on_success runs SUCCESS_SETTLE_MS later, with the button still in its
    // holding state; if it throws, the button shows its success face.
    completed() {
      const event = fire("success")
      const expression = button.dataset.onSuccess
      if (!expression) return event.defaultPrevented

      host.setTimeout(() => {
        try {
          const found = scopeFor("on_success")
          if (found) evaluate(host.Alpine, found, expression)
        } catch (error) {
          fail("on_success threw", error)
          button.classList.remove("process")
          button.classList.add("success")
        }
      }, SUCCESS_SETTLE_MS)
      return true
    }
  }
}
