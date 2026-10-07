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

var started = false

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
  function readPins() {
    var header = document.querySelector('header');
    var nodes = document.querySelectorAll('[data-pin]');
    var list = [];
    var headerPinned = false;
    for (var i = 0; i < nodes.length; i++) {
      var name = nodes[i].getAttribute('data-pin');
      // An unnamed pin would write `--pin--h`, a valid property name and a
      // silent nonsense one. Skip it rather than publish it.
      if (!name) continue;
      if (nodes[i] === header) headerPinned = true;
      list.push(measure(nodes[i], name, nodes[i] === header));
    }
    // THE HOST-OWNED HEADER, and the back-compat promise that depends on it.
    // A header that does not carry [data-pin] is not in the registry, so the
    // legacy --nav-h / --nav-bottom — which studio/_sidebar_panel, turf's
    // contest board and mcritchie-studio's heartbeat CSS all read — would
    // never publish at all. Both live consumers own their header, so it is
    // adopted as a pin even when it does not ask to be.
    if (header && !headerPinned) list.push(measure(header, 'nav', true));
    return list;
  }

  // ONE READ PER ELEMENT PER PUBLISH, and every read before every write.
  // A read after a write to the root forces a fresh layout, which is the
  // thrash this publisher exists without. Measured by review at 6x CPU
  // throttle over 175 frames: frames past 20ms 62 vs 42, median 17.7 vs
  // 14.9ms, p90 34.2 vs 26.0ms; at 10x, 84/180 vs 4/180.
  function measure(el, name, legacy) {
    // A hidden layer needs no special case: display:none gives offsetHeight 0
    // and an all-zero rect, so it measures 0 and drops out of the stack on its
    // own. That is what lets a layer come and go without anyone declaring a
    // stacking order, and it is load-bearing rather than incidental.
    var r = el.getBoundingClientRect();
    return { el: el, name: name, legacy: legacy, h: el.offsetHeight, bottom: Math.max(0, r.bottom) };
  }


  function write(pins, stack) {
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
    var pins = readPins();
    write(pins, composed(pins));
    syncObserver(pins);
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
  // A Turbo Stream replaces nodes WITHOUT a turbo:load. The registry is derived
  // per publish, so a stale reference is no longer possible either way — but the
  // OBSERVER still has to be moved onto the incoming node, and the stack has to
  // be recomposed for a layer that arrived or left. Both happen in publishAll.
  document.addEventListener('turbo:before-stream-render', function () {
    window.requestAnimationFrame(invalidate);
  });
  // Registered ONCE at start, not inside a re-scan, so a Turbo nav
  // re-publishes instead of stacking another listener per visit.
  window.addEventListener('scroll', schedule, { passive: true });
  window.addEventListener('resize', schedule, { passive: true });

  // A deferred module runs after the body is parsed, so the layers are already
  // there: publish now rather than wait for DOMContentLoaded, which also
  // covers a host that imports this after that event has fired.
  invalidate();
}
