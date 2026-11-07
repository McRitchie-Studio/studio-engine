// studio/carousel: the arithmetic behind studio/_carousel. The track is a native
// scroll-snap row, so a swipe, a trackpad and a focused link all move it with no
// script; studio/controllers/carousel_controller only reads where the row is and
// moves it for the arrows, the dots and the keyboard.
//
// A STOP is a place the row can rest: the start of a slide, until the row can
// scroll no further, and then its end. Six slides three to a view rest at four
// stops, so the dots past the last stop are hidden.
//
// It imports nothing; test/javascript/carousel.test.mjs loads it as a data: module.

// Within this many pixels of an end counts as at it: a zoomed page scrolls in
// fractions.
export const TOLERANCE = 2

// Which ends of the row hide a slide.
export function hiddenEnds({ scrollLeft, clientWidth, scrollWidth }) {
  const max = Math.max(0, scrollWidth - clientWidth)
  return { start: scrollLeft > TOLERANCE, end: scrollLeft < max - TOLERANCE }
}

// The scroll position of each stop, from each slide's offset and the row's
// furthest scroll. The slides past the last stop share it.
export function stops(offsets, max) {
  const reachable = offsets.filter((offset) => offset < max - TOLERANCE)
  if (reachable.length === offsets.length) return reachable.length ? reachable : [0]
  return [...reachable, max]
}

// The stop the row rests at, or is nearest to while it moves.
export function currentStop(scrollLeft, positions) {
  if (positions.length === 0) return 0
  const last = positions.length - 1
  if (scrollLeft >= positions[last] - TOLERANCE) return last

  let nearest = 0
  positions.forEach((position, index) => {
    if (Math.abs(position - scrollLeft) < Math.abs(positions[nearest] - scrollLeft)) nearest = index
  })
  return nearest
}

// How many whole slides a view shows: an arrow moves the row by that many, so
// the slide that peeked in at the edge is the first one after the press.
export function perPage(clientWidth, slideWidth, gap) {
  if (!(slideWidth > 0)) return 1
  return Math.max(1, Math.floor((clientWidth + gap + TOLERANCE) / (slideWidth + gap)))
}

// The stop an arrow or a key takes the row to, held to the first and last stop.
// A LOOPING row (loop: true) wraps instead: Next at the last stop goes to the
// first, Previous at the first goes to the last. A page that would overshoot an
// end still lands on that end first, so no slide is skipped on the way round.
// The controller uses this wrap only for a looping row it has not cloned; a cloned
// row (THE LOOP'S CLONES, below) moves by loopStop instead, round the seam.
export function targetStop(action, current, page, count, loop = false) {
  const last = Math.max(0, count - 1)
  if (loop && last > 0) {
    if (action === "next" && current >= last) return 0
    if (action === "prev" && current <= 0) return last
  }
  const to = {
    prev: current - page,
    next: current + page,
    first: 0,
    last
  }[action]
  if (to === undefined) return current
  return Math.min(last, Math.max(0, to))
}

// AUTOPLAY (the partial's autoplay:, data-carousel-autoplay): the row moves one
// stop each interval, never while a reason holds it still.

// The interval in seconds from the attribute, or null for no autoplay.
export function autoplaySeconds(value) {
  if (value === null || value === undefined || value === "") return null
  const seconds = Number(value)
  return Number.isFinite(seconds) && seconds > 0 ? seconds : null
}

// The stop autoplay moves to from `current`: the next one, round to the first
// on a looping row. Null where it has nowhere to go: the last stop of a row that
// does not loop (autoplay stops there), or a row with one stop.
export function autoplayStop(current, count, loop = false) {
  if (!(count > 1)) return null
  if (current < count - 1) return current + 1
  return loop ? 0 : null
}

// What holds autoplay still. "stopped" is the reader's own pause button (and
// reduced motion, which starts the row stopped); it alone shows the play icon.
// The rest lift on their own: the pointer leaves, focus leaves, the tab shows,
// the row scrolls back into view, the reader stops touching it.
export const PAUSE_REASONS = ["stopped", "hover", "focus", "hidden", "offscreen", "interaction"]

// The reasons with one set or lifted. A new Set: the old one is left alone.
export function withReason(reasons, reason, on) {
  const next = new Set(reasons)
  if (on) next.add(reason)
  else next.delete(reason)
  return next
}

// The reasons a row starts with: stopped under reduced motion, hidden in a
// hidden tab.
export function initialReasons({ reducedMotion = false, hidden = false } = {}) {
  const reasons = new Set()
  if (reducedMotion) reasons.add("stopped")
  if (hidden) reasons.add("hidden")
  return reasons
}

// Whether autoplay runs: it is on and nothing holds it.
export function autoplayRunning(seconds, reasons) {
  return seconds !== null && seconds > 0 && reasons.size === 0
}

// How long after the reader's last swipe, scroll or press autoplay waits to
// resume: one interval, and never under five seconds.
export function idleDelay(seconds) {
  return Math.max(5000, (seconds || 0) * 1000)
}

// The pause button's name, from whether the reader has stopped the row.
export function toggleLabel(stopped) {
  return stopped ? "Play slideshow" : "Pause slideshow"
}

