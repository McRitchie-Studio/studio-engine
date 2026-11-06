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
export function targetStop(action, current, page, count) {
  const last = Math.max(0, count - 1)
  const to = {
    prev: current - page,
    next: current + page,
    first: 0,
    last
  }[action]
  if (to === undefined) return current
  return Math.min(last, Math.max(0, to))
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
