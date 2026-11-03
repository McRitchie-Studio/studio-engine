// studio/style_section_nav: which section of the style guide the reader is in.
// It imports nothing; test/javascript/style_section_nav.test.mjs loads it as a
// data: module.
//
// `tops` is each section's top in viewport pixels, in page order. A section is
// current once its top reaches the bottom of the sticky row (`line`). Before
// the first one reaches it, the first is current. At the end of the page the
// last is current, because a short last section can never reach the line.
export function activeIndex(tops, line, atPageEnd = false) {
  if (tops.length === 0) return -1
  if (atPageEnd) return tops.length - 1

  let active = 0
  tops.forEach((top, index) => { if (top <= line) active = index })
  return active
}
