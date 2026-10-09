// studio/confirm_interstitial: the scanner-safe sign-in page
// (studio/_confirm_interstitial) posts its own form. The GET that renders the
// page is inert; this POST is what burns the single-use token and signs in.
//
// The page is a whole document with no layout, no import map and no Stimulus
// application, so it loads this module by its own tag and the module runs on
// evaluation. It posts once: the form is stamped, so a second evaluation (a
// restored page) does not post again.
//
// THE FALLBACK BUTTON HAS TWO WAYS TO APPEAR, four seconds in. The page shows
// it by CSS alone, so a page whose script never arrives still has something to
// press. This module shows it too, by a timer, because an engine may hold a
// CSS animation while the post's navigation is pending (WebKit does, and the
// post is pending for exactly as long as the button is wanted).
//
// It imports nothing; test/javascript/confirm_interstitial.test.mjs loads it
// as a data: module.

export const FORM_ID = "magic-consume-form"
export const FALLBACK_ID = "magic-fallback"
// The class that shows the fallback (the page's own stylesheet).
export const SHOWN_CLASS = "is-shown"
export const FALLBACK_AFTER_MS = 4000

// Submits the form unless it has been submitted already. Answers whether it
// submitted.
export function autoSubmit(form) {
  if (!form || form.dataset.autoSubmitted) return false
  form.dataset.autoSubmitted = "1"
  if (typeof form.requestSubmit === "function") form.requestSubmit()
  else form.submit()
  return true
}

// Shows the fallback block once `ms` have passed. Returns the timer.
export function revealFallbackLater(fallback, later, ms) {
  if (!fallback) return null
  return later(function () { fallback.classList.add(SHOWN_CLASS) }, ms == null ? FALLBACK_AFTER_MS : ms)
}

if (typeof document !== "undefined") {
  autoSubmit(document.getElementById(FORM_ID))
  revealFallbackLater(document.getElementById(FALLBACK_ID), setTimeout)
}
