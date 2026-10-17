// studio/pinned_stack: THE PINNED STACK. Publishes the live geometry of every layer
// of pinned page chrome as CSS custom properties, so anything fixed or sticky
// positions off it in CSS with no hardcoded px and no JS of its own.
//
// A layer joins by carrying `data-pin="<name>"`. Nothing else is required:
// no registration call, no declared stacking order, no consumer edit.
//
// WHAT A CONSUMER READS — prefer the first two; they are the reason this is a
// primitive rather than an arithmetic helper:
//
//   --pin-stack-bottom  the bottom of the WHOLE stack. What something sitting
//                       BENEATH all the pinned chrome positions off.
//   --pin-<name>-top    the bottom of everything ABOVE that layer. What a layer
//                       that is ITSELF in the stack positions off.
//   --pin-<name>-h      that layer's HEIGHT.
//   --pin-<name>-bottom that layer's own BOTTOM EDGE, in viewport coordinates.
//   --nav-h / --nav-bottom  the <header>'s height and bottom edge, under their
//                       legacy names, from the same measurement.
//
// DO NOT COMPOSE THE STACK IN A CONSUMER. `top: max(var(--pin-nav-bottom),
// var(--pin-apps-bottom))` is what this replaced, and it fails twice: it does
// not scale, because a fourth layer means editing every consumer that ever
// wanted to sit under the stack; and it is not sound, because a max() over two
// custom properties is only meaningful if they were written in the same frame.
// --pin-stack-bottom is one value that cannot disagree with itself.
//
// --nav-h AND --nav-bottom ARE NOT THE SAME NUMBER. They are equal only when
// the header sits at the top of the viewport, which is why one was long
// mistaken for the other. An app that stacks chrome ABOVE the header — an
// environment banner rendered before the navbar, as mcritchie-industries does —
// pushes the header down, and a `fixed` overlay positioned at --nav-h then
// rides UP over the header by exactly the height of that chrome. Use --nav-h to
// SIZE something as tall as the header; use --nav-bottom to START something
// underneath it. Same distinction for --pin-<name>-h vs --pin-<name>-bottom.
//
// Started once per document by studio/application. The listeners it adds live
// for the document, and a Turbo visit republishes through them rather than
// starting it again.

// THE STACK, COMPOSED HERE RATHER THAN BY EVERY CONSUMER.
//
// Consumers used to write `top: max(var(--pin-nav-bottom), var(--pin-apps-bottom))`
// — every layer enumerated, in every consumer. That is two failures at once.
// It does not SCALE: a fourth pinned layer means editing every consumer that
// ever wanted to sit under the stack. And it is not SOUND: max() over two
// independently-written custom properties is only meaningful if they were
// written in the same frame, and any skew between them is expressed instantly
// as layout. Composing here means a consumer reads ONE value that cannot
// disagree with itself.
//
//   --pin-stack-bottom  the bottom of the WHOLE pinned stack. What something
//                       sitting beneath all the chrome positions off.
//   --pin-<name>-top    the bottom of everything ABOVE that layer. What a
//                       layer that is ITSELF in the stack positions off —
//                       --pin-stack-bottom would include the layer's own
//                       edge, so a layer positioned off it would chase itself
//                       down the page.
//
// ORDER is document order, which is the order the layers were declared and
// therefore the order they read in. `data-pin-order` overrides it for a layer
// whose DOM position does not match where it sits on screen; it is a plain
// number, lower is higher up, and it needs to exist on only the layer that
// disagrees rather than on all of them.
export function order(p) {
  var raw = parseFloat(p.el.getAttribute('data-pin-order'));
  return isNaN(raw) ? null : raw;
}
export function composed(pins) {
  var i, j, stack = 0;
  for (i = 0; i < pins.length; i++) {
    if (pins[i].bottom > stack) stack = pins[i].bottom;
    var above = 0;
    for (j = 0; j < pins.length; j++) {
      if (i === j) continue;
      var oi = order(pins[i]), oj = order(pins[j]);
      // Both ordered: compare the numbers. Otherwise fall back to document
      // order, which querySelectorAll already returns them in.
      var jIsAbove = (oi !== null && oj !== null) ? oj < oi : j < i;
      if (jIsAbove && pins[j].bottom > above) above = pins[j].bottom;
    }
    pins[i].top = above;
  }
  return stack;
}

