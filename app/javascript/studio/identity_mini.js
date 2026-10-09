// studio/identity_mini: when the compact identity bar
// (studio/profiles/_identity_mini) takes over from the full identity card.
//
// The bar is fixed under the navbar and ships hidden and inert. It shows once
// most of the full card has scrolled away, and on the edit page it carries the
// save controls from then on. The identity-mini controller binds one bar to
// its page's card.
//
// It imports nothing; test/javascript/identity_mini.test.mjs loads it as a
// data: module.

// The class that shows the bar (studio/profiles/_identity_styles).
export const VISIBLE_CLASS = "is-visible"

// The card the bar stands in for.
export const FULL_SELECTOR = "[data-studio-identity-full]"

// The bar shows once less than this much of the card is on screen. Part-way,
// so the two overlap briefly and there is no moment with neither on screen. A
// ratio and not a pixel offset: the card's height changes with the name's wrap
// and with whether an address sits under it.
export const SHOW_BELOW_RATIO = 0.6

// The navbar covers the top of the viewport, so the pixels behind it are not
// visible ones. The spread of thresholds is what lets the ratio test run:
// with one threshold the callback fires only at fully in and fully out.
export const OBSERVER_OPTIONS = {
  rootMargin: "-72px 0px 0px 0px",
  threshold: [0, 0.2, 0.4, 0.5, 0.6, 0.8, 1]
}

// Whether the card counts as gone. A card taller than the viewport never
// reaches ratio 1, so not intersecting at all counts in its own right.
export function cardGone(entry) {
  return !entry.isIntersecting || entry.intersectionRatio < SHOW_BELOW_RATIO
}

// Shows or hides the bar. The tab order and the accessibility tree follow the
// same decision as the class: opacity and pointer-events cannot say "not
// here", and the bar holds buttons.
export function showBar(mini, visible) {
  mini.classList.toggle(VISIBLE_CLASS, visible)
  mini.inert = !visible
}

// One bar watching one card. `Observer` is IntersectionObserver; a browser
// without it leaves the bar hidden and inert, and the page fully usable.
export class IdentityMini {
  constructor(mini, full, Observer) {
    this.mini = mini
    this.full = full
    this.Observer = Observer
    this.observer = null
  }

  start() {
    this.stop()
    if (!this.mini || !this.full || !this.Observer) return false
    this.observer = new this.Observer((entries) => showBar(this.mini, cardGone(entries[0])), OBSERVER_OPTIONS)
    this.observer.observe(this.full)
    return true
  }

  stop() {
    if (this.observer) this.observer.disconnect()
    this.observer = null
  }

  // Hidden again, as the bar ships: for a page going into Turbo's cache.
  reset() {
    this.stop()
    if (this.mini) showBar(this.mini, false)
  }
}
