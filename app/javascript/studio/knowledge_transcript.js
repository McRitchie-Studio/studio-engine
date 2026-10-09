// studio/knowledge_transcript: a meeting's recording beside its transcript, on
// the knowledge layer's document page (/admin/knowledge/:id). A click on a cue
// seeks the player there and plays; while it plays, the cue being spoken is
// marked and kept in view inside the cue list.
//
// The markup is studio/knowledge_docs/_preview_transcript:
//
//   <div data-studio-controller="knowledge-transcript">
//     <video data-knowledge-player controls ...></video>
//     <ol data-knowledge-cues>
//       <li data-seconds="62"><button type="button">1:02</button> ...</li>
//
// It arrives inside a lazy <turbo-frame>, after the page has loaded; the
// knowledge-transcript controller (registered lazily by studio/stimulus) mounts
// it whenever the element appears. Without this module the page still works:
// the player has its own controls and the cues are plain text.
//
// WHAT IT COSTS, since a transcript can hold 5,000 cues:
//   - mounting reads each cue's data-seconds once and sorts the cues by time
//     once (cueOrder);
//   - a `timeupdate` (a browser fires several a second) is one binary search,
//     MAX_SEARCH_STEPS comparisons at most whatever the cue count (cueAt), and
//     touches the page only when the current cue CHANGED: two class writes, and
//     one scroll of the cue list;
//   - every cue shares the one click listener on the list.
//
// FOLLOWING NEVER FIGHTS THE READER. Only the cue list's own scrollTop is ever
// written, never the page's. When the reader scrolls the list, following stops
// for FOLLOW_PAUSE_MS after their last scroll; the scroll this module causes is
// told apart from theirs by the position it left the list at. A click on a cue
// resumes following at once.
//
// It imports nothing; test/javascript/knowledge_transcript.test.mjs loads it
// as a data: module. Bound to the page by the knowledge-transcript controller.

export const PLAYER = "[data-knowledge-player]"
export const CUES = "[data-knowledge-cues]"
export const CUE = "[data-seconds]"
export const CURRENT_CLASS = "knowledge-cue-current"
export const READY_ATTRIBUTE = "data-knowledge-transcript-ready"

// How long after the reader's last scroll of the cue list following stays off.
export const FOLLOW_PAUSE_MS = 5000
// How far down the list's visible height a followed cue is placed.
export const FOLLOW_OFFSET = 0.25
// The most halvings cueAt makes: enough for 2^32 cues.
export const MAX_SEARCH_STEPS = 32

// A cue's time in seconds, or NaN for anything that is not a time.
export function secondsOf(value) {
  if (value === null || value === undefined || value === "") return NaN
  const seconds = Number(value)
  return Number.isFinite(seconds) && seconds >= 0 ? seconds : NaN
}

// The cue positions ordered by time, earliest first; cues that share a time
// keep their page order. A transcript is nearly always in time order already,
// but nothing promises it, and cueAt needs it. A cue with no time is left out.
export function cueOrder(seconds) {
  const order = []
  for (let index = 0; index < seconds.length; index++) {
    if (Number.isFinite(seconds[index])) order.push(index)
  }
  return order.sort((a, b) => (seconds[a] - seconds[b]) || (a - b))
}

// The position (in `seconds`) of the cue being spoken at `time`: the last cue,
// by time, that has started. -1 before the first cue. A binary search over
// `order`.
export function cueAt(order, seconds, time) {
  if (!Number.isFinite(time)) return -1
  let low = 0
  let high = order.length
  for (let step = 0; step < MAX_SEARCH_STEPS && low < high; step++) {
    const middle = (low + high) >>> 1
    if (seconds[order[middle]] <= time) low = middle + 1
    else high = middle
  }
  return low === 0 ? -1 : order[low - 1]
}

