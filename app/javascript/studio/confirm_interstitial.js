// studio/confirm_interstitial: the scanner-safe sign-in page
// (studio/_confirm_interstitial) posts its own form. The GET that renders the
// page is inert; this POST is what burns the single-use token and signs in.
//
// The page is a whole document with no layout, no import map and no Stimulus
// application, so it loads this module by its own tag and the module runs on
// evaluation. It posts once: the form is stamped, so a second evaluation (a
// restored page) does not post again.
//
// NOTHING HERE REVEALS THE FALLBACK BUTTON. The page shows it by CSS alone,
// four seconds in, so a page whose script never arrives still has something to
// press.
//
// It imports nothing; test/javascript/confirm_interstitial.test.mjs loads it
// as a data: module.

export const FORM_ID = "magic-consume-form"

// Submits the form unless it has been submitted already. Answers whether it
// submitted.
export function autoSubmit(form) {
  if (!form || form.dataset.autoSubmitted) return false
  form.dataset.autoSubmitted = "1"
  if (typeof form.requestSubmit === "function") form.requestSubmit()
  else form.submit()
  return true
}

if (typeof document !== "undefined") autoSubmit(document.getElementById(FORM_ID))
