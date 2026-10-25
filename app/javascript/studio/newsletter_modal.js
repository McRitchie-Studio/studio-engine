// studio/newsletter_modal: the newsletter cards' JSON mode
// (studio/profiles/_newsletter_modals with submit_mode: :json).
//
//   x-data="studioNewsletterModal({ action: 'subscribe', url, store, needsEmail, requiresConsent, nextId, event })"
//
// One scope for every card, so each binds the same names: email, consent,
// saving, error, props, ready and submit(). A card that only shows (the success
// and goodbye beats) binds props and nothing else.
//
// WHAT submit() DOES, in order:
//   1. Refuses quietly while a request is in flight, or while a consent box the
//      card carries is unticked (the button is disabled then too).
//   2. When the card asks for an address, refuses an address with no "@" past
//      its first character, on the card's own error line.
//   3. HANDS OFF when the opener passed props.onSubmit: closes the card and
//      calls it with the address (or null). The opener owns the request then;
//      this is how a page that already knows how to subscribe asks only for the
//      address.
//   4. Otherwise POSTs JSON to the host's url (DELETE or another verb by
//      opts.method) with the page's CSRF token, and reads the answer: a 2xx, not by redirect, whose
//      body does not say success: false is a success; anything else shows
//      body.error, or a plain line, on the card.
//   5. On success: dispatches opts.event on window with
//      { subscribed, email, response }, calls props.onSuccess(response) when the
//      opener passed one, then swaps to opts.nextId (the success or goodbye card)
//      with the response as its props, or closes when there is none.
//
// No page reload anywhere: the host's listener updates whatever the page shows.
//
// studio/alpine_scopes publishes the factory on window, statically: Alpine
// evaluates the x-data as the modal host mounts the card. It imports nothing;
// test/javascript/newsletter_modal.test.mjs loads it as a data: module.

export const INVALID_EMAIL = "Enter a valid email address."
export const SUBSCRIBE_FAILED = "Could not join the newsletter."
export const UNSUBSCRIBE_FAILED = "Could not unsubscribe."
export const CHANGED_EVENT = "studio:newsletter-changed"

// The address trimmed, or "" when it cannot be one: an "@" with nothing before
// it, or none at all. The server is the real check; this only saves a round trip
// for the address nobody meant.
export function cleanEmail(value) {
  const s = String(value == null ? "" : value).trim()
  return s.indexOf("@") > 0 ? s : ""
}

// What the host's answer means. ok: a 2xx whose body does not say
// success: false, and that fetch did not reach by a redirect (an expired session
// redirected to an HTML sign-in page answers 200, and joined nobody). error:
// the body's own words, else the fallback.
export function outcomeOf(response, body, fallback) {
  body = body && typeof body === "object" ? body : {}
  const ok = !!(response && response.ok && !response.redirected) && body.success !== false
  return ok ? { ok: true, body: body } : { ok: false, body: body, error: body.error || fallback }
}

// The page's CSRF token, or "" on a page without one.
export function csrfToken(doc) {
  try {
    const meta = doc && doc.querySelector('meta[name="csrf-token"]')
    return (meta && meta.content) || ""
  } catch (_) {
    return ""
  }
}

// x-data for a newsletter card.
//
// opts:
//   action           "subscribe" (default) or "unsubscribe".
//   url              the host's JSON endpoint for the action.
//   method           the verb (default "POST").
//   store            the Alpine store the card is mounted in (default "modals").
//   needsEmail       the card asks for an address.
//   requiresConsent  the card carries a consent box (ticked to start).
//   nextId           the card a success swaps to; blank closes instead.
//   event            the window event a success dispatches (CHANGED_EVENT).
//
// env: { win } for the tests.
export function studioNewsletterModal(opts, env) {
  opts = opts || {}
  const win = (env && env.win) || (typeof window !== "undefined" ? window : {})
  const action = opts.action === "unsubscribe" ? "unsubscribe" : "subscribe"

  return {
    email: "",
    consent: true,
    saving: false,
    error: "",
    action: action,
    url: opts.url || "",
    method: String(opts.method || "POST").toUpperCase(),
    store: opts.store || "modals",
    needsEmail: !!opts.needsEmail,
    requiresConsent: !!opts.requiresConsent,
    nextId: opts.nextId || "",
    event: opts.event || CHANGED_EVENT,

    _store() {
      try { return win.Alpine.store(this.store) } catch (_) { return null }
    },

    // The open card's props, or {} with nothing open.
    get props() {
      const store = this._store()
      const entry = store && store.current && store.current()
      return (entry && entry.props) || {}
    },

    get ready() {
      return !this.saving && (!this.requiresConsent || !!this.consent)
    },

    async submit() {
      if (!this.ready) return
      let address = null
      if (this.needsEmail) {
        address = cleanEmail(this.email)
        if (!address) {
          this.error = INVALID_EMAIL
          return
        }
      }
      this.error = ""

      const props = this.props
      if (action === "subscribe" && typeof props.onSubmit === "function") {
        const handOff = props.onSubmit
        this._close()
        handOff(address)
        return
      }

      this.saving = true
      const fallback = action === "unsubscribe" ? UNSUBSCRIBE_FAILED : SUBSCRIBE_FAILED
      let outcome
      try {
        const init = {
          method: this.method,
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-CSRF-Token": csrfToken(win.document)
          }
        }
        if (action === "subscribe") init.body = JSON.stringify({ email: address })
        const response = await win.fetch(this.url, init)
        let body = {}
        try { body = await response.json() } catch (_) {}
        outcome = outcomeOf(response, body, fallback)
      } catch (_) {
        outcome = { ok: false, body: {}, error: fallback }
      }

      this.saving = false
      if (!outcome.ok) {
        this.error = outcome.error
        return
      }
      this._succeed(outcome.body, address, props)
    },

    _succeed(body, address, props) {
      const subscribed = action === "subscribe"
      try {
        win.dispatchEvent(new win.CustomEvent(this.event, {
          detail: { subscribed: subscribed, email: address, response: body }
        }))
      } catch (_) {}
      if (typeof props.onSuccess === "function") {
        try { props.onSuccess(body) } catch (_) {}
      }
      const store = this._store()
      if (!store) return
      if (this.nextId) store.swap(this.nextId, body)
      else store.close()
    },

    _close() {
      const store = this._store()
      if (store) store.close()
    }
  }
}
