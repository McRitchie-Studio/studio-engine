// studio/alpine_shims: the Alpine names and window globals consumers still
// bind to, each a thin delegate to the module that now owns the behaviour.
//
// They exist while a consumer binds to them, and go with the consumer phase of
// the Stimulus migration. Every binding site is listed on the task
// engine-behaviour-moves-to-stimulus.
//
// WHY THIS WORKS BEFORE ALPINE STARTS. layouts/studio/_head loads Alpine AFTER
// the module tags, and deferred classic scripts and module scripts execute in
// document order. So this module has run, and its `alpine:init` listener is
// registered, before Alpine evaluates its first x-data.
import { NavCollapse } from "studio/nav_collapse"
import {
  storedTheme, toggleTheme, showNavSpinner, hideNavSpinner,
  installSpinnerReset, fireSuccessConfetti
} from "studio/head_chrome"

// x-data="navCollapse()": the hub's own header. A host that defines its own
// window.navCollapse (turf-monster does, inline, before this runs) keeps it.
export function navCollapse() {
  return {
    scrolled: false,
    init: function () {
      var self = this
      this._collapse = new NavCollapse(this.$el, function (lit) { self.scrolled = lit })
      this._collapse.start()
    },
    destroy: function () {
      if (this._collapse) this._collapse.stop()
    }
  }
}

export function installAlpineShims() {
  if (!window.navCollapse) window.navCollapse = navCollapse
  if (!window.showNavSpinner) window.showNavSpinner = showNavSpinner
  if (!window.hideNavSpinner) window.hideNavSpinner = hideNavSpinner
  if (!window.fireSuccessConfetti) window.fireSuccessConfetti = fireSuccessConfetti
  installSpinnerReset()

  document.addEventListener('alpine:init', function () {
    var Alpine = window.Alpine
    Alpine.store('devMode', localStorage.getItem('devMode') === 'true')
    Alpine.store('theme', {
      value: storedTheme(localStorage),
      get isDark() { return this.value === 'dark' },
      toggle: function () {
        this.value = toggleTheme(document.documentElement, localStorage, function (fn, ms) { setTimeout(fn, ms) })
      }
    })
  })
}
