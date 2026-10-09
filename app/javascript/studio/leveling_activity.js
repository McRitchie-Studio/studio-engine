// studio/leveling_activity: the Alpine scope behind the leveling-activity modals
// (studio/modals/blocks/_leveling_activity and its _change_username
// specialisation): one action, with or without a single-line input, that an app
// endpoint saves.
//
//   <div x-data="levelingActionModal({ hasInput: true, submitUrl: '/account/username' })">
//
// The modal mounts inside a modal host's template, so Alpine evaluates the
// x-data when the modal opens. studio/alpine_shims imports this module and
// publishes the factory as window.levelingActionModal on every page.
//
// UI ONLY. It POSTs to an app-supplied submitUrl and reads a neutral JSON
// contract. A second step some apps need is delegated opaquely: the engine
// hands the app's "challenge" blob to the app's window[finalizeHook] and POSTs
// back whatever "proof" the hook returns. It inspects neither.
//
// The contract (submitUrl and finalizeUrl answer JSON):
//   POST submitUrl { value } answers one of
//     { status: "saved", seeds_earned?, seeds_total? }   done
//     { status: "needs_step", challenge, token }         the app's step is required
//     { status: "error", message }                       the message is shown
//   on needs_step, with a finalizeHook:
//     proof = await window[finalizeHook](challenge, { token, onProgress })
//     POST finalizeUrl { token, proof } answers { status: "saved" | "error", ... }
//
// opts:
//   hasInput       true renders and validates a single-line input; false is a
//                  plain "Complete" action.
//   initialValue   the input's starting value, a string.
//   minLength      the input's minimum length, checked in the browser (0 = none).
//   submitUrl      the app endpoint the action POSTs to; the app owns the save.
//   finalizeUrl    the app endpoint for the second step, when there is one.
//   finalizeHook   the name of the window async function that runs that step.
//   savedEvent     the window event dispatched on success, carrying the app's
//                  payload. Default "studio:activity-saved". A caller that names
//                  its own event runs the follow-on itself (see appDrivenFollowOn).
//   store          the Alpine modal store behind close(). Default "modals".
//   leveling       the default for the seeds celebration. The live value is the
//                  open modal's props.leveling (see the leveling getter).
//   hasConsent     true renders a consent checkbox that gates the action.
//   demo           the style-guide preview: it resolves locally, POSTs nothing
//                  and dispatches no saved event.
//   seedsPerLevel  seeds per level for the celebration bar. Default 100.
//   demoSeedsEarned, demoSeedsTotal   the demo's seed payload. Default 30 and
//                  seedsPerLevel, which crosses a level.
//
// It imports nothing; test/javascript/leveling_activity.test.mjs loads it as a
// data: module.

export const DEFAULT_SAVED_EVENT = "studio:activity-saved"

const GENERIC_ERROR = "Something went wrong. Please try again."
const STEP_ERROR = "Couldn't complete the step."

// Whether the action can run. An input activity needs a real change of at
// least minLength; a plain action runs once. An unticked consent box gates both.
export function actionable({ hasConsent, consent, hasInput, saved, value, original, minLength }) {
  if (hasConsent && !consent) return false
  if (!hasInput) return !saved

  const trimmed = (value || "").trim()
  if (trimmed.length < minLength) return false
  return trimmed !== (original || "").trim()
}

// A response's status: the body's own, or "saved" for a 2xx that names none.
export function responseStatus(result) {
  const body = (result && result.body) || {}
  return body.status || (result && result.ok ? "saved" : "error")
}

// The demo's seed payload: the pair the caller chose, or one that crosses a level.
export function demoSeeds(earned, total, seedsPerLevel) {
  return {
    seeds_earned: Number.isNaN(earned) ? 30 : earned,
    seeds_total: Number.isNaN(total) ? seedsPerLevel : total
  }
}

