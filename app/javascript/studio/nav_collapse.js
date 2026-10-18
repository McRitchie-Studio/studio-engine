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
// Five details are load-bearing:
//
//   the hold: the header keeps its EXPANDED footprint in the page's flow. As it
//   shrinks, the controller gives the difference back as margin below it, so
//   the document never changes height and nothing under the header moves on
//   its own. Before the hold, the collapse reflowed the whole page every frame:
//   content ran ahead of the finger while collapsing, a flick back to the top
//   pushed the page DOWN for ~10 frames after the scroll had stopped, and near
//   the bottom of a page the browser clamped scrollY back 4px a frame as the
//   document shrank under it. Held, the page scrolls exactly as far as the
//   finger moved it, and only the header itself changes size. A header that
//   is not in flow (fixed or absolute) is left alone: it never moved the page.
//
//   (Held, the short-page guard below is off: the document no longer
//   shortens, so the flap it prevents cannot happen. The per-frame CAP stays
//   on. It was written to stop a flick dragging the page, and the hold already
//   does that; what it buys a held header is the header's own motion. With the
//   cap off, a flick that crossed the ramp in one frame snapped the header
//   from full to compact in one frame, which read as a jerk on the hub's
//   /deployments (2026-10-15). Capped, the header eases over a few frames, and
//   the page under it still holds, because the hold keeps the document's
//   height whatever --nav-p is. Easing open after a flick to the top leaves
//   page background between the header and the content for those frames, the
//   space the header is growing back into.)
//
//   passive + rAF: the listener never blocks the compositor and coalesces a
//   burst of scroll events (iOS momentum fires far above 60Hz) into one write
//   per frame. The write lands on the HEADER, not :root: an inherited custom
//   property written on :root dirties style for the whole document every
//   frame, and it would leak the live page's scroll progress into the preview
//   headers on /navbar.
//
//   the smoothstep (written for an UNHELD header; held, the page does not
//   move, and the smoothstep only shapes how the header itself shrinks):
//   collapsing a sticky, IN-FLOW header pulls the page up,
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
//   held          the header holds its footprint (see the hold above): no
//                 short-page guard; the per-frame cap still eases the header
//
// Answers { p, settling }: the progress to publish, and whether the frame
// clamp left it short of where the scroll position wants it (so the caller
// must schedule another frame).
export function collapseFrame({ y, p, ramp, maxPx, scrollHeight, innerHeight, reduce, held }) {
  // The height the document WOULD have with the navbar expanded. The
  // add-back is the whole trick; see the guard note above.
  var roomExpanded = scrollHeight - innerHeight + ramp * p;

  // WHERE THE COLLAPSE WANTS TO BE, from scroll position alone.
  var target;
  var snap = false;
  if (!held && roomExpanded < ramp + 24) {
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

// THE HOLD, in two parts.
//
// THE LINEAR PART IS CSS. The header carries
//   margin-bottom: calc(base + var(--nav-hold) * var(--nav-p) + var(--nav-hold-fix))
// where --nav-hold is its rest height minus its collapsed height. That margin
// grows in the SAME style recalc that shrinks the header, so the document
// never shortens, not even for one layout. (Setting the margin from script
// after the shrink was the first version of this, and it lost: the shrink's
// own layout shortened the document, and on a short page the browser clamped
// scrollY before the margin came back. Measured: 211 -> 167.)
//
// THE RESIDUE IS SCRIPT. A collapse need not be exactly linear in --nav-p
// (the tallest thing in the row can change mid-ramp), and the scrolled state
// may add a border. holdFix answers what the linear part missed, so the
// footprint is the rest height exactly: rest - (height + hold * p).
export function holdFix({ rest, height, hold, p }) {
  return rest - height - hold * p;
}

// Only a header in the page's flow moves the page as it shrinks.
export function inFlow(position) {
  return position !== 'fixed' && position !== 'absolute';
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

// THE SCROLL-DRIVEN MODE (engine.css, THE SCROLL-DRIVEN COLLAPSE). A header
// carrying data-nav-timeline, from 768px, in a browser with scroll timelines,
// collapses in CSS on the compositor, and this controller stops driving --nav-p.
// What CSS cannot know it is told once, not per frame: the band that scrolls
// away, the scales, and where the header meets the window. The query is the
// stylesheet's own; the two must agree, or both would drive the header.
export var TIMELINE_QUERY = '(min-width: 768px)';

export function timelineSupported() {
  return typeof CSS !== 'undefined' && !!CSS.supports && CSS.supports('animation-timeline: scroll()');
}

export function timelineOn(el, wide) {
  return el.hasAttribute('data-nav-timeline') && wide && timelineSupported();
}

// The timeline's custom properties, from the header measured at both ends of
// the band table (--nav-p 0 and 1). Layout sizes only (offsetHeight and
// offsetWidth), which a transform does not change, so the reading is the same
// at any scroll position.
//
//   rest, collapsed   the header's height expanded and collapsed
//   brand0, brand1    the brand link's height expanded and collapsed
//   brandW            the brand link's width expanded (0: none)
//   avatar0, avatar1  the avatar's height expanded and collapsed (0: none)
//   nameW             the account name's width
//
// The name scales by the avatar's ratio (the rule of 3), and the icon rail
// slides right by what the name and avatar give up, so the gaps stay even.
// Without an avatar (signed out) nothing on the right moves. The brand scales
// from its left edge, but a transform keeps its layout box, so the links beside
// it ([data-nav-links]) slide left by the width it gives up (brandShrink) and
// keep their gap to it.
export function timelineVars({ rest, collapsed, brand0, brand1, brandW, avatar0, avatar1, nameW }) {
  var brandScale = brand0 > 0 ? brand1 / brand0 : 1;
  var avatarScale = avatar0 > 0 ? avatar1 / avatar0 : 1;
  var avatarShrink = avatar0 > 0 ? Math.max(0, avatar0 - avatar1) : 0;
  return {
    band: Math.max(0, rest - collapsed),
    brandScale: brandScale,
    brandShrink: brandW > 0 ? Math.max(0, brandW * (1 - brandScale)) : 0,
    avatarScale: avatarScale,
    avatarShrink: avatarShrink,
    toolsShift: avatar0 > 0 ? nameW * (1 - avatarScale) + avatarShrink : 0
  };
}

var TIMELINE_PROPS = ['--nav-band', '--nav-start', '--nav-brand-scale', '--nav-brand-shrink',
  '--nav-avatar-scale', '--nav-avatar-shrink', '--nav-tools-shift'];

// What the timeline mode leaves on the header. stopTimeline() clears it, and
// so does the --nav-p path's start(): a Turbo snapshot taken wide and restored
// below 768px (a phone rotated, then Back) arrives still carrying it, and
// pinned_stack would subtract the stale band from --nav-h.
export function clearTimeline(el) {
  var was = el.hasAttribute('data-nav-timeline-on');
  TIMELINE_PROPS.forEach(function (name) { el.style.removeProperty(name); });
  el.removeAttribute('data-nav-timeline-on');
  if (was) refreshPinnedStack();
}

// studio/pinned_stack's REFRESH_EVENT. The header's PINNED height (its box
// less the band) and the stack's travel change when timeline mode starts,
// re-measures or stops, and none of that resizes the box, so the stack's
// ResizeObserver cannot hear it. Named here rather than imported so neither
// module has to load the other.
export var PINNED_STACK_REFRESH = 'studio:pinned-stack-refresh';
function refreshPinnedStack() {
  if (typeof document !== 'undefined') document.dispatchEvent(new CustomEvent(PINNED_STACK_REFRESH));
}

function round(n) {
  return Math.round(n * 1000) / 1000;
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
    this._frame = 0;
    this.stopped = false;
    this.tuning = { ramp: DEFAULT_RAMP, maxPx: DEFAULT_MAX_STEP };
    this._reduce = null;
    this._onScroll = this.onScroll.bind(this);
    this._onResize = this.onResize.bind(this);
    this._apply = this.apply.bind(this);
    this.held = false;
    this.rest = 0;
    this.hold = 0;
    this.fix = 0;
    this.lastHeight = null;
    this._observer = null;
    this._remeasure = this.remeasure.bind(this);
    this.timeline = false;
    this._wide = null;
    this._onWide = this.onWide.bind(this);
    this._onTimelineScroll = this.onTimelineScroll.bind(this);
    this._onTimelineResize = this.measureTimeline.bind(this);
    this._bars = null;
  }

  start() {
    this.stopped = false;
    this._wide = window.matchMedia(TIMELINE_QUERY);
    if (this._wide.addEventListener) this._wide.addEventListener('change', this._onWide);
    if (timelineOn(this.el, this._wide.matches)) {
      this.startTimeline();
      return;
    }
    this._reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
    // A HEADER RESTORED FROM TURBO'S SNAPSHOT CACHE arrives as it was left:
    // its scrolled classes on, and this controller's own hold still inline
    // (Turbo copies the page before the old controller disconnects). Read as
    // the header's own, that hold was counted twice on Back: a permanent band
    // under the header, 39-43px on turf-monster's contest page. So the
    // controller clears what it owns before it reads anything.
    this.onScrolled(false);
    clearTimeline(this.el);
    this.el.style.marginBottom = '';
    this.el.style.removeProperty('--nav-hold');
    this.el.style.removeProperty('--nav-hold-fix');
    this.el.style.removeProperty('--nav-p');
    var style = getComputedStyle(this.el);
    this.tuning = readTuning(style);
    this.held = inFlow(style.position);
    if (this.held) {
      var base = parseFloat(style.marginBottom) || 0;
      this.el.style.marginBottom =
        'calc(' + base + 'px + var(--nav-hold, 0px) * var(--nav-p, 0) + var(--nav-hold-fix, 0px))';
      this.measure();
      // The header's height also moves for reasons that are not --nav-p: the
      // scrolled state's bottom border (1px), a webfont landing, a
      // Turbo-streamed badge. The observer re-applies the hold for any of
      // them, in the frame they land. Only a header AT REST (unscrolled,
      // expanded) redefines the rest height, because that is the one state
      // whose height the footprint must equal: scrolled, a change is
      // something the header is doing, not what it rests at.
      if (typeof ResizeObserver === 'function') {
        var self = this;
        this._observer = new ResizeObserver(function () {
          if (self.stopped) return;
          var h = self.el.getBoundingClientRect().height;
          if (self.lastHeight !== null && Math.abs(h - self.lastHeight) <= 0.1) return;
          self.lastHeight = h;
          // At rest the header's height IS its rest height, and a change
          // there is new content: measure both endpoints again.
          if (self.atRest() && Math.abs(h - self.rest) > 0.1) self.measure();
          else self.correct(h);
        });
        this._observer.observe(this.el);
      }
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(this._remeasure);
    }
    this.apply();

    window.addEventListener('scroll', this._onScroll, { passive: true });
    window.addEventListener('resize', this._onResize, { passive: true });
    if (this._reduce.addEventListener) this._reduce.addEventListener('change', this._apply);
  }

  // A Turbo visit tears the header down and builds a new one; without this
  // every visit would stack another listener on window.
  stop() {
    this.stopped = true;
    this.cancelFrame();
    if (this._wide && this._wide.removeEventListener) this._wide.removeEventListener('change', this._onWide);
    this._wide = null;
    if (this.timeline) {
      this.stopTimeline();
      return;
    }
    window.removeEventListener('scroll', this._onScroll);
    window.removeEventListener('resize', this._onResize);
    if (this._observer) this._observer.disconnect();
    this._observer = null;
    if (this.held) {
      this.el.style.marginBottom = '';
      this.el.style.removeProperty('--nav-hold');
      this.el.style.removeProperty('--nav-hold-fix');
    }
    if (this._reduce && this._reduce.removeEventListener) {
      this._reduce.removeEventListener('change', this._apply);
    }
  }

  // A frame the --nav-p path queued (a resize, a scroll, the settle loop)
  // must not land after a stop. Crossing 768px fires this path's resize
  // listener BEFORE the query's change, so the frame is queued, the swap
  // runs, start() clears `stopped`, and the frame then wrote --nav-p onto
  // the timeline header and eased it to 1: a 48px box translated up by the
  // band, above the window (task timeline-header-resize-collapse). Cancel
  // it, and clear `queued` so the next mode can schedule its own.
  cancelFrame() {
    if (this._frame && typeof cancelAnimationFrame === 'function') cancelAnimationFrame(this._frame);
    this._frame = 0;
    this.queued = false;
  }

  // Crossing 768px swaps modes: undo the one running, start the one that
  // now applies.
  onWide() {
    if (this.stopped) return;
    this.stop();
    this.start();
  }

  startTimeline() {
    this.timeline = true;
    this.held = false;
    this.p = 0;
    // A header restored from Turbo's cache, or crossing 768px, can carry
    // what the --nav-p path left inline; it goes.
    this.el.style.marginBottom = '';
    this.el.style.removeProperty('--nav-hold');
    this.el.style.removeProperty('--nav-hold-fix');
    this.el.style.removeProperty('--nav-p');
    this.el.setAttribute('data-nav-timeline-on', '');
    this.scrolled = false;
    this.onScrolled(false);
    this.measureTimeline();
    this.onTimelineScroll();
    window.addEventListener('scroll', this._onTimelineScroll, { passive: true });
    window.addEventListener('resize', this._onTimelineResize, { passive: true });
    var bars = document.querySelector('[data-studio-bar-stack]');
    if (bars && typeof ResizeObserver === 'function') {
      this._bars = new ResizeObserver(this._onTimelineResize);
      this._bars.observe(bars);
    }
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(this._onTimelineResize);
  }

  stopTimeline() {
    this.timeline = false;
    window.removeEventListener('scroll', this._onTimelineScroll);
    window.removeEventListener('resize', this._onTimelineResize);
    if (this._bars) this._bars.disconnect();
    this._bars = null;
    clearTimeline(this.el);
  }

  // Reads the header at both ends of the band table and publishes what the
  // timeline needs. Runs on start, resize, font load and a bar resize; a
  // scroll never calls it. Writes only a value that changed.
  measureTimeline() {
    if (this.stopped || !this.timeline) return;
    var el = this.el;
    var brand = el.querySelector('.nav-logo-link');
    var avatar = el.querySelector('[data-nav-account] > [aria-hidden]');
    var name = el.querySelector('[data-nav-account] > span:first-child');
    var read = function () {
      return {
        h: el.offsetHeight,
        brand: brand ? brand.offsetHeight : 0,
        brandW: brand ? brand.offsetWidth : 0,
        avatar: avatar ? avatar.offsetHeight : 0
      };
    };
    el.style.removeProperty('--nav-p');
    var open = read();
    el.style.setProperty('--nav-p', '1');
    var shut = read();
    el.style.removeProperty('--nav-p');
    var vars = timelineVars({
      rest: open.h, collapsed: shut.h,
      brand0: open.brand, brand1: shut.brand, brandW: open.brandW,
      avatar0: open.avatar, avatar1: shut.avatar,
      nameW: name ? name.offsetWidth : 0
    });
    // Where the header meets the top of the window: the bars above it in flow.
    var bars = document.querySelector('[data-studio-bar-stack]');
    var start = bars && (bars.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING)
      ? bars.offsetHeight : 0;
    var props = {
      '--nav-band': round(vars.band) + 'px',
      '--nav-start': start + 'px',
      '--nav-brand-scale': String(round(vars.brandScale)),
      '--nav-brand-shrink': round(vars.brandShrink) + 'px',
      '--nav-avatar-scale': String(round(vars.avatarScale)),
      '--nav-avatar-shrink': round(vars.avatarShrink) + 'px',
      '--nav-tools-shift': round(vars.toolsShift) + 'px'
    };
    var changed = false;
    for (var key in props) {
      if (el.style.getPropertyValue(key) !== props[key]) { el.style.setProperty(key, props[key]); changed = true; }
    }
    if (changed) refreshPinnedStack();
  }

  // The scrolled marker on the controller's own hysteresis, written only when
  // it flips. No frame is scheduled: the collapse itself is the stylesheet's.
  onTimelineScroll() {
    if (this.stopped || !this.timeline) return;
    var lit = shadowLit(this.scrolled, Math.max(0, window.scrollY));
    if (lit !== this.scrolled) {
      this.scrolled = lit;
      this.onScrolled(lit);
    }
  }

  onScroll() {
    if (this.queued) return;
    this.queued = true;
    this._frame = requestAnimationFrame(this._apply);
  }

  onResize() {
    this.tuning = readTuning(getComputedStyle(this.el));
    if (this.held) this.measure();
    this.onScroll();
  }

  atRest() {
    return this.p === 0 && window.scrollY <= 0;
  }

  // The header's height at a given --nav-p, read by putting it there for the
  // length of one synchronous layout. Nothing paints in between, so the
  // reader never sees it. The margin is pinned to the rest height while it
  // reads, so the document only ever GROWS during the read: growing cannot
  // clamp the scroll position, shrinking can.
  heightAt(p) {
    var style = this.el.style;
    var was = style.getPropertyValue('--nav-p');
    style.setProperty('--nav-p', String(p));
    var h = this.el.getBoundingClientRect().height;
    if (was) style.setProperty('--nav-p', was); else style.removeProperty('--nav-p');
    return h;
  }

  // Both endpoints, then the linear hold between them and the residue at the
  // current progress. Both are read UNSCROLLED: the rest height is the
  // header's height at the top of the page, where the scrolled state (and any
  // border it carries) is off. The residue absorbs that state while it is on.
  measure() {
    var style = this.el.style;
    var lit = this.scrolled;
    if (lit) this.onScrolled(false);
    style.setProperty('--nav-hold-fix', '0px');
    this.fix = 0;
    style.setProperty('--nav-hold', '0px');
    var pinned = style.marginBottom;
    style.marginBottom = '0px';
    var rest = this.heightAt(0);
    style.marginBottom = rest + 'px';
    var collapsed = this.heightAt(1);
    style.marginBottom = pinned;
    if (lit) this.onScrolled(true);
    this.rest = rest;
    this.hold = Math.max(0, rest - collapsed);
    style.setProperty('--nav-hold', this.hold + 'px');
    this.correct(this.el.getBoundingClientRect().height);
  }

  remeasure() {
    if (this.stopped || !this.held) return;
    this.measure();
  }

  // Write the residue the linear hold missed, when it moved by more than a
  // rounding error. The observer calls this in the frame the height changed,
  // before paint.
  correct(height) {
    this.lastHeight = height;
    var fix = holdFix({ rest: this.rest, height: height, hold: this.hold, p: this.p });
    if (Math.abs(fix - this.fix) > 0.1) {
      this.fix = fix;
      this.el.style.setProperty('--nav-hold-fix', fix.toFixed(2) + 'px');
    }
  }

  apply() {
    this.queued = false;
    this._frame = 0;
    // Timeline mode owns the header: --nav-p is the stylesheet's there, and
    // this path writes nothing, whatever frame is still in flight.
    if (this.stopped || this.timeline) return;
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
      reduce: this._reduce.matches,
      held: this.held
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
      this._frame = requestAnimationFrame(this._apply);
    }

    var lit = shadowLit(this.scrolled, y);
    if (lit !== this.scrolled) {
      this.scrolled = lit;
      this.onScrolled(lit);
    }
  }
}