// Where the cue list should scroll to so the cue is in view, or null when it
// already is. Positions are in the list's own scroll coordinates.
//   cueTop, cueHeight: the cue;  scrollTop, viewHeight: the list's window
export function followTop({ cueTop, cueHeight, scrollTop, viewHeight }) {
  if (cueTop >= scrollTop && cueTop + cueHeight <= scrollTop + viewHeight) return null
  return Math.max(0, Math.round(cueTop - viewHeight * FOLLOW_OFFSET))
}

// Whether the reader has text selected, in which case a click on a line is the
// end of a selection and not a request to seek.
function selecting(win) {
  if (!win || typeof win.getSelection !== "function") return false
  const selection = win.getSelection()
  return !!selection && !selection.isCollapsed && String(selection).length > 0
}

// Binds one transcript. `root` holds the player and the cue list. Returns
// { destroy, current } or null when either is missing. `now` and `win` are
// arguments so a test can supply them.
export function mountTranscript(root, { now = () => Date.now(), win = (typeof window === "undefined" ? null : window) } = {}) {
  const media = root.querySelector(PLAYER)
  const list = root.querySelector(CUES)
  if (!media || !list) return null

  const cues = Array.from(list.querySelectorAll(CUE))
  const seconds = cues.map((cue) => secondsOf(cue.getAttribute("data-seconds")))
  const order = cueOrder(seconds)

  let current = -1
  let pausedUntil = 0
  // The scrollTop this module last left the list at; a scroll event that
  // finds the list there is its own.
  let placedAt = null

  const follow = (cue) => {
    if (now() < pausedUntil) return
    const listBox = list.getBoundingClientRect()
    const cueBox = cue.getBoundingClientRect()
    const top = followTop({
      cueTop: cueBox.top - listBox.top + list.scrollTop,
      cueHeight: cueBox.height,
      scrollTop: list.scrollTop,
      viewHeight: list.clientHeight
    })
    if (top === null) return
    list.scrollTop = top
    placedAt = list.scrollTop
  }

  const mark = () => {
    const index = cueAt(order, seconds, media.currentTime)
    if (index === current) return
    if (current >= 0) {
      cues[current].classList.remove(CURRENT_CLASS)
      cues[current].removeAttribute("aria-current")
    }
    current = index
    if (index < 0) return
    cues[index].classList.add(CURRENT_CLASS)
    cues[index].setAttribute("aria-current", "true")
    follow(cues[index])
  }

  const seek = (event) => {
    const target = event.target
    const cue = target && typeof target.closest === "function" ? target.closest(CUE) : null
    if (!cue || !list.contains(cue)) return
    // The time itself is a button and always seeks; the rest of the line seeks
    // unless the click finished a text selection.
    const onButton = typeof target.closest === "function" && !!target.closest("button")
    if (!onButton && selecting(win)) return

    const at = secondsOf(cue.getAttribute("data-seconds"))
    if (!Number.isFinite(at)) return
    pausedUntil = 0
    media.currentTime = at
    const playing = typeof media.play === "function" ? media.play() : null
    if (playing && typeof playing.catch === "function") playing.catch(() => {})
    mark()
  }

  const scrolled = () => {
    if (placedAt !== null && Math.abs(list.scrollTop - placedAt) < 1) return
    placedAt = null
    pausedUntil = now() + FOLLOW_PAUSE_MS
  }

  media.addEventListener("timeupdate", mark)
  media.addEventListener("seeked", mark)
  list.addEventListener("click", seek)
  list.addEventListener("scroll", scrolled, { passive: true })
  root.setAttribute(READY_ATTRIBUTE, "")
  mark()

  return {
    current: () => current,
    destroy() {
      media.removeEventListener("timeupdate", mark)
      media.removeEventListener("seeked", mark)
      list.removeEventListener("click", seek)
      list.removeEventListener("scroll", scrolled)
      root.removeAttribute(READY_ATTRIBUTE)
      if (current >= 0) {
        cues[current].classList.remove(CURRENT_CLASS)
        cues[current].removeAttribute("aria-current")
      }
      current = -1
    }
  }
}
