// studio/in_page_links: a link to a place on the page the reader is on scrolls there. It
// does not load the page again (docs/PAGE_HEADER.md, "In-page links").
//
// Alex McRitchie, 2026-11-06, on the style guide's section pills: "The system needs to
// understand when a scroll down is the solution rather than a page change."
//
// WHY THE ENGINE HAS TO DO THIS. Turbo 8 does not treat a link to "#section" on the same
// path as a jump: its Navigator.locationWithActionIsSamePage returns false, so the click is a
// full Turbo visit. It fetches the page, renders it again, fires turbo:visit (the loader and
// the page transition hear it) and lands with a cut. That reads as a page load.
//
// So a plain click on a link whose address is this page (origin, path and query) with a
// #fragment whose element exists is taken here: no visit, a smooth scroll to the element
// under the pinned stack, the fragment pushed onto history, and focus moved to the target.
// Reduced motion jumps. Every other link is left alone, for Turbo or the browser.
//
// THE LISTENER BUBBLES, ON THE DOCUMENT. Turbo follows a link from a bubble listener on the
// window, which runs after this one and skips a click whose default is prevented. A
// component's own handler on the link (a tab that switches a panel by its hash, an Alpine
// @click.prevent) runs before this one, so a click it took is never taken here.
//
// BACK. Turbo turns history's scroll restoration to "manual", and on a popstate with Turbo's
// state it starts a restore visit: a second page load. So an entry this module pushed carries
// Turbo's own state, with the same restoration id, and a popstate between two entries of the
// page on screen is taken here first (capture, at the window) and scrolls to the place the
// reader left. A popstate to the page from another page is Turbo's, as before.
//
// It imports nothing; test/javascript/in_page_links.test.mjs loads it as a data: module.

// The event a link's own controller hears: the scroll began, and where it is going.
// detail: { link, target, hash }. It bubbles from the link.
export const SCROLL_EVENT = "studio:in-page-scroll"
// The scroll this module started has settled, or the reader took over. On the document.
export const SCROLL_END_EVENT = "studio:in-page-scroll-end"
// The state key on a history entry this module wrote: { scrollY } where the reader was.
export const STATE_KEY = "studioInPage"
// The mark on a target that took tabindex=-1 for focus here; engine.css draws no ring on it.
export const FOCUS_MARK = "data-in-page-focus"
// No scroll for this long ends the scroll, where the browser has no scrollend event. Where it
// has one, scrollend ends a scroll that moved (or the START_CAP_MS backstop below): on a slow
// main thread (a phone, or CI at 8x CPU) a smooth scroll's frames come further apart than
// this, and a quiet spell ended the jump at its first frame. Then the target moved and nothing
// aimed again.
export const SETTLE_MS = 150
// A scroll the reader never sees move still ends: the cap for a scroll that never starts.
// Where the browser has scrollend, it is also the backstop after each scroll event: a scroll
// that scrollend never follows (a page that shortens, and the browser pulls the scroll back
// with one scroll event and no scrollend) still ends. A slow frame (260ms at 8x CPU) does not.
export const START_CAP_MS = 400
// After the end, the target holds its place on the screen for this long: content above it
// that grows or shrinks (a lazy frame the scroll passed, whose page lands later) moves the
// page by the same amount, as scroll anchoring would. The body has anchoring off
// (studio/_head: with it on, the navbar's collapse made the scroll bounce). The reader's own
// input or any scroll the module did not make ends the hold at once. Growth later than this
// is not followed: the window is bounded so a page that reflows long after a jump is the
// reader's, not the jump's. At 8x CPU the lab's feed landed 0.5 to 1.7s after the end.
export const HOLD_MS = 3000
// A scroll aims again at a target that moved more than this, at most this many times.
export const AIM_SLACK_PX = 2
export const MAX_AIMS = 6
const REDUCED_MOTION = "(prefers-reduced-motion: reduce)"
const FOCUSABLE = "a[href], area[href], button, input, select, textarea, summary, iframe, [contenteditable], [tabindex]"

