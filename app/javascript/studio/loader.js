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
//   the pace      one standard for every app: a visit under data-delay ms shows no
//                 overlay and waits for nothing; once the overlay of a visit has
//                 shown, it stays data-min-show ms. Turbo's hook for a pause,
//                 turbo:before-render, comes AFTER a view transition took the old
//                 page's picture, with rendering paused, so a hold there would
//                 freeze the loader and carry it out in that picture. So the wait
//                 is on the response, ahead of all of that: see holdVisitResponse.
//   the door      a host need not render the overlay. layouts/studio/_head carries
//                 it in a <template>, and this module adds it to the body at need.
//   pending       a button holding studio_loader_pending. Turbo marks a
//                 submitting form aria-busy itself; for a form Turbo does not
//                 drive, the submitter is marked here, and cleared on pagehide
//                 and on pageshow (a bfcache restore).
//   the cap       a submit Turbo does not drive clears its overlay and button
//                 after data-max-wait ms (MAX_WAIT_MS by default): a response that
//                 turned into a download replaces no page, so nothing else
//                 would. A Turbo visit is never capped; a non-HTML response
//                 clears at once, on turbo:reload.
//   the API       window.StudioLoader.show(caption) / hide() for any other long
//                 wait, and setPercent(el, n) for a loader drawn with percent:.
//                 hide() is immediate. It ends any wait, because the caller owns
//                 that moment, and a caller's show() has no minimum.
//
// The logic is exported for test/javascript/loader.test.mjs.

export var DEFAULT_DELAY_MS = 350
export var DEFAULT_MIN_SHOW_MS = 750
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

export function overlayMinShow(overlay) {
  var value = overlay ? parseInt(overlay.getAttribute('data-min-show'), 10) : NaN
  return value >= 0 ? value : DEFAULT_MIN_SHOW_MS
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
var shownAt = null
var deferredHide = null
var releaseHold = null
var visitSignal = null

// The host's own overlay, else the one layouts/studio/_head carries. Added once:
// querySelector cannot see into a <template>.
function ensureOverlay(doc) {
  var overlay = findOverlay(doc)
  if (overlay || !doc.body) return overlay
  var template = doc.querySelector('template[data-studio-loader-overlay-template]')
  if (!template) return null
  doc.body.appendChild(doc.importNode(template.content, true))
  return findOverlay(doc)
}

// What is left of the minimum for an overlay a visit showed. Zero for one that is
// not showing, and for one a caller opened with show().
export function minShowLeft(overlay, now) {
  if (!overlay || overlay.hidden || shownAt === null) return 0
  return Math.max(0, overlayMinShow(overlay) - (now - shownAt))
}

// A page that must stay its own document answers this way. Turbo loads it again by
// a full load, so this response paints nothing, and a wait here would only delay it.
export function answersWithFullLoad(html) {
  return /<meta[^>]*(turbo-visit-control[^>]*reload|reload[^>]*turbo-visit-control)/i.test(html || '')
}

export function noteVisitRequest(event, doc) {
  if (event.target === doc.documentElement) visitSignal = event.detail.fetchOptions.signal
}

function endHold() {
  if (releaseHold) releaseHold()
}

// Turbo reads response.responseHTML, and only then records the response, caches the
// page and opens its view transition. So this is the last moment the page is live
// with the response in hand. The rest of the minimum runs here and the overlay goes,
// so the old picture has no overlay in it. It always ends: at the timer, at hide(),
// or at the next visit. A later hold (the transition's wait for images) comes after
// this one has ended, inside the render, so neither can cut the other short. Turbo
// renders even a cancelled visit's response, so that HTML never goes: a Back must win.
//
// Only a visit's own good HTML waits. A frame, a form and a prefetch have another
// target. A failure and a download pass straight through.
export function holdVisitResponse(event, doc) {
  doc = doc || document
  if (event.target !== doc.documentElement) return false
  clearTimeout(pendingTimer)
  pendingTimer = null
  var response = event.detail && event.detail.fetchResponse
  // A body that fails after its headers rejects here, and Turbo fires nothing for it.
  if (response) Promise.resolve(response.responseHTML).catch(function () { hide(doc) })
  if (!response || !response.succeeded || !response.isHTML) return false
  var overlay = findOverlay(doc)
  if (minShowLeft(overlay, Date.now()) <= 0) return false
  var signal = visitSignal
  var held = Promise.resolve(response.responseHTML).then(function (html) {
    if (answersWithFullLoad(html)) return html
    var left = minShowLeft(overlay, Date.now())
    if (left <= 0) return html
    return new Promise(function (resolve) {
      var done = function (value) { if (!signal || !signal.aborted) resolve(value) }
      var timer = setTimeout(function () {
        releaseHold = null
        hide(doc)
        done(html)
      }, left)
      releaseHold = function () {
        clearTimeout(timer)
        releaseHold = null
        done(html)
      }
    })
  })
  Object.defineProperty(response, 'responseHTML', { configurable: true, value: held })
  return true
}

// A form's overlay ends with its submit, and no render waits on it, so this only
// keeps the overlay up for the rest of its minimum.
export function hideAfterMinimum(doc) {
  doc = doc || document
  var left = minShowLeft(findOverlay(doc), Date.now())
  if (left <= 0) return hide(doc)
  clearTimeout(deferredHide)
  deferredHide = setTimeout(function () { hide(doc) }, left)
  return true
}

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
  clearTimeout(deferredHide)
  deferredHide = null
  autoShown = false
  shownAt = null
  var overlay = ensureOverlay(doc)
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
  clearTimeout(deferredHide)
  deferredHide = null
  shownAt = null
  endHold()
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

// Show after the overlay's delay, so a fast load never flashes it. Uncapped: a
// slow Turbo visit keeps its overlay until the page arrives.
export function showSoon(caption, doc) {
  doc = doc || document
  var overlay = ensureOverlay(doc)
  if (!overlay || !overlay.hidden) return
  clearTimeout(pendingTimer)
  pendingTimer = setTimeout(function () {
    show(caption, doc)
    autoShown = true
    shownAt = Date.now()
  }, overlayDelay(overlay))
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
  var percent = clampPercent(value)
  loader.setAttribute('data-loader-percent', '')
  loader.style.setProperty('--studio-loader-percent', String(percent))
  // A bar is a progressbar: a percent makes it determinate and is its value.
  if (loader.getAttribute && loader.getAttribute('role') === 'progressbar') loader.setAttribute('aria-valuenow', String(percent))
  var sweep = loader.querySelector && loader.querySelector('.progress-meter--indeterminate')
  if (sweep) sweep.classList.remove('progress-meter--indeterminate')
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

  doc.addEventListener('turbo:visit', function (event) {
    // The response a hold still waits on belongs to a visit that is over.
    endHold()
    if (userVisit(event)) showSoon('', doc)
  })
  doc.addEventListener('turbo:before-fetch-request', function (event) { noteVisitRequest(event, doc) })
  doc.addEventListener('turbo:before-fetch-response', function (event) { holdVisitResponse(event, doc) })
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
    if (form && form.hasAttribute && form.hasAttribute('data-studio-loader-overlay')) hideAfterMinimum(doc)
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
    if (form.hasAttribute('data-studio-loader-overlay')) { showSoon(form.getAttribute('data-studio-loader-overlay') || '', doc); armCap(doc) }
  })

  if (doc.defaultView && !doc.defaultView.StudioLoader) {
    doc.defaultView.StudioLoader = {
      show: function (caption) { return show(caption, doc) },
      hide: function () { return hide(doc) },
      setPercent: setPercent
    }
  }
}
