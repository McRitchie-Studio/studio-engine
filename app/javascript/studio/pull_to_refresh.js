// studio/pull_to_refresh: pull the page down from its top to reload it
// (docs/LOADER.md, "Pull to refresh"). Phone widths and touch only: the
// controller arms itself where PHONE_QUERY matches and does nothing anywhere
// else, so a desktop, a mouse or a keyboard never meets it. The markup is
// studio_pull_to_refresh:
//
//   <div class="studio-pull-refresh" data-studio-controller="pull-to-refresh"
//        data-pull-to-refresh-frame="feed">            (optional: reload one frame)
//     <span class="studio-pull-refresh-indicator" hidden>...</span>
//     <p class="sr-only" role="status" data-pull-to-refresh-status></p>
//     ...the page...
//   </div>
//
//   the pull     a touch that starts with the page at its top and moves down
//                drags the indicator; --studio-pull is the distance over
//                THRESHOLD_PX, eased so it resists the finger.
//   the release  past the threshold it refreshes: the named frame's reload(),
//                else a Turbo visit to this URL with action "replace" (which the
//                page-load overlay never shows for). Short of it, it settles back.
//   the end      turbo:frame-load or turbo:load clears the indicator; so does
//                MAX_SPIN_MS, so a refresh that fails never leaves it spinning.
//
// The browser's own pull (Chrome on Android reloads on overscroll) is turned
// off with overscroll-behavior-y while the controller is armed, so one pull
// never refreshes twice.
//
// It imports nothing; test/javascript/pull_to_refresh.test.mjs loads it as a
// data: module.

export const PHONE_QUERY = "(pointer: coarse) and (max-width: 640px)"
export const THRESHOLD_PX = 72
export const MAX_SPIN_MS = 10000

// How far a finger `dy` pixels down has pulled, 0..1.2 of the threshold. The
// first half follows the finger; past it the pull resists.
export function pullProgress(dy) {
  if (!(dy > 0)) return 0
  const raw = dy / THRESHOLD_PX
  const eased = raw <= 0.5 ? raw : 0.5 + (raw - 0.5) * 0.55
  return Math.min(1.2, Math.round(eased * 1000) / 1000)
}

// A release refreshes once the eased pull reaches the threshold.
export function shouldRefresh(progress) {
  return progress >= 1
}

export function phoneTouch(win) {
  return !!(win && typeof win.matchMedia === "function" && win.matchMedia(PHONE_QUERY).matches)
}

// Whether a touch on `target` began inside a scroller below `root` that is not
// at its top: that drag scrolls the scroller back up, so it is not a pull.
export function insideScroller(target, root) {
  for (let el = target; el && el !== root; el = el.parentElement) if (el.scrollTop > 0) return true
  return false
}

// Wires one container. Answers a stop function, or null where it does not arm.
export function watchPullToRefresh(root, win, doc) {
  win = win || window
  doc = doc || document
  if (!phoneTouch(win)) return null

  const indicator = root.querySelector(".studio-pull-refresh-indicator")
  const status = root.querySelector("[data-pull-to-refresh-status]")
  const label = root.getAttribute("data-pull-to-refresh-label") || "Refreshing"
  const html = doc.documentElement
  const previousOverscroll = html.style.overscrollBehaviorY
  html.style.overscrollBehaviorY = "contain"

  let startY = null
  let progress = 0
  let spinTimer = null

  function setPull(value) {
    progress = value
    if (indicator) {
      indicator.hidden = value === 0 && root.getAttribute("data-pull-state") !== "refreshing"
      indicator.style.setProperty("--studio-pull", String(Math.min(1, value)))
    }
  }

  function finish(event) {
    const frameId = root.getAttribute("data-pull-to-refresh-frame")
    if (event && event.type === "turbo:frame-load" && (!frameId || event.target.id !== frameId)) return
    if (root.getAttribute("data-pull-state") !== "refreshing") return
    clearTimeout(spinTimer)
    root.setAttribute("data-pull-state", "settling")
    if (status) status.textContent = ""
    setPull(0)
  }

  function refresh() {
    root.setAttribute("data-pull-state", "refreshing")
    if (indicator) indicator.hidden = false
    if (status) status.textContent = label
    spinTimer = setTimeout(finish, MAX_SPIN_MS)
    const frameId = root.getAttribute("data-pull-to-refresh-frame")
    const frame = frameId && doc.getElementById(frameId)
    if (frame && typeof frame.reload === "function") frame.reload()
    else if (win.Turbo && typeof win.Turbo.visit === "function") win.Turbo.visit(win.location.href, { action: "replace" })
    else win.location.reload()
  }

  function onStart(event) {
    if (root.getAttribute("data-pull-state") === "refreshing") return
    if (event.touches.length !== 1 || (win.scrollY || 0) > 0 || insideScroller(event.target, root)) { startY = null; return }
    startY = event.touches[0].clientY
    root.setAttribute("data-pull-state", "pulling")
  }

  function onMove(event) {
    if (startY === null) return
    const dy = event.touches[0].clientY - startY
    if (dy <= 0 || (win.scrollY || 0) > 0) { setPull(0); return }
    // Holding the page still while the indicator follows the finger.
    if (event.cancelable) event.preventDefault()
    setPull(pullProgress(dy))
  }

  function onEnd() {
    if (startY === null) return
    startY = null
    if (shouldRefresh(progress)) { refresh(); return }
    root.setAttribute("data-pull-state", "settling")
    setPull(0)
  }

  root.addEventListener("touchstart", onStart, { passive: true })
  root.addEventListener("touchmove", onMove, { passive: false })
  root.addEventListener("touchend", onEnd)
  root.addEventListener("touchcancel", onEnd)
  doc.addEventListener("turbo:frame-load", finish)
  doc.addEventListener("turbo:load", finish)

  return function stop() {
    clearTimeout(spinTimer)
    html.style.overscrollBehaviorY = previousOverscroll
    root.removeEventListener("touchstart", onStart)
    root.removeEventListener("touchmove", onMove)
    root.removeEventListener("touchend", onEnd)
    root.removeEventListener("touchcancel", onEnd)
    doc.removeEventListener("turbo:frame-load", finish)
    doc.removeEventListener("turbo:load", finish)
  }
}
