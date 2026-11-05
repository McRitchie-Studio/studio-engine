// studio/page_header: the page header's two measurements, as pure functions. It
// imports nothing; test/javascript/page_header.test.mjs loads it as a data: module.

// A sticky row is stuck once it has left its place in the flow. restTop is that
// place, measured by the sentinel beside it. The half pixel is rounding: at rest
// the two tops differ by a fraction at most, and a stuck row by at least a pixel.
export function isStuck(rowTop, restTop) {
  return rowTop - restTop > 0.5
}

// Whether the sentinel marks the row's place. It is absolutely positioned, so in a
// block parent it sits where the row starts. In a flex or grid parent it sits at the
// parent's start instead, whatever is above the row.
export function sentinelMarksThePlace(parentDisplay) {
  return !/flex|grid/.test(parentDisplay)
}

// Which ends of the tabs hide a tab, so a fade marks only an end with more to see.
export function hiddenEnds({ scrollLeft, clientWidth, scrollWidth }) {
  return {
    start: scrollLeft > 1,
    end: scrollLeft + clientWidth < scrollWidth - 1
  }
}

// How far the tabs must scroll to show a tab, clear of the fade. 0 if it shows.
export function revealBy(box, tab, margin = 32) {
  if (tab.left < box.left) return tab.left - box.left - margin
  if (tab.right > box.right) return tab.right - box.right + margin
  return 0
}
