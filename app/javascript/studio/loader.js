// studio/loader: drives the branded loader's two live states (docs/LOADER.md).
// The motion itself is CSS (engine-motion.css, "Branded loader"); this module
// only decides WHEN the page-load overlay shows and marks busy buttons.
//
//   the overlay   [data-studio-loader-overlay], rendered once by
//                 studio_loader_overlay. Shown when a Turbo visit, or a submit
//                 of a form marked data-studio-loader-overlay, outlasts the
//                 overlay's data-delay ms; hidden when the page arrives.
//   pending       a button holding studio_loader_pending. Turbo marks a
//                 submitting form aria-busy itself; for a form Turbo does not
//                 drive, the submitter is marked here.
//   the API       window.StudioLoader.show(caption) / hide() for any other long
//                 wait, and setPercent(el, n) for a loader drawn with percent:.
//
// The logic is exported for test/javascript/loader.test.mjs.

export var DEFAULT_DELAY_MS = 350

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

function findOverlay(doc) {
  return doc.querySelector('[data-studio-loader-overlay]')
}

var pendingTimer = null

export function show(caption, doc) {
  doc = doc || document
  clearTimeout(pendingTimer)
  pendingTimer = null
  var overlay = findOverlay(doc)
  if (!overlay) return false
  var line = overlay.querySelector('[data-studio-loader-caption]')
  if (line) line.textContent = caption || ''
  overlay.hidden = false
  overlay.setAttribute('aria-busy', 'true')
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
  overlay.removeAttribute('aria-busy')
  overlay.hidden = true
  return true
}

// Show after the overlay's delay, so a fast load never flashes it.
export function showSoon(caption, doc) {
  doc = doc || document
  var overlay = findOverlay(doc)
  if (!overlay || !overlay.hidden) return
  clearTimeout(pendingTimer)
  pendingTimer = setTimeout(function () { show(caption, doc) }, overlayDelay(overlay))
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

  doc.addEventListener('turbo:visit', function () { showSoon('', doc) })
  ;['turbo:load', 'turbo:render', 'turbo:before-cache', 'turbo:fetch-request-error', 'turbo:frame-load'].forEach(function (name) {
    doc.addEventListener(name, function () { hide(doc) })
  })
  // A bfcache restore keeps the overlay as it was when the page was left.
  if (doc.defaultView) doc.defaultView.addEventListener('pageshow', function (event) { if (event.persisted) hide(doc) })

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
    if (button) button.setAttribute('aria-busy', 'true')
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
