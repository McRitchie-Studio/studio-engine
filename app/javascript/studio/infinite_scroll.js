// studio/infinite_scroll: the next page loads as its end comes near
// (docs/LOADER.md, "Infinite scroll"). The markup is studio_infinite_scroll:
//
//   <div class="studio-infinite-scroll" data-studio-controller="infinite-scroll">
//     ...page 1's items...
//     <turbo-frame id="posts-page-2" data-infinite-scroll-next>
//       <a href="/posts?page=2" data-infinite-scroll-more>Load more</a>
//     </turbo-frame>
//     <p role="status" aria-live="polite" data-infinite-scroll-status></p>
//   </div>
//
// THE BUTTON IS THE PRIMITIVE. "Load more" is an ordinary link inside the next
// page's frame, so a click loads that frame with Turbo, and with no script at all
// it opens the next page. This module only clicks it early: when the frame comes
// within NEAR_PX of the viewport (IntersectionObserver, watching the button's
// row, since the frame itself takes no box), it points the frame at
// the link's URL. The button stays in view the whole time, for a keyboard, a
// screen reader or a browser with no observer.
//
//   announce   once a page lands, the status line says how many items came
//              ("12 more loaded"), and that the list is done when no next frame
//              came with them. It is polite: it waits for the reader to pause.
//   focus      a page the reader asked for with the keyboard moves focus to
//              its first new item, since the button they pressed is gone.
//
// It imports nothing; test/javascript/infinite_scroll.test.mjs loads it as a
// data: module.

export const NEAR_PX = 600
export const NEXT = "turbo-frame[data-infinite-scroll-next]"
export const MORE = "[data-infinite-scroll-more]"
export const STATUS = "[data-infinite-scroll-status]"
export const DEFAULT_ANNOUNCE = "%{count} more loaded"

// The status line for a page of `count` items. `done` adds the end label.
export function announcement(template, count, done, endLabel) {
  const said = String(template || DEFAULT_ANNOUNCE).replace("%{count}", String(count))
  return done && endLabel ? `${said}. ${endLabel}` : said
}

// The items a landed frame brought: its element children, less the next frame
// and the end line, which are the list's machinery rather than its content.
export function newItems(frame) {
  return Array.from(frame.children || []).filter((el) =>
    !(el.matches && (el.matches(NEXT) || el.matches(".studio-infinite-scroll-end") || el.matches(".studio-infinite-scroll-more"))))
}

// The one frame still waiting for its page: not loaded, not loading.
export function waitingFrame(root) {
  const frames = Array.from(root.querySelectorAll(NEXT))
  return frames.find((frame) => !frame.hasAttribute("src") && !frame.hasAttribute("complete")) || null
}

// What the observer watches for a frame: its button row, else its link.
export function sentinelOf(frame) {
  return frame.querySelector(".studio-infinite-scroll-more") || frame.querySelector(MORE)
}

// Points the frame at its link's URL, once. Answers whether it started a load.
export function loadNext(frame) {
  if (!frame || frame.hasAttribute("src")) return false
  const link = frame.querySelector(MORE)
  const url = link && link.getAttribute("href")
  if (!url) return false
  frame.setAttribute("src", url)
  return true
}

function say(status, text, win) {
  if (!status) return
  // Emptied first, so the same words said twice are heard twice.
  status.textContent = ""
  const put = () => { status.textContent = text }
  if (win && typeof win.requestAnimationFrame === "function") win.requestAnimationFrame(put)
  else put()
}

// Wires one list. Answers a stop function for the controller's disconnect.
export function watchInfiniteScroll(root, win) {
  win = win || window
  let watcher = null
  let watched = null
  let byKeyboard = false

  // The frame takes no box (display: contents), and an observer sees only
  // boxes, so the watch is on its sentinel: the button's row inside it.
  function arm() {
    const frame = waitingFrame(root)
    const sentinel = frame && sentinelOf(frame)
    if (sentinel === watched) return
    if (watcher && watched) watcher.unobserve(watched)
    watched = sentinel
    if (!sentinel || !watcher) return
    watcher.observe(sentinel)
  }

  if (typeof win.IntersectionObserver === "function") {
    watcher = new win.IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return
        watcher.unobserve(entry.target)
        byKeyboard = false
        loadNext(entry.target.closest(NEXT))
      })
    }, { rootMargin: `0px 0px ${NEAR_PX}px 0px` })
  }

  // A click on the button with no pointer behind it is a keyboard press.
  function onClick(event) {
    const link = event.target && event.target.closest && event.target.closest(MORE)
    if (link && root.contains(link)) byKeyboard = event.detail === 0
  }

  function onLoad(event) {
    const frame = event.target
    if (!frame || !frame.matches || !frame.matches(NEXT) || !root.contains(frame)) return
    const items = newItems(frame)
    const done = !frame.querySelector(NEXT)
    say(root.querySelector(STATUS), announcement(root.getAttribute("data-infinite-scroll-announce"), items.length, done,
      root.getAttribute("data-infinite-scroll-end")), win)
    if (byKeyboard && items[0]) {
      if (!items[0].hasAttribute("tabindex")) items[0].setAttribute("tabindex", "-1")
      items[0].focus({ preventScroll: false })
    }
    byKeyboard = false
    arm()
  }

  root.addEventListener("click", onClick, true)
  root.addEventListener("turbo:frame-load", onLoad)
  arm()

  return function stop() {
    root.removeEventListener("click", onClick, true)
    root.removeEventListener("turbo:frame-load", onLoad)
    if (watcher) watcher.disconnect()
  }
}