// THE STACK ON A SCROLL-TIMELINE HEADER (studio/nav_collapse's timeline mode,
// data-nav-timeline-on). That header keeps its expanded box and is sticky at
// minus its band, so what pins is the compact bar, and its height never changes
// while the page scrolls. Every layer of the stack is chrome that pins at the
// bottom of the layers above it, so on such a page the stack is a fact of
// HEIGHTS, not of where the window happens to be: each visible layer sits at
// its composed top and ends one height below it. That is where a sticky reader
// (a board's lane headers) lands the moment it pins, and it does not move per
// scroll frame, so nothing is written per scroll frame either: the publisher
// writes on resize and on a roster change, and the follower path goes unused.
//
// A hidden layer (height 0) still drops out at 0. Settles in one pass per
// layer of depth; bounded by the layer count so a contradictory data-pin-order
// cannot spin.
export function pinnedAt(pins) {
  var i, pass, stack = 0;
  for (i = 0; i < pins.length; i++) pins[i].bottom = 0;
  for (pass = 0; pass <= pins.length; pass++) {
    stack = composed(pins);
    var moved = false;
    for (i = 0; i < pins.length; i++) {
      var bottom = pins[i].h > 0 ? pins[i].top + pins[i].h : 0;
      if (bottom !== pins[i].bottom) { pins[i].bottom = bottom; moved = true; }
    }
    if (!moved) break;
  }
  return stack;
}

export function onTimeline(header) {
  return !!header && header.hasAttribute('data-nav-timeline-on');
}

// ONE READ PER ELEMENT PER PUBLISH, and every read before every write.
// A read after a write to the root forces a fresh layout, which is the
// thrash this publisher exists without. Measured by review at 6x CPU
// throttle over 175 frames: frames past 20ms 62 vs 42, median 17.7 vs
// 14.9ms, p90 34.2 vs 26.0ms; at 10x, 84/180 vs 4/180.
export function measurePin(el, name, legacy, timeline) {
  // A header on the scroll timeline keeps its expanded box, and its top band
  // scrolls away above the window; what pins is the compact bar, so that is
  // its height here. An inline read, no layout.
  var band = el.hasAttribute('data-nav-timeline-on') ? parseFloat(el.style.getPropertyValue('--nav-band')) || 0 : 0;
  var h = el.offsetHeight - band;
  // On the timeline the bottom comes from the heights (pinnedAt), so the rect
  // is not read at all.
  if (timeline) return { el: el, name: name, legacy: legacy, h: h, bottom: 0 };
  // A hidden layer needs no special case: display:none gives offsetHeight 0
  // and an all-zero rect, so it measures 0 and drops out of the stack on its
  // own. That is what lets a layer come and go without anyone declaring a
  // stacking order, and it is load-bearing rather than incidental.
  var r = el.getBoundingClientRect();
  return { el: el, name: name, legacy: legacy, h: h, bottom: Math.max(0, r.bottom) };
}