// Keys inside these belong to the element, not the row: a form field, and a widget
// that moves its own selection with the arrow keys.
export const KEY_OWNERS = [
  "input", "textarea", "select", "[contenteditable]:not([contenteditable='false'])",
  "[role='slider']", "[role='spinbutton']", "[role='listbox']", "[role='combobox']",
  "[role='tablist']", "[role='radiogroup']", "[role='menu']", "[role='menubar']",
  "[role='grid']", "[role='tree']", "[role='treegrid']", "video", "audio"
].join(", ")

// Whether a key pressed on `target` is the carousel `region`'s to handle: not
// when the target sits in a key owner, or in a carousel nested inside this one,
// which handles its own keys.
export function ownsKey(target, region, carousel = ".carousel") {
  if (!target?.closest) return false
  if (target.closest(KEY_OWNERS)) return false
  return target.closest(carousel) === region
}

// The action a key asks for, or null for a key the carousel leaves alone.
export function keyAction(key) {
  return { ArrowLeft: "prev", ArrowRight: "next", Home: "first", End: "last" }[key] || null
}

// The words the status line reads after a move: "Slides 4 to 6 of 9".
export function positionText(first, shown, total) {
  const from = first + 1
  const to = Math.min(total, first + shown)
  return from === to ? `Slide ${from} of ${total}` : `Slides ${from} to ${to} of ${total}`
}

// The spotlight's stops: the scroll position that centres each slide, from each
// slide's offset and width in the track (its padding included), held to the row.
// Every slide is a stop, so every dot shows and an arrow moves one slide.
export function centerStops(slides, clientWidth, max) {
  if (slides.length === 0) return [0]
  return slides.map(({ left, width }) => Math.min(max, Math.max(0, left + width / 2 - clientWidth / 2)))
}

// The stop a row opens on, from the partial's start index: a standard row with
// more slides than stops opens at its last stop.
export function startStop(start, count) {
  if (!(count > 0)) return 0
  const index = Math.floor(Number(start)) || 0
  return Math.min(count - 1, Math.max(0, index))
}

// THE LOOP'S CLONES. A looping row (loop: true, more than one slide) is visually
// continuous: the controller copies the last slides before the first and the first
// slides after the last, so the space either side of an end shows the slides round
// the seam. A clone is aria-hidden and inert, with no id and no test hook, so a
// screen reader and Tab meet each slide once; the dots and the status line count the
// real slides only.
//
// Each place in that longer row has a VIRTUAL index: the real slides are 0 to
// total - 1, the clones before them -count to -1, the clones after total to
// total + count - 1. A move across the seam glides to a clone, and once the row
// rests there the controller jumps, with no glide, to the real slide it copies.

// The index of a real slide from a virtual one.
export function wrapIndex(index, total) {
  if (!(total > 0)) return 0
  return ((index % total) + total) % total
}

// How many clones each side: a wide row's slides plus one, enough to fill the view
// beside either end in both styles. None for a row of one slide.
export function cloneCount(perView, total) {
  if (!(total > 1)) return 0
  const view = Number(perView)
  return Math.ceil(Number.isFinite(view) && view > 0 ? Math.min(view, 6) : 3) + 1
}

// The real slide each clone copies, in row order: `before` sits ahead of the first
// slide, `after` behind the last. A short row repeats round itself.
export function cloneLayout(total, count) {
  if (!(total > 1) || !(count > 0)) return { before: [], after: [] }
  const before = []
  const after = []
  for (let k = count; k >= 1; k -= 1) before.push(wrapIndex(-k, total))
  for (let k = 0; k < count; k += 1) after.push(wrapIndex(k, total))
  return { before, after }
}

// The virtual index an arrow, a key or autoplay takes a cloned row to: a page on
// either way, round the seam with no end. Home and End go to the first and last
// real slide. Held to the clones, so a press mid-glide never runs off the row.
export function loopStop(action, current, page, total, count) {
  const to = { prev: current - page, next: current + page, first: 0, last: total - 1 }[action]
  if (to === undefined) return current
  return Math.min(total - 1 + count, Math.max(-count, to))
}

// The virtual index nearest `current` that shows real slide `index`: a dot takes
// the short way round the seam.
export function nearestVirtual(index, current, total, count) {
  const options = [index - total, index, index + total].filter((v) => v >= -count && v <= total - 1 + count)
  return options.reduce((best, v) => (Math.abs(v - current) < Math.abs(best - current) ? v : best), index)
}

// The real slide a row resting on a clone jumps to, or null when it rests on a real one.
export function seamJump(virtual, total) {
  if (!(total > 0)) return null
  return virtual < 0 || virtual >= total ? wrapIndex(virtual, total) : null
}

// The attributes a clone drops: ids and names (a clone must not answer a #fragment or
// join a form), test hooks, and Stimulus wiring (a clone runs no controller and is
// no one's target), and the carousel's own marks.
export const CLONE_STRIP = /^(id|name|data-(test|testid|test-id|qa|cy)|data-(studio-)?(controller|action)|data-[\w-]+-target|data-carousel-start-slide|data-current)$/

// The status line of a looping row, whose view may run round the seam:
// "Slides 5 to 6 and 1 of 6".
export function loopPositionText(first, shown, total) {
  const count = Math.min(shown, total)
  if (first + count <= total) return positionText(first, count, total)
  const over = first + count - total
  const head = first + 1 === total ? `Slides ${total}` : `Slides ${first + 1} to ${total}`
  return `${head} and ${over === 1 ? "1" : `1 to ${over}`} of ${total}`
}
