// studio/loader: drives the branded loader's two live states (docs/LOADER.md).
// The motion itself is CSS (engine-motion.css, "Branded loader"); this module
// only decides WHEN the page-load overlay shows and marks busy buttons.
//
//   the overlay   [data-studio-loader-overlay], rendered once by
//                 studio_loader_overlay. Shown when a visit the USER started (a
//                 Turbo advance or restore; never a replace, a refresh, a frame
//                 or a prefetch), or a submit of a form marked
//                 data-studio-loader-overlay, outlasts the overlay's data-delay
//                 ms; hidden when the page arrives. Its role=status label is
//                 announced: the overlay never marks itself aria-busy.
//   pending       a button holding studio_loader_pending. Turbo marks a
//                 submitting form aria-busy itself; for a form Turbo does not
//                 drive, the submitter is marked here, and cleared on pagehide
//                 and on pageshow (a bfcache restore).
//   the cap       an automatic show and a marked button clear themselves after
//                 data-max-wait ms (MAX_WAIT_MS by default): a response that
//                 turned into a download replaces no page, so nothing else
//                 would. A Turbo visit whose response is not HTML clears at
//                 once, on turbo:reload.
//   the API       window.StudioLoader.show(caption) / hide() for any other long
//                 wait, and setPercent(el, n) for a loader drawn with percent:.
//
// The logic is exported for test/javascript/loader.test.mjs.

export var DEFAULT_DELAY_MS = 350
export var MAX_WAIT_MS = 15000

// Only a visit the user started earns the overlay: a click or Turbo.visit
// (advance) and Back or Forward (restore). A replace is a background refresh
// (a poll, Turbo 8's page refresh); frames and prefetches never fire turbo:visit.
export function userVisit(event) {
  var action = event && event.detail && event.detail.action
  return action === 'advance' || action === 'restore'
}

export function overlayDelay(overlay) {
  var value = overlay ? parseInt(overlay.getAttribute('data-delay'), 10) : NaN
  return value >= 0 ? value : DEFAULT_DELAY_MS
}

// The percent a caller handed setPercent, clamped to a number in 0..100.
export function clampPercent(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0
  return Math.min(100, Math.max(0, n))
}

export function maxWait(overlay) {
  var value = overlay ? parseInt(overlay.getAttribute('data-max-wait'), 10) : NaN
  return value > 0 ? value : MAX_WAIT_MS
}

function findOverlay(doc) {
  return doc.querySelector('[data-studio-loader-overlay]')
}

var pendingTimer = null
var capTimer = null
var autoShown = false

// The overlay's status is a live region; rewriting its label after the overlay
// unhides makes a screen reader say it, where text already present when a
// region appears is often skipped. The label is kept in data-studio-loader-label,
// so a second show inside the gap restores it rather than the emptied text.
function announce(overlay, doc) {
  var label = overlay.querySelector('[role="status"] .sr-only')
  if (!label) return
  var text = label.getAttribute('data-studio-loader-label')
  if (text === null) { text = label.textContent; label.setAttribute('data-studio-loader-label', text) }
  label.textContent = ''
  var win = doc.defaultView
  ;(win && win.setTimeout ? win.setTimeout.bind(win) : setTimeout)(function () { label.textContent = text }, 50)
}

export function show(caption, doc) {
  doc = doc || document
  clearTimeout(pendingTimer)
  pendingTimer = null
  autoShown = false
  var overlay = findOverlay(doc)
  if (!overlay) return false
  var line = overlay.querySelector('[data-studio-loader-caption]')
  if (line) line.textContent = caption || ''
  overlay.hidden = false
  announce(overlay, doc)
  // One frame hidden=false at opacity 0, then fade in.
  var raf = (doc.defaultView && doc.defaultView.requestAnimationFrame) || function (fn) { return setTimeout(fn, 16) }
  raf(function () { if (!overlay.hidden) overlay.setAttribute('data-state', 'shown') })
  return true
}

export function hide(doc) {
  doc = doc || document
  clearTimeout(pendingTimer)
  pendingTimer = null
  var overlay = findOverlay(doc)
  if (!overlay) return false
  overlay.removeAttribute('data-state')
  overlay.hidden = true
  return true
}