// THE REGISTRY IS DERIVED, NEVER CACHED — and that is a correctness rule.
//
// This used to build a `pins` array once and hold each element by reference
// until something re-registered it. A Turbo Stream replaces a pinned layer's
// node WITHOUT a turbo:load, so between the patch and the re-scan the held
// reference pointed at the DETACHED predecessor — and a detached node's rect
// is all zeros, which is indistinguishable from a layer that is legitimately
// hidden. Measured on mcritchie-studio's /deployments: --pin-apps-bottom
// published 0px while the live strip stood at display:block, bottom 152px,
// and the board's lane headers slammed 99px up and back on every broadcast.
//
// Re-querying costs one querySelectorAll over a handful of nodes per publish.
// That is cheaper than the class of bug it removes, because it makes a stale
// reference IMPOSSIBLE rather than merely unlikely: there is no window between
// a DOM patch and a re-scan in which this can be pointed at the wrong node.
//
// Returns { pins, stack, timeline }: every layer measured and composed, the
// stack's bottom, and whether the header is on the scroll timeline.
export function readStack() {
  var header = document.querySelector('header');
  var timeline = onTimeline(header);
  var nodes = document.querySelectorAll('[data-pin]');
  var list = [];
  var headerPinned = false;
  for (var i = 0; i < nodes.length; i++) {
    var name = nodes[i].getAttribute('data-pin');
    // An unnamed pin would write `--pin--h`, a valid property name and a
    // silent nonsense one. Skip it rather than publish it.
    if (!name) continue;
    if (nodes[i] === header) headerPinned = true;
    list.push(measurePin(nodes[i], name, nodes[i] === header, timeline));
  }
  // THE HOST-OWNED HEADER, and the back-compat promise that depends on it.
  // A header that does not carry [data-pin] is not in the registry, so the
  // legacy --nav-h / --nav-bottom — which studio/_sidebar_panel, turf's
  // contest board and mcritchie-studio's heartbeat CSS all read — would
  // never publish at all. Both live consumers own their header, so it is
  // adopted as a pin even when it does not ask to be.
  if (header && !headerPinned) list.push(measurePin(header, 'nav', true, timeline));
  return {
    pins: list,
    stack: timeline ? pinnedAt(list) : composed(list),
    timeline: timeline,
    travel: timeline ? timelineTravel(header) : 0
  };
}

// HOW FAR THE PAGE SCROLLS BEFORE THE TIMELINE HEADER PINS: the bars above it
// in flow (--nav-start) plus the band that scrolls away (--nav-band), both
// written inline by studio/nav_collapse. Inline reads, no layout. A FIXED
// reader (data-pin-edge) starts this far below the stack's bottom at the top
// of the page and closes the gap on the scroll timeline, in CSS (engine.css,
// THE PINNED EDGE ON THE SCROLL TIMELINE).
export function timelineTravel(header) {
  var px = function (name) { return parseFloat(header.style.getPropertyValue(name)) || 0; };
  return Math.max(0, px('--nav-start') + px('--nav-band'));
}

// THE LIVE READ, for SCRIPT readers. The custom properties are for CSS; a
// script that reads --pin-stack-bottom off documentElement can be up to
// SETTLE_MS late, because in motion the publisher writes only the elements
// that read the stack in CSS and writes the root once the scroll settles.
// Cyvasse's phone dock read the root mid-scroll and sat 30px off. This
// measures on call, from the same reading the publisher would make now, so it
// is never stale and never writes anything.
//
//   import { stackBottom } from "studio/pinned_stack"
//   window.studioPinnedStack.bottom()   // the same, for a script with no import
//   window.studioPinnedStack.read()     // { bottom, timeline, layers: { nav: { h, top, bottom } } }
export function stackBottom() {
  return readStack().stack;
}

export function stackReading() {
  var r = readStack();
  var layers = {};
  for (var i = 0; i < r.pins.length; i++) {
    layers[r.pins[i].name] = { h: r.pins[i].h, top: r.pins[i].top, bottom: r.pins[i].bottom };
  }
  return { bottom: r.stack, timeline: r.timeline, travel: r.travel, layers: layers };
}

if (typeof window !== 'undefined') {
  window.studioPinnedStack = { bottom: stackBottom, read: stackReading };
}

// What studio/nav_collapse fires on the document when its timeline mode
// starts, re-measures its band, or stops: the header's pinned height changed
// without its box resizing, which the ResizeObserver cannot see.
export var REFRESH_EVENT = 'studio:pinned-stack-refresh';

var started = false