export function levelingActionModal(opts, { win = window, doc = document } = {}) {
  opts = opts || {}
  return {
    hasInput: !!opts.hasInput,
    value: opts.initialValue || "",
    original: opts.initialValue || "",
    minLength: parseInt(opts.minLength, 10) || 0,
    submitUrl: opts.submitUrl || "",
    finalizeUrl: opts.finalizeUrl || "",
    finalizeHook: opts.finalizeHook || "",
    savedEvent: opts.savedEvent || DEFAULT_SAVED_EVENT,
    store: opts.store || "modals",
    _levelingDefault: !!opts.leveling,
    hasConsent: !!opts.hasConsent,
    consent: false,
    demo: !!opts.demo,
    seedsPerLevel: parseInt(opts.seedsPerLevel, 10) || 100,
    demoSeedsEarned: parseInt(opts.demoSeedsEarned, 10),
    demoSeedsTotal: parseInt(opts.demoSeedsTotal, 10),
    saving: false,
    error: "",
    saved: false,
    celebrate: false,
    progressLabel: "",
    seedsEarned: 0,
    seedsTotal: 0,

    // The props of the modal that is open on this scope's store, or null.
    _props() {
      const store = (win.Alpine && win.Alpine.store) ? win.Alpine.store(this.store) : null
      const current = (store && typeof store.current === "function") ? store.current() : null
      return (current && current.props) || null
    },

    // props.celebrate opens the modal already saved, at the updated state, with
    // the seeds the celebration animates from.
    init() {
      const props = this._props() || {}
      if (!props.celebrate) return

      this.seedsEarned = parseInt(props.seedsEarned, 10) || 0
      this.seedsTotal = parseInt(props.seedsTotal, 10) || 0
      this.saved = true
      this.celebrate = true
    },

    // Read from the open modal's props on every access, so one modal id shows
    // the seeds celebration or the plain confirmation as a toggle moves. A modal
    // whose props do not say keeps the default it was rendered with.
    get leveling() {
      const props = this._props()
      if (props && typeof props.leveling === "boolean") return props.leveling
      return this._levelingDefault
    },

    get changed() {
      return actionable(this)
    },

    // A caller that is not a demo and names its own saved event owns what
    // follows a save: its listener closes, swaps or advances the modal. The
    // engine then dispatches the event and stops, so the app's next step
    // renders once. A demo, and a caller on the default event, get the engine's
    // own confirmation or celebration.
    get appDrivenFollowOn() {
      if (this.demo) return false
      return this.savedEvent !== DEFAULT_SAVED_EVENT
    },

    // A demo dispatches nothing: a host listening for the saved event would
    // open its own follow-on modal over the preview.
    _dispatch(payload) {
      if (this.demo) return
      try {
        win.dispatchEvent(new win.CustomEvent(this.savedEvent, { detail: payload || {} }))
      } catch (error) {}
    },

    _finishSaved(payload) {
      payload = payload || {}
      this.saving = false
      this.saved = true
      this.progressLabel = ""
      if (this.hasInput) this.original = (this.value || "").trim()
      this._dispatch(payload)
      // The app's listener owns close against swap, so the engine closes nothing.
      if (this.appDrivenFollowOn) return

      // The updated state. Which view shows it (the seeds celebration or the
      // plain confirmation) is the leveling getter's call.
      this.seedsEarned = parseInt(payload.seeds_earned, 10) || 0
      this.seedsTotal = parseInt(payload.seeds_total, 10) || 0
      this.celebrate = true
      this._syncCelebrate(true)
    },

    // Mirrors celebrate onto the open modal's props, which the style guide's
    // glow reads, so the glow follows the modal from its input card to its
    // updated card.
    _syncCelebrate(value) {
      const props = this._props()
      if (props) props.celebrate = !!value
    },

    _post(url, body) {
      const csrf = (doc.querySelector('meta[name="csrf-token"]') || {}).content || ""
      const fetcher = win.authedFetch || win.fetch
      return fetcher(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf, "Accept": "application/json" },
        body: JSON.stringify(body || {})
      }).then((response) => response.json().then((json) => ({ ok: response.ok, body: json || {} })))
    },

    save() {
      if (this.saving || !this.changed) return
      this.saving = true
      this.error = ""

      if (this.demo) {
        const seeds = demoSeeds(this.demoSeedsEarned, this.demoSeedsTotal, this.seedsPerLevel)
        setTimeout(() => { this._finishSaved(seeds) }, 600)
        return
      }

      const body = this.hasInput ? { value: (this.value || "").trim() } : {}
      this._post(this.submitUrl, body)
        .then((result) => this._handle(result))
        .catch((error) => {
          this.error = (error && error.message) || GENERIC_ERROR
          this.saving = false
        })
    },

    _handle(result) {
      const body = (result && result.body) || {}
      const status = responseStatus(result)
      if (status === "saved") { this._finishSaved(body); return }
      if (status === "needs_step") return this._step(body)
      this.error = body.message || GENERIC_ERROR
      this.saving = false
    },

    // The second step. The app's hook turns the challenge into a proof, and the
    // proof goes back to finalizeUrl with the token.
    _step(body) {
      const hook = this.finalizeHook && win[this.finalizeHook]
      if (typeof hook !== "function") {
        this.error = "This step isn't available."
        this.saving = false
        return
      }

      return Promise.resolve(
        hook(body.challenge, {
          token: body.token,
          onProgress: (label) => { this.progressLabel = label || "" }
        })
      ).then((proof) => this._post(this.finalizeUrl, { token: body.token, proof })).then((result) => {
        const answer = (result && result.body) || {}
        if (responseStatus(result) === "saved") {
          this._finishSaved(answer)
        } else {
          this.error = answer.message || STEP_ERROR
          this.saving = false
        }
      }).catch((error) => {
        this.error = (error && error.message) || STEP_ERROR
        this.saving = false
      })
    }
  }
}
