// studio/modal_countdown: a modal card that counts down and closes itself.
//
//   x-data="studioModalCountdown({ seconds: $store.modals.current().props.secondsLeft, store: 'modals', autoClose: true })"
//       blocks/_error_card with countdown_key: the "give it a sec" wait after
//       a 429, seeded from the response's Retry-After. The card shows
//       waitLabel and, at zero, closes the store it is mounted in.
//
// The seconds are read ONCE, at mount, from whatever expression the host named:
// the card counts its own copy down and never writes back to the modal's props.
// No seconds, or none above zero, is no countdown: nothing ticks and nothing
// closes, so a card opened without a Retry-After stays until it is dismissed.
//
// studio/alpine_scopes publishes the factory on window, statically: Alpine
// evaluates the x-data as the modal host mounts the card, and a factory that is
// not defined by then leaves the card dead. It imports nothing;
// test/javascript/modal_countdown.test.mjs loads it as a data: module.

// Above this many seconds the wait reads in minutes ("3 min"), below it in
// seconds ("45s"): a rate limit of several minutes counted in seconds reads as
// a clock, not a wait.
export const MINUTES_FROM = 90

// A host value as whole seconds to wait: a Retry-After of "12", 12 or 11.2 all
// wait 12. Anything that is not a positive number is 0, no wait.
export function startSeconds(value) {
  const n = Number(value)
  return Number.isFinite(n) && n > 0 ? Math.ceil(n) : 0
}

// The wait as a person reads it.
export function waitLabel(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0))
  return s > MINUTES_FROM ? Math.ceil(s / 60) + " min" : s + "s"
}

// x-data for a counting card.
//
// opts:
//   seconds    the wait, read once at mount (see startSeconds).
//   store      the Alpine store the card is mounted in (default "modals").
//   autoClose  close that store at zero (default true).
//
// env: { win, setInterval, clearInterval } for the tests.
export function studioModalCountdown(opts, env) {
  opts = opts || {}
  const win = (env && env.win) || (typeof window !== "undefined" ? window : {})
  const every = (env && env.setInterval) || ((fn, ms) => setInterval(fn, ms))
  const stopEvery = (env && env.clearInterval) || ((id) => clearInterval(id))

  return {
    remaining: startSeconds(opts.seconds),
    store: opts.store || "modals",
    autoClose: opts.autoClose !== false,
    _timer: null,

    get counting() {
      return this.remaining > 0
    },
    get waitLabel() {
      return waitLabel(this.remaining)
    },

    init() {
      this._stop()
      if (this.remaining <= 0) return
      this._timer = every(() => this.tick(), 1000)
    },

    tick() {
      if (this.remaining <= 0) return this._stop()
      this.remaining -= 1
      if (this.remaining > 0) return
      this.remaining = 0
      this._stop()
      if (this.autoClose) this._close()
    },

    // The card may already be gone (a person dismissed it in the last second),
    // so a store with nothing open, or no such store, is not an error.
    _close() {
      try { win.Alpine.store(this.store).close() } catch (_) {}
    },

    _stop() {
      if (this._timer !== null) stopEvery(this._timer)
      this._timer = null
    },

    // Alpine calls destroy() when the host unmounts the card, so a card closed
    // by hand leaves no interval behind it.
    destroy() {
      this._stop()
    }
  }
}