// THE READERS OF THE STACK, found rather than declared.
//
// Every value this publisher writes is an inherited custom property on
// documentElement, so every write restyles the WHOLE document, whether or not
// an element reads it. On a scroll frame that is the hot path: the header's
// bottom edge moves every frame while an ambient bar scrolls away and while
// the navbar collapses. Measured on turf-monster's contest page (about 2,000
// elements): one root write cost 8.7ms of style recalc against 0.2ms for the
// same write on the header, and the collapse dropped every second or third
// frame on a 120Hz screen. The hub's 478-element /links paid 1ms.
//
// Only a handful of elements read these values. So while a scroll is in
// motion the publisher writes them onto those elements alone, and writes the
// root once the scroll settles. A reader is any element that
//   · carries [data-pin-follow], the explicit opt-in;
//   · uses one in its inline style (studio/_sidebar_panel does); or
//   · matches a stylesheet rule that uses one (scanned once per document).
// The document's root and body are never followers: a rule there (a custom
// property derived from --nav-h on :root) is served by the settled write.
//
// A reader follows LIVE only when it uses a value for something that paints.
// scroll-margin and scroll-padding matter only at the moment of an anchor
// jump, and the settled root serves them: turf-monster's contest board carries
// `scroll-margin-top: var(--nav-h)` on a 1,200-element subtree, and following
// it live cost the whole page's restyle back.
export var READS_THE_STACK = /var\(\s*--(pin-|nav-bottom|nav-h\b)/;

export function readsLive(cssText) {
  var decls = String(cssText || '').split(';');
  for (var i = 0; i < decls.length; i++) {
    var at = decls[i].indexOf(':');
    if (at < 0) continue;
    var name = decls[i].slice(0, at).trim().toLowerCase();
    if (/^scroll-(margin|padding)/.test(name)) continue;
    if (READS_THE_STACK.test(decls[i].slice(at + 1))) return true;
  }
  return false;
}

export function followerSelectors(sheets) {
  var found = ['[data-pin-follow]', '[style*="var(--pin-"]', '[style*="var(--nav-bottom"]', '[style*="var(--nav-h"]'];
  function walk(rules) {
    for (var i = 0; rules && i < rules.length; i++) {
      var rule = rules[i];
      if (rule.selectorText && rule.style && readsLive(rule.style.cssText)) {
        var parts = rule.selectorText.split(',');
        for (var j = 0; j < parts.length; j++) {
          var sel = parts[j].trim();
          if (sel && found.indexOf(sel) === -1) found.push(sel);
        }
      }
      if (rule.cssRules) walk(rule.cssRules);
    }
  }
  for (var k = 0; k < sheets.length; k++) {
    var rules = null;
    // A cross-origin sheet refuses cssRules; it cannot hold this app's readers.
    try { rules = sheets[k].cssRules; } catch (e) { rules = null; }
    walk(rules);
  }
  return found;
}

export function startPinnedStack() {
  if (started || !window.ResizeObserver) return;
  started = true;
  var ro = null;
  var queued = false;
  // WHAT WAS LAST PUBLISHED, per layer name: { h, bottom, top }. It does two
  // jobs. It is the record of which names this publisher has written, so a
  // DEPARTED layer can be cleared. And it is what lets an UNCHANGED value skip
  // its write — these are INHERITED custom properties on documentElement, so
  // even a write of the same number invalidates style for the whole document,
  // and a scroll frame touches this four times per layer.
  var last = {};
  var lastStack = null;
  // SKIPPING AN UNCHANGED WRITE IS ONLY SAFE WHILE NOTHING ELSE TOUCHES THESE
  // PROPERTIES. On a scroll frame that holds, and skipping is most of why this
  // is cheap. On a STRUCTURAL change it does not: a layer arriving or leaving,
  // a Turbo patch, a fresh document — anything there may have cleared a
  // property out from under the cache, and a skip would then never write it
  // again. So a structural change forces a full write, once.
  var forceWrite = true;
  // The nodes currently under observation, held only to know what to unobserve
  // when one departs. The REGISTRY ITSELF is never cached; see readPins().
  var observed = [];

  // THE MOTION WRITE (see READS_THE_STACK above). lastScrollAt marks the
  // gesture; within SETTLE_MS of it a publish writes the followers, and a
  // timer writes the root once the scroll has been still that long.
  var SETTLE_MS = 160;
  var lastScrollAt = -Infinity;
  var settleTimer = null;
  var selectors = null;
  // The scan is redone when the document's stylesheets change (a Turbo visit
  // into a page with its own), keyed on their hrefs and count.
  var scannedSheets = null;
  var followed = [];
  var followedProps = [];

  function followers() {
    var key = [].map.call(document.styleSheets, function (sheet) { return sheet.href || 'inline'; }).join('|');
    if (!selectors || key !== scannedSheets) {
      selectors = followerSelectors(document.styleSheets);
      scannedSheets = key;
    }
    var out = [];
    for (var i = 0; i < selectors.length; i++) {
      var nodes;
      // A selector the scan lifted may not be queryable (a pseudo-element).
      try { nodes = document.querySelectorAll(selectors[i]); } catch (e) { continue; }
      for (var j = 0; j < nodes.length; j++) {
        var n = nodes[j];
        if (n === document.documentElement || n === document.body || n === document.head) continue;
        // The inline matches are substring guesses; the declarations decide.
        if (selectors[i].charAt(0) === '[' && selectors[i] !== '[data-pin-follow]' && !readsLive(n.getAttribute('style'))) continue;
        if (out.indexOf(n) === -1) out.push(n);
      }
    }
    return out;
  }

  function writeFollowers(props) {
    var targets = followers();
    // An element that stopped reading the stack (or left the page) gives its
    // copies back, so it inherits the root again.
    for (var f = 0; f < followed.length; f++) {
      if (targets.indexOf(followed[f]) !== -1) continue;
      for (var g = 0; g < followedProps.length; g++) followed[f].style.removeProperty(followedProps[g][0]);
    }
    for (var i = 0; i < targets.length; i++) {
      for (var k = 0; k < props.length; k++) {
        if (targets[i].style.getPropertyValue(props[k][0]) !== props[k][1]) targets[i].style.setProperty(props[k][0], props[k][1]);
      }
    }
    followed = targets;
    followedProps = props;
  }

  // Once the root holds the settled values, the followers inherit them again.
  function releaseFollowers() {
    for (var i = 0; i < followed.length; i++) {
      for (var k = 0; k < followedProps.length; k++) followed[i].style.removeProperty(followedProps[k][0]);
    }
    followed = [];
    followedProps = [];
  }

  function settle() {
    settleTimer = null;
    publishAll();
    releaseFollowers();
  }

  // The registry and the measurement are module-level (readStack, measurePin
  // above) so the live read and the publisher make the same reading.

  var lastTravel = null;
  function write(pins, stack, timeline, travel) {
    var style = document.documentElement.style;
    var seen = {};
    var i, p, prev;
    // A ROSTER CHANGE IS STRUCTURAL TOO, and it is not always announced by an
    // event: an x-show that adds the node, a layer rendered by something other
    // than a stream. Compare the names against what was published last.
    var force = forceWrite;
    forceWrite = false;
    if (!force) {
      for (i = 0; i < pins.length; i++) { if (!last.hasOwnProperty(pins[i].name)) { force = true; break; } }
    }

    // ON THE SCROLL TIMELINE the stack does not move with the scroll (see
    // pinnedAt), so a scroll frame finds nothing changed and the root path
    // below writes nothing. The follower path is for values that DO move per
    // frame; it goes unused here, and any copies a --nav-p frame left go back.
    if (timeline) {
      if (settleTimer) { clearTimeout(settleTimer); settleTimer = null; }
      if (followed.length) releaseFollowers();
    }
    // The fixed readers' scroll-timeline path (data-pin-edge, engine.css) is
    // switched on by this attribute and sized by --pin-stack-travel. Both are
    // written only when they change: on a resize or a mode swap.
    var root = document.documentElement;
    if (timeline) {
      if (force || travel !== lastTravel) { style.setProperty('--pin-stack-travel', travel + 'px'); lastTravel = travel; }
      if (!root.hasAttribute('data-pin-timeline')) root.setAttribute('data-pin-timeline', '');
    } else if (lastTravel !== null || root.hasAttribute('data-pin-timeline')) {
      style.removeProperty('--pin-stack-travel');
      root.removeAttribute('data-pin-timeline');
      lastTravel = null;
    }

    // IN MOTION, THE FOLLOWERS ONLY. A structural change still writes the
    // root at once: it is rare, and a layer arriving must reach every reader.
    if (!force && !timeline && performance.now() - lastScrollAt < SETTLE_MS) {
      var props = [];
      for (i = 0; i < pins.length; i++) {
        p = pins[i];
        props.push(['--pin-' + p.name + '-h', p.h + 'px'], ['--pin-' + p.name + '-bottom', p.bottom + 'px'], ['--pin-' + p.name + '-top', p.top + 'px']);
        if (p.legacy) props.push(['--nav-h', p.h + 'px'], ['--nav-bottom', p.bottom + 'px']);
      }
      props.push(['--pin-stack-bottom', stack + 'px']);
      writeFollowers(props);
      if (settleTimer) clearTimeout(settleTimer);
      settleTimer = setTimeout(settle, SETTLE_MS);
      return;
    }
    for (i = 0; i < pins.length; i++) {
      p = pins[i];
      seen[p.name] = true;
      prev = last[p.name] || {};
      if (force || p.h !== prev.h) {
        style.setProperty('--pin-' + p.name + '-h', p.h + 'px');
        if (p.legacy) style.setProperty('--nav-h', p.h + 'px');
      }
      if (force || p.bottom !== prev.bottom) {
        style.setProperty('--pin-' + p.name + '-bottom', p.bottom + 'px');
        if (p.legacy) style.setProperty('--nav-bottom', p.bottom + 'px');
      }
      if (force || p.top !== prev.top) style.setProperty('--pin-' + p.name + '-top', p.top + 'px');
      last[p.name] = { h: p.h, bottom: p.bottom, top: p.top };
    }
    if (force || stack !== lastStack) {
      style.setProperty('--pin-stack-bottom', stack + 'px');
      lastStack = stack;
    }

    // CLEAR WHAT LEFT. A layer goes away three ways: display:none and x-show
    // both keep the node, so it measures 0 and drops out of the stack on its
    // own. REMOVAL does not — nothing is left to measure, and without this the
    // last published value stands forever while the consumer sits at the height
    // of a strip that is gone. Review measured a removed 300px strip holding
    // --pin-apps-bottom at 300px against a real stack bottom of 160px.
    for (var name in last) {
      if (last.hasOwnProperty(name) && !seen[name]) {
        style.removeProperty('--pin-' + name + '-h');
        style.removeProperty('--pin-' + name + '-bottom');
        style.removeProperty('--pin-' + name + '-top');
        delete last[name];
      }
    }
  }

  function publishAll() {
    var reading = readStack();
    write(reading.pins, reading.stack, reading.timeline, reading.travel);
    syncObserver(reading.pins);
  }

  // Observe whatever is pinned RIGHT NOW. observe() on an already-observed node
  // is a no-op, so this only ever adds the new; unobserve() drops the departed
  // so a replaced node cannot keep waking us from outside the document.
  function syncObserver(pins) {
    if (!pins.length) {
      if (ro) { ro.disconnect(); ro = null; observed = []; }
      return;
    }
    if (!ro) ro = new ResizeObserver(onResize);
    var i, next = [];
    for (i = 0; i < pins.length; i++) { next.push(pins[i].el); ro.observe(pins[i].el); }
    for (i = 0; i < observed.length; i++) {
      if (next.indexOf(observed[i]) === -1) ro.unobserve(observed[i]);
    }
    observed = next;
  }

  // PUBLISH IN THE ResizeObserver CALLBACK, SYNCHRONOUSLY. This is the whole
  // fix, and it is a statement about WHEN a frame does its work rather than
  // about what this code computes.
  //
  // A frame runs: rAF callbacks -> style/layout -> ResizeObserver callbacks ->
  // paint. This publisher used to be woken by the observer and then DEFER the
  // write to requestAnimationFrame, which lands at the top of the NEXT frame —
  // so the frame in which a layer actually appeared or disappeared painted with
  // the previous frame's number, every time. The RO callback runs after layout
  // and before paint, which is exactly the last moment a write can still land
  // in the frame that caused it.
  //
  // A/B measured in isolation, toggling a pinned layer's display and sampling
  // what the changing frame paints: rAF-deferred wrong on 8/8 changing frames,
  // RO-synchronous wrong on 0/8.
  //
  // This cannot loop. The values written here move CONSUMERS, and a consumer is
  // not a pin — nothing this writes resizes anything it observes. A pinned layer
  // that positions off --pin-<name>-top MOVES without RESIZING, and the observer
  // fires on size, so it settles in one pass rather than ringing.
  // The one way a SYNCHRONOUS publish could misbehave: a consumer that both
  // reads a published value and is itself a pin, sized off what it reads
  // (`height: calc(100vh - var(--pin-apps-top))`). That resizes an observed
  // node from inside the observer's own callback, and left alone the browser
  // reports "ResizeObserver loop completed with undelivered notifications" and
  // drops the frame. So re-entry is counted, and past a couple of settling
  // passes this hands the rest to the frame callback: the pathological page
  // degrades to the OLD one-frame-late behaviour instead of wedging, and the
  // ordinary page never reaches the branch. Reset on the next frame, so the
  // count measures one frame's settling rather than the session's.
  var depth = 0, resetQueued = false;
  function onResize() {
    if (depth >= 3) { schedule(); return; }
    depth++;
    if (!resetQueued) {
      resetQueued = true;
      window.requestAnimationFrame(function () { resetQueued = false; depth = 0; });
    }
    publishAll();
  }

  // SCROLL STILL NEEDS THE FRAME CALLBACK. A scroll changes a sticky header's
  // bottom EDGE without changing its size, so the observer never sees it and
  // there is nothing to be synchronous with — rAF is the right clock, and it
  // coalesces the burst iOS momentum fires far above 60Hz.
  function schedule() {
    if (queued) return;
    queued = true;
    window.requestAnimationFrame(function () { queued = false; publishAll(); });
  }

  function invalidate() { forceWrite = true; publishAll(); }
  document.addEventListener('DOMContentLoaded', invalidate);
  document.addEventListener('turbo:load', invalidate);
  // Turbo copies the page into its snapshot cache before it leaves: give the
  // followers' copies back first, so a restored page carries none of them.
  document.addEventListener('turbo:before-cache', function () {
    if (settleTimer) { clearTimeout(settleTimer); settleTimer = null; }
    releaseFollowers();
  });
  // A Turbo Stream replaces nodes WITHOUT a turbo:load. The registry is derived
  // per publish, so a stale reference is no longer possible either way — but the
  // OBSERVER still has to be moved onto the incoming node, and the stack has to
  // be recomposed for a layer that arrived or left. Both happen in publishAll.
  document.addEventListener('turbo:before-stream-render', function () {
    window.requestAnimationFrame(invalidate);
  });
  // The timeline header's pinned height moves when its band is measured,
  // which changes no box size, so the observer never hears of it.
  document.addEventListener(REFRESH_EVENT, publishAll);
  // Registered ONCE at start, not inside a re-scan, so a Turbo nav
  // re-publishes instead of stacking another listener per visit.
  window.addEventListener('scroll', schedule, { passive: true });
  // The gesture's clock for the motion write (see READS_THE_STACK).
  window.addEventListener('scroll', function () { lastScrollAt = performance.now(); }, { passive: true });
  window.addEventListener('resize', schedule, { passive: true });

  // A deferred module runs after the body is parsed, so the layers are already
  // there: publish now rather than wait for DOMContentLoaded, which also
  // covers a host that imports this after that event has fired.
  invalidate();
}
