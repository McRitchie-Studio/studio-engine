// studio/nav_collapse: the scroll-linked navbar collapse.
//
// Publishes --nav-p on the <header> once per animation frame from
// window.scrollY. The navbar's own stylesheet derives every collapsing
// dimension from it with calc(), so the header moves only in a frame the
// finger moved it, and stops the instant the finger does.
//
// It replaces `@scroll.window="scrolled = scrolled ? (scrollY > 5) : (scrollY
// > 60)"` plus `transition-all duration-300`. That pair let the FINGER set a
// step and an ease curve own everything after it. Measured in turf-monster at
// 390x844 before the change: the header ran 178px -> 139px and 34 of those
// 39px of document reflow landed AFTER the scroll had stopped, over 232ms, at
// up to 3px per frame of content nobody asked to move -- plus a 1px REVERSE
// lurch in the frame the class flipped, where a discrete text-3xl -> text-xl
// swap collided with the stylesheet's own `transition: font-size`.
//
// ADOPTING IT: put `nav-shell` and `data-studio-controller="nav-collapse"` on
// the header (studio/controllers/nav_collapse_controller), give each breakpoint
// band a `--nav-ramp`, and write the collapsing dimensions as calc()s off
// --nav-p. A header that still says `x-data="navCollapse()"` gets the same
// mechanism through the Alpine shim (studio/alpine_shims). This file ships NO
// sizing opinion, so an app whose navbar collapses to different endpoints than
// the engine's adopts the mechanism without touching its markup.
//
// Four details are load-bearing:
//
//   passive + rAF: the listener never blocks the compositor and coalesces a
//   burst of scroll events (iOS momentum fires far above 60Hz) into one write
//   per frame. The write lands on the HEADER, not :root: an inherited custom
//   property written on :root dirties style for the whole document every
//   frame, and it would leak the live page's scroll progress into the preview
//   headers on /navbar.
//
//   the smoothstep: collapsing a sticky, IN-FLOW header pulls the page up,
//   so during the collapse content moves by the scroll AND by the shrink:
//   faster than the finger, always. That is inherent; reclaiming the vertical
//   space is the point. What is tunable is the shape of the burst. --nav-ramp
//   is sized at 3x the band's collapse total and the ramp is smoothstepped,
//   whose slope is zero at both ends, so content speed LEAVES 1x, peaks near
//   1.5x mid-ramp, and returns to 1x with no velocity step. A linear ramp
//   equal to the collapse hits 2x and steps straight back to 1x.
//
//   the short-page guard: collapsing shortens the document by the collapse
//   total. On a page with barely more than that to scroll, the collapse
//   deletes the very scroll room that triggered it, the browser clamps
//   scrollY to 0, and the navbar flaps open and shut forever. roomExpanded
//   adds back the shrink ALREADY applied, so the measurement cannot chase
//   itself as it collapses.
//
//   reduced motion: scroll-linked motion has no clock left to slow down, but
//   resizing type under a moving finger is itself the motion some readers are
//   asking us to drop. Under the query --nav-p snaps 0/1 on the old
//   60/5 hysteresis instead of interpolating.

export const DEFAULT_RAMP = 144;
export const DEFAULT_MAX_STEP = 5;

// ONE FRAME OF THE COLLAPSE, as a pure function of what the frame measured.
//
//   y             window.scrollY, already clamped at 0
//   p             the progress published last frame, 0..1
//   ramp          --nav-ramp in px
//   maxPx         --nav-max-step in px of header travel per frame
//   scrollHeight  document.documentElement.scrollHeight
//   innerHeight   window.innerHeight
//   reduce        prefers-reduced-motion matches
//
// Answers { p, settling }: the progress to publish, and whether the frame
// clamp left it short of where the scroll position wants it (so the caller
// must schedule another frame).
export function collapseFrame({ y, p, ramp, maxPx, scrollHeight, innerHeight, reduce }) {
  // The height the document WOULD have with the navbar expanded. The
  // add-back is the whole trick; see the guard note above.
  var roomExpanded = scrollHeight - innerHeight + ramp * p;

  // WHERE THE COLLAPSE WANTS TO BE, from scroll position alone.
  var target;
  var snap = false;
  if (roomExpanded < ramp + 24) {
    target = 0;
    snap = true;
  } else if (reduce) {
    target = (p > 0 ? y > 5 : y > 60) ? 1 : 0;
    snap = true;
  } else {
    var t = Math.min(1, y / ramp);
    target = t * t * (3 - 2 * t);
  }

  // THE RATE LIMIT: how far the collapse may travel in ONE frame.
  //
  // Position-linked progress fixed motion that OUTLIVED the gesture. It
  // also guaranteed the opposite defect: if scrollY moves 90px between
  // two frames, so does the header's whole range. Measured in
  // turf-monster at 390x844, worst single-frame header height change by
  // scroll profile:
  //
  //     8px/frame (slow, deliberate)   3.9px
  //    24px/frame (normal swipe)      14.1px
  //    momentum flick                 39.0px   <- the ENTIRE collapse
  //    hard flick                     39.0px
  //
  // So the TARGET stays position-linked and the STEP is clamped. What
  // makes this safe is that a slow scroll never REACHES the clamp:
  // under --nav-max-step of header travel per frame the branch below
  // returns `target` untouched, so the slow feel is not approximated,
  // it is the same arithmetic.
  //
  // maxStep is derived, not tuned per band: engine.css sizes --nav-ramp
  // at 3x the band's collapse total, so a cap of MAX px/frame is
  // 3*MAX/ramp in --nav-p units. Mobile (ramp 120) gives 4.9px/frame,
  // desktop (ramp 144) 5.0px. Retune --nav-ramp without keeping that 3x
  // relation and this cap silently drifts with it.
  var next;
  if (snap) {
    // A guard refusal and a reduced-motion state are DECISIONS, not
    // motion; ramping them would animate the very thing each exists to
    // avoid.
    next = target;
  } else {
    var maxStep = (3 * maxPx) / ramp;
    var delta = target - p;
    next = Math.abs(delta) <= maxStep
      ? target
      : p + (delta > 0 ? maxStep : -maxStep);
  }

  return { p: next, settling: !snap && next !== target };
}