// Clear the buttons studio/loader marked busy (never one a page marked itself).
export function clearBusy(doc) {
  doc = doc || document
  clearTimeout(capTimer)
  capTimer = null
  var marked = doc.querySelectorAll('[data-studio-loader-busy]')
  for (var i = 0; i < marked.length; i++) {
    marked[i].removeAttribute('aria-busy')
    marked[i].removeAttribute('data-studio-loader-busy')
  }
}

// Hide the overlay and clear every busy button: the page is ours again.
export function settle(doc) {
  doc = doc || document
  hide(doc)
  clearBusy(doc)
}

// The cap never hides an overlay a caller showed through StudioLoader.show().
function armCap(doc) {
  clearTimeout(capTimer)
  capTimer = setTimeout(function () {
    var shownByUs = autoShown
    clearBusy(doc)
    if (shownByUs) hide(doc)
  }, maxWait(findOverlay(doc)))
}

// Show after the overlay's delay, so a fast load never flashes it; settle after
// the cap, so a wait that never ends in a page never sticks.
export function showSoon(caption, doc) {
  doc = doc || document
  var overlay = findOverlay(doc)
  if (!overlay || !overlay.hidden) return
  clearTimeout(pendingTimer)
  pendingTimer = setTimeout(function () { show(caption, doc); autoShown = true }, overlayDelay(overlay))
  armCap(doc)
}

export function markBusy(button, doc) {
  doc = doc || document
  button.setAttribute('aria-busy', 'true')
  button.setAttribute('data-studio-loader-busy', '')
  armCap(doc)
}

export function setPercent(el, value) {
  if (!el) return
  var loader = el.classList && el.classList.contains('studio-loader') ? el : el.querySelector('.studio-loader')
  if (!loader) return
  loader.setAttribute('data-loader-percent', '')
  loader.style.setProperty('--studio-loader-percent', String(clampPercent(value)))
}

// A submitter that carries a pending loader.
export function pendingSubmitter(event) {
  var submitter = event && (event.submitter || (event.detail && event.detail.formSubmission && event.detail.formSubmission.submitter))
  if (!submitter || !submitter.querySelector) return null
  return submitter.querySelector('.studio-loader[data-loader-pending]') ? submitter : null
}

var installed = false
export function installStudioLoader(doc) {
  doc = doc || document
  if (installed) return
  installed = true

  doc.addEventListener('turbo:visit', function (event) { if (userVisit(event)) showSoon('', doc) })
  // turbo:reload: the response was not HTML (a download), or the visit failed,
  // and Turbo hands the URL to the browser; no page may ever replace this one.
  ;['turbo:load', 'turbo:render', 'turbo:before-cache', 'turbo:fetch-request-error', 'turbo:frame-load', 'turbo:reload'].forEach(function (name) {
    doc.addEventListener(name, function () { hide(doc) })
  })
  // Leaving clears the page before the bfcache keeps it; a restore clears it
  // again, in case it was kept some other way.
  if (doc.defaultView) {
    doc.defaultView.addEventListener('pagehide', function () { settle(doc) })
    doc.defaultView.addEventListener('pageshow', function (event) { if (event.persisted) settle(doc) })
  }

  doc.addEventListener('turbo:submit-start', function (event) {
    var form = event.target
    if (form && form.hasAttribute && form.hasAttribute('data-studio-loader-overlay')) {
      showSoon(form.getAttribute('data-studio-loader-overlay') || '', doc)
    }
  })
  doc.addEventListener('turbo:submit-end', function (event) {
    var form = event.target
    if (form && form.hasAttribute && form.hasAttribute('data-studio-loader-overlay')) hide(doc)
  })

  // A form Turbo does not drive navigates away on its own; mark the button and,
  // when asked, the overlay, until the next page replaces this one.
  doc.addEventListener('submit', function (event) {
    var form = event.target
    if (event.defaultPrevented || !form || !form.getAttribute) return
    var win = doc.defaultView
    if (win && win.Turbo && form.getAttribute('data-turbo') !== 'false') return
    var button = pendingSubmitter(event)
    if (button) markBusy(button, doc)
    if (form.hasAttribute('data-studio-loader-overlay')) showSoon(form.getAttribute('data-studio-loader-overlay') || '', doc)
  })

  if (doc.defaultView && !doc.defaultView.StudioLoader) {
    doc.defaultView.StudioLoader = {
      show: function (caption) { return show(caption, doc) },
      hide: function () { return hide(doc) },
      setPercent: setPercent
    }
  }
}
