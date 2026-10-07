// studio/head_chrome: the small behaviours every page's chrome carries. Each
// piece below used to be an inline <script> in layouts/studio/_head.
//
//   nav spinner   the scale morph between the theme toggle and a spinner
//   confetti      the success burst a completed flow fires
//
// The logic is exported for test/javascript/head_chrome.test.mjs. The window
// globals that consumers bind to are installed by studio/alpine_shims. The
// theme and its Alpine store are studio/alpine_stores, which loads even when
// this module does not.

// ---- NAV SPINNER ------------------------------------------------------------
//
// Minimum display time prevents quick flashes; per app via
// Studio.nav_spinner_min_ms, which the head publishes as
// <meta name="studio-nav-spinner-min-ms"> (smooth-load apps drop it to ~300).

// How long hide must still wait so the spinner shows for at least minMs.
export function spinnerHideDelay(shownAt, now, minMs) {
  return Math.max(0, minMs - (now - shownAt))
}

export function spinnerMinMs(doc) {
  var meta = doc.querySelector('meta[name="studio-nav-spinner-min-ms"]')
  var value = meta ? parseInt(meta.getAttribute('content'), 10) : 0
  return value > 0 ? value : 0
}

var spinnerShownAt = 0

function showToggle(doc) {
  doc.querySelectorAll('.nav-toggle-icon').forEach(function (e) { e.style.opacity = '1'; e.style.transform = 'scale(1) rotate(0deg)' })
  doc.querySelectorAll('.nav-spinner-icon').forEach(function (e) { e.style.opacity = '0'; e.style.transform = 'scale(0) rotate(-90deg)' })
}

export function showNavSpinner() {
  spinnerShownAt = Date.now()
  document.querySelectorAll('.nav-toggle-icon').forEach(function (e) { e.style.opacity = '0'; e.style.transform = 'scale(0) rotate(90deg)' })
  document.querySelectorAll('.nav-spinner-icon').forEach(function (e) { e.style.opacity = '1'; e.style.transform = 'scale(1) rotate(0deg)' })
}

export function hideNavSpinner() {
  var wait = spinnerHideDelay(spinnerShownAt, Date.now(), spinnerMinMs(document))
  setTimeout(function () { showToggle(document) }, wait)
}

// Reset spinner state before Turbo caches the page. Installed once.
var spinnerResetInstalled = false
export function installSpinnerReset() {
  if (spinnerResetInstalled) return
  spinnerResetInstalled = true
  document.addEventListener('turbo:before-cache', function () { showToggle(document) })
}

// ---- SUCCESS CONFETTI -------------------------------------------------------
//
// Rides the global `confetti` that studio/canvas_confetti defines; does
// nothing when it is absent. window.CONFETTI_COLORS overrides the palette.

export var SUCCESS_COLORS = ['#4BAF50', '#8E82FE', '#06D6A0', '#FF7C47', '#FFD700', '#00BFFF', '#FF6B9D', '#C084FC']

// The four bursts, each as [delay ms, confetti options].
export function successBursts(colors) {
  return [
    [0, { particleCount: 150, spread: 100, origin: { x: 0.5, y: 0.5 }, colors: colors, zIndex: 9999, startVelocity: 45, gravity: 0.8, ticks: 300, scalar: 1.2 }],
    [150, { particleCount: 80, angle: 60, spread: 60, origin: { x: 0, y: 0.6 }, colors: colors, zIndex: 9999, startVelocity: 55, gravity: 1, ticks: 250 }],
    [150, { particleCount: 80, angle: 120, spread: 60, origin: { x: 1, y: 0.6 }, colors: colors, zIndex: 9999, startVelocity: 55, gravity: 1, ticks: 250 }],
    [400, { particleCount: 100, spread: 160, origin: { x: 0.5, y: 0.3 }, colors: colors, zIndex: 9999, startVelocity: 30, gravity: 1.2, ticks: 200, scalar: 0.8 }]
  ]
}

export function fireSuccessConfetti() {
  if (typeof window.confetti === 'undefined') return
  var fire = window.confetti
  successBursts(window.CONFETTI_COLORS || SUCCESS_COLORS).forEach(function (burst) {
    if (burst[0] === 0) fire(burst[1])
    else setTimeout(function () { fire(burst[1]) }, burst[0])
  })
}