// The fragment of `href` when it points into the page at `here`: same origin, path and query,
// and a fragment that names something. Decoded, as the browser looks it up. Else null.
export function samePageFragment(href, here) {
  if (!href || !here) return null
  let url, page
  try {
    page = new URL(here)
    url = new URL(href, page)
  } catch {
    return null
  }
  if (url.origin !== page.origin || url.pathname !== page.pathname || url.search !== page.search) return null
  if (url.hash.length < 2) return null
  const raw = url.hash.slice(1)
  try {
    return decodeURIComponent(raw)
  } catch {
    return raw
  }
}

// A click the browser would follow in place: the main button, no modifier, not already taken.
export function plainClick(event) {
  if (!event || event.defaultPrevented) return false
  if (event.button !== undefined && event.button !== 0) return false
  return !(event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
}

// A link that asks for something other than a jump in this window: a new window or frame, a
// download, Turbo off, a method or stream link, or a named Turbo frame.
export function linkOptsOut(link) {
  const target = link.getAttribute("target")
  if (target && target.toLowerCase() !== "_self") return true
  if (link.hasAttribute("download")) return true
  if (link.hasAttribute("data-turbo-method") || link.hasAttribute("data-method")) return true
  if (link.hasAttribute("data-turbo-stream")) return true
  const frame = link.getAttribute("data-turbo-frame")
  if (frame && frame !== "_top") return true
  const drive = link.closest ? link.closest("[data-turbo]") : null
  return !!drive && drive.getAttribute("data-turbo") === "false"
}

// The element a fragment names: its id, else an <a name>, as the browser finds it.
export function findTarget(doc, fragment) {
  if (!fragment) return null
  const byId = doc.getElementById(fragment)
  if (byId) return byId
  const named = doc.getElementsByName ? [...doc.getElementsByName(fragment)] : []
  return named.find((el) => el.tagName === "A") || null
}

// THE DECISION: the target to scroll to for this click on this link, or null to leave it.
export function inPageTarget(event, link, doc, here) {
  if (!link || !plainClick(event) || linkOptsOut(link)) return null
  const fragment = samePageFragment(link.getAttribute("href"), here)
  return fragment === null ? null : findTarget(doc, fragment)
}

// The history state for the entry a jump pushes. It keeps Turbo's restoration id, so a
// restore from another page finds this page's snapshot, and moves its index one on.
export function pushedState(current) {
  const turbo = current && current.turbo
  if (!turbo) return { [STATE_KEY]: {} }
  return { turbo: { ...turbo, restorationIndex: (turbo.restorationIndex || 0) + 1 }, [STATE_KEY]: {} }
}

// Whether a popstate moves between two entries of the page on screen: the same address,
// bar the fragment, and, under Turbo, the same restoration id as the page Turbo shows.
export function samePagePop(state, shownId, url, shownUrl) {
  if (!sameDocumentAddress(url, shownUrl)) return false
  const turbo = state && state.turbo
  if (!turbo) return !!(state && state[STATE_KEY])
  return !!shownId && turbo.restorationIdentifier === shownId
}

export function sameDocumentAddress(a, b) {
  try {
    const one = new URL(a)
    const two = new URL(b)
    return one.origin === two.origin && one.pathname === two.pathname && one.search === two.search
  } catch {
    return false
  }
}

// How far above the target the scroll stops. Its own scroll-margin-top first: the engine's
// section-target and section-subtarget already know the stack. Without one, the bottom of the
// pinned stack, measured now, so the target never lands under the chrome.
export function marginFor(declared, stackBottom) {
  if (declared > 0) return null
  return stackBottom > 0 ? Math.round(stackBottom) : null
}

function focusTarget(target) {
  if (!target.matches(FOCUSABLE)) {
    target.setAttribute("tabindex", "-1")
    target.setAttribute(FOCUS_MARK, "")
    target.addEventListener("blur", () => {
      target.removeAttribute("tabindex")
      target.removeAttribute(FOCUS_MARK)
    }, { once: true })
  }
  try {
    target.focus({ preventScroll: true })
  } catch {
    // An element that cannot take focus leaves it where it was.
  }
}

let installed = false

export function installInPageLinks(doc) {
  if (installed || !doc || !doc.defaultView) return false
  installed = true
  const win = doc.defaultView
  let shownUrl = win.location.href
  let settling = null

  const turboHistory = () => (win.Turbo && win.Turbo.session && win.Turbo.session.history) || null
  const shownId = () => {
    const history = turboHistory()
    if (history && history.restorationIdentifier) return history.restorationIdentifier
    const state = win.history.state
    return (state && state.turbo && state.turbo.restorationIdentifier) || null
  }
  const reduced = () => !!(win.matchMedia && win.matchMedia(REDUCED_MOTION).matches)

  const scrollTo = (target, behavior) => {
    const declared = parseFloat(win.getComputedStyle(target).scrollMarginTop) || 0
    const stack = win.studioPinnedStack && win.studioPinnedStack.bottom ? win.studioPinnedStack.bottom() : 0
    const margin = marginFor(declared, stack)
    const inline = target.style.scrollMarginTop
    if (margin !== null) target.style.scrollMarginTop = `${margin}px`
    target.scrollIntoView({ behavior, block: "start" })
    if (margin !== null) target.style.scrollMarginTop = inline
  }
  const pageTop = (target) => target.getBoundingClientRect().top + win.scrollY
  const INPUTS = ["wheel", "touchstart", "keydown", "pointerdown"]

  // After a jump's end: each frame for HOLD_MS, a target that moved on the page moves the page
  // with it, at once, so its place on the screen stays (scroll anchoring, for this one
  // element). The check runs in an animation frame, after the growth's layout and before its
  // paint, so the reader sees no frame with the target out of place. It lets go at the first
  // input, at any scroll that is not its own (the reader's scrollbar, an app's scrollTo, a
  // clamp), at the next jump, at a Back or Forward, after MAX_AIMS moves, or at HOLD_MS.
  const hold = (target) => {
    if (!win.requestAnimationFrame) return
    let held = win.scrollY
    let top = target.getBoundingClientRect().top
    let moves = 0
    let frame = null
    let timer = null
    const release = () => {
      win.cancelAnimationFrame(frame)
      win.clearTimeout(timer)
      for (const name of INPUTS) win.removeEventListener(name, release, true)
      if (settling === release) settling = null
    }
    const check = () => {
      // A scroll the hold did not make is the reader's or the app's: it lets go first.
      if (Math.abs(win.scrollY - held) > AIM_SLACK_PX) return release()
      // A target a render took out of the page has no place to keep.
      if (target.isConnected === false) return release()
      const now = target.getBoundingClientRect().top
      if (Math.abs(now - top) > AIM_SLACK_PX) {
        if (moves >= MAX_AIMS) return release()
        moves += 1
        win.scrollBy({ top: now - top, behavior: "instant" })
        held = win.scrollY
        top = target.getBoundingClientRect().top
      }
      frame = win.requestAnimationFrame(check)
    }
    settling = release
    for (const name of INPUTS) win.addEventListener(name, release, { capture: true, passive: true })
    timer = win.setTimeout(release, HOLD_MS)
    frame = win.requestAnimationFrame(check)
  }

  // One jump, from its start to its end. The browser fixes a smooth scroll's end where the
  // target was at the start. Content that grows on the way (a lazy frame the scroll passes,
  // the navbar's collapse) moves the target, so the scroll aims again, up to MAX_AIMS times,
  // until the reader takes over (a wheel, a touch, a key, a press). The end is the browser's
  // scrollend where it has one (else START_CAP_MS after the last scroll event), a quiet spell
  // where not; then the end event, once. A scroll that never starts ends at the cap either way. Then, unless the reader took over, the
  // target holds its place for HOLD_MS (hold, above).
  const jump = (target, behavior) => {
    if (settling) settling()
    const hasScrollend = "onscrollend" in win
    let quiet = null
    let cap = null
    let aims = 0
    let reader = false
    let live = true
    let aimed = pageTop(target)
    const takeOver = () => { reader = true }
    const reaim = () => {
      if (reader || aims >= MAX_AIMS || Math.abs(pageTop(target) - aimed) <= AIM_SLACK_PX) return false
      aims += 1
      scrollTo(target, behavior)
      aimed = pageTop(target)
      return true
    }
    const wait = (ms) => {
      win.clearTimeout(quiet)
      quiet = win.setTimeout(end, ms)
    }
    const end = () => {
      if (!live) return
      // The target moved after the scroll stopped: aim once more and wait for that end.
      if (reaim()) return wait(START_CAP_MS)
      win.removeEventListener("scroll", onScroll)
      win.removeEventListener("scrollend", end)
      for (const name of INPUTS) win.removeEventListener(name, takeOver, true)
      win.clearTimeout(quiet)
      win.clearTimeout(cap)
      live = false
      if (settling === stop) settling = null
      if (!reader) hold(target)
      doc.dispatchEvent(new win.CustomEvent(SCROLL_END_EVENT))
    }
    const onScroll = () => {
      win.clearTimeout(cap)
      reaim()
      // The scroll has started. With scrollend, scrollend ends it, and START_CAP_MS after the
      // last scroll event is the backstop for a scroll that scrollend never follows.
      wait(hasScrollend ? START_CAP_MS : SETTLE_MS)
    }
    const stop = () => {
      reader = true
      end()
    }
    settling = stop
    win.addEventListener("scroll", onScroll, { passive: true })
    if (hasScrollend) win.addEventListener("scrollend", end)
    for (const name of INPUTS) win.addEventListener(name, takeOver, { capture: true, passive: true })
    cap = win.setTimeout(end, START_CAP_MS)
    scrollTo(target, behavior)
    aimed = pageTop(target)
  }

  doc.addEventListener("click", (event) => {
    const link = event.target && event.target.closest ? event.target.closest("a[href]") : null
    const target = inPageTarget(event, link, doc, win.location.href)
    if (!target) return
    event.preventDefault()

    const oldURL = win.location.href
    const href = new URL(link.getAttribute("href"), oldURL).href
    const behavior = reduced() ? "instant" : "smooth"
    if (href !== oldURL) {
      // The entry the reader leaves keeps where they were, for Back.
      win.history.replaceState({ ...(win.history.state || {}), [STATE_KEY]: { scrollY: win.scrollY } }, "", oldURL)
      const state = pushedState(win.history.state)
      win.history.pushState(state, "", href)
      const history = turboHistory()
      if (history && state.turbo) {
        history.currentIndex = state.turbo.restorationIndex
        history.location = new URL(href)
      }
    }
    shownUrl = win.location.href

    // A scroll still running from an earlier click ends first, so its end cannot release this one.
    if (settling) settling()
    link.dispatchEvent(new win.CustomEvent(SCROLL_EVENT, { bubbles: true, detail: { link, target, hash: new URL(href).hash } }))
    jump(target, behavior)
    focusTarget(target)
    if (href !== oldURL) win.dispatchEvent(new win.HashChangeEvent("hashchange", { oldURL, newURL: href }))
  })

  // Capture at the window runs ahead of Turbo's own popstate listener there.
  win.addEventListener("popstate", (event) => {
    const url = win.location.href
    if (!samePagePop(event.state, shownId(), url, shownUrl)) {
      shownUrl = url
      return
    }
    shownUrl = url
    // The traversal's place wins over a jump or a hold still running.
    if (settling) settling()
    // Turbo would start a restore visit; without Turbo the browser restores the scroll itself.
    if (event.state && event.state.turbo) {
      event.stopImmediatePropagation()
      const history = turboHistory()
      if (history) {
        history.location = new URL(url)
        history.currentIndex = event.state.turbo.restorationIndex
      }
    }
    if (win.history.scrollRestoration !== "manual") return
    const saved = event.state && event.state[STATE_KEY]
    if (saved && typeof saved.scrollY === "number") {
      win.scrollTo({ top: saved.scrollY, behavior: "instant" })
      return
    }
    const fragment = samePageFragment(url, url)
    const target = findTarget(doc, fragment)
    if (target) scrollTo(target, "instant")
    else if (!fragment) win.scrollTo({ top: 0, behavior: "instant" })
  }, { capture: true })

  // A Turbo visit shows another page, or this one anew.
  doc.addEventListener("turbo:load", () => { shownUrl = win.location.href })
  return true
}

if (typeof document !== "undefined") installInPageLinks(document)