// The shadow is the one thing still on a clock, and it may stay there:
// box-shadow paints, it never reflows, so it cannot move content.
// Hysteresis keeps it from strobing at the boundary.
export function shadowLit(lit, y) {
  return lit ? y > 5 : y > 60;
}

// --nav-ramp and --nav-max-step off the header's computed style, each with
// its default when the band declares none.
export function readTuning(style) {
  var raw = parseFloat(style.getPropertyValue('--nav-ramp'));
  var step = parseFloat(style.getPropertyValue('--nav-max-step'));
  return {
    ramp: raw > 0 ? raw : DEFAULT_RAMP,
    maxPx: step > 0 ? step : DEFAULT_MAX_STEP
  };
}

// THE BINDING: one header, its listeners, and the frame loop. The Stimulus
// controller and the Alpine shim both drive this, so the two cannot drift.
// onScrolled(lit) fires when the shadow's hysteresis flips.
export class NavCollapse {
  constructor(el, onScrolled) {
    this.el = el;
    this.onScrolled = onScrolled || function () {};
    this.p = 0;
    this.scrolled = false;
    this.queued = false;
    this.stopped = false;
    this.tuning = { ramp: DEFAULT_RAMP, maxPx: DEFAULT_MAX_STEP };
    this._reduce = null;
    this._onScroll = this.onScroll.bind(this);
    this._onResize = this.onResize.bind(this);
    this._apply = this.apply.bind(this);
  }

  start() {
    this.stopped = false;
    this._reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
    this.tuning = readTuning(getComputedStyle(this.el));
    this.apply();

    window.addEventListener('scroll', this._onScroll, { passive: true });
    window.addEventListener('resize', this._onResize, { passive: true });
    if (this._reduce.addEventListener) this._reduce.addEventListener('change', this._apply);
  }

  // A Turbo visit tears the header down and builds a new one; without this
  // every visit would stack another listener on window.
  stop() {
    this.stopped = true;
    window.removeEventListener('scroll', this._onScroll);
    window.removeEventListener('resize', this._onResize);
    if (this._reduce && this._reduce.removeEventListener) {
      this._reduce.removeEventListener('change', this._apply);
    }
  }

  onScroll() {
    if (this.queued) return;
    this.queued = true;
    requestAnimationFrame(this._apply);
  }

  onResize() {
    this.tuning = readTuning(getComputedStyle(this.el));
    this.onScroll();
  }

  apply() {
    this.queued = false;
    if (this.stopped) return;
    // Clamped: rubber-band overscroll reports a NEGATIVE scrollY, and a
    // negative progress inflates the navbar past its expanded size.
    var y = Math.max(0, window.scrollY);
    var frame = collapseFrame({
      y: y,
      p: this.p,
      ramp: this.tuning.ramp,
      maxPx: this.tuning.maxPx,
      scrollHeight: document.documentElement.scrollHeight,
      innerHeight: window.innerHeight,
      reduce: this._reduce.matches
    });

    if (frame.p !== this.p) {
      this.p = frame.p;
      this.el.style.setProperty('--nav-p', frame.p.toFixed(4));
    }

    // KEEP FRAMES COMING WHILE CATCHING UP. Nothing else will schedule
    // one: the finger is off, so no more scroll events arrive, and
    // without this the collapse freezes wherever the clamp left it. It
    // converges LINEARLY and lands exactly: about 8 frames (~133ms) at
    // the mobile --nav-ramp of 120, and about 10 (~167ms) at the default
    // 144, from a hard flick.
    if (frame.settling) {
      this.queued = true;
      requestAnimationFrame(this._apply);
    }

    var lit = shadowLit(this.scrolled, y);
    if (lit !== this.scrolled) {
      this.scrolled = lit;
      this.onScrolled(lit);
    }
  }
}
