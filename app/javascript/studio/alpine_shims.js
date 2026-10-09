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
//
// THE STORES ARE NOT HERE. $store.theme and $store.devMode are
// studio/alpine_stores, which the head also loads by its own module tag, so a
// host's body binding survives a boot that failed to load. Importing it here
// keeps it in the boot graph, preloaded; it installs itself on evaluation.
import "studio/alpine_stores"
import { NavCollapse } from "studio/nav_collapse"
import {
  showNavSpinner, hideNavSpinner, installSpinnerReset, fireSuccessConfetti
} from "studio/head_chrome"
import { themeEditor, dsThemeEditor } from "studio/theme_editor"
import { emailBannerEditor, emailRecipients } from "studio/email_banner"

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
  // x-data="themeEditor({...})" (theme_settings/edit) and
  // x-data="dsThemeEditor({...})" (style/_theme). Alpine passes the seed alone.
  if (!window.themeEditor) window.themeEditor = (seed) => themeEditor(seed)
  if (!window.dsThemeEditor) window.dsThemeEditor = (seed) => dsThemeEditor(seed)
  // x-data="emailBannerEditor({...})" (studio/emails/show) and
  // x-data="emailRecipients({...})" (studio/emails/index).
  if (!window.emailBannerEditor) window.emailBannerEditor = (config) => emailBannerEditor(config)
  if (!window.emailRecipients) window.emailRecipients = (config) => emailRecipients(config)
  installSpinnerReset()
}
