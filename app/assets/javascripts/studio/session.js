// studio/session.js — the browser half of the session-drift primitive.
// docs/SESSION_DRIFT.md is the contract; this header is the map.
//
// WHAT IT DOES. Every page rendered by a Studio::ErrorHandling controller carries
// a stamp in <meta name="studio-session">: the session's state, its fingerprint,
// when it was issued and when it lapses, where to rehydrate it, and the
// identities the host bound it to. This store reads that stamp and keeps asking
// one question: does this page still describe the browser's session?
//
// THE STATES (SessionContext::STATES on the server):
//   anonymous      nobody is signed in. First-class, not an error.
//   authenticated  somebody is signed in and the page still describes them.
//   stale          the page learned its stamp is out of date; a rehydrate is due.
//   changed        an identity source observes someone other than the bound identity.
//   rehydrated     the page pulled the server's session in place and is signed in.
//   signed_out     the page was signed in and the server now reports nobody.
//
// WHERE DRIFT COMES FROM. Identity sources. The engine ships three web2 sources
// (together the "session" scope) and a plug-in interface for everything else:
//   peer    — other tabs announce their fingerprint on a BroadcastChannel; a
//             newer, different one makes this page stale.
//   expiry  — a timer at the stamp's expiresAt.
//   server  — returning to a tab after it was hidden (and a bfcache restore)
//             probes the rehydrate endpoint; a 401 reads as revoked.
//   plug-ins — registerIdentitySource({ name, start(report) }) reports the
//             identity it observes; the store compares it to the stamp's
//             identities[name]. The engine never interprets either string.
//
// WHAT IT PUBLISHES. window.StudioSession (below), the document events
// `session:changed` (every transition) and `session:mismatch` (undeclared drift
// only, the one a warning listens to), and Alpine.store('studioSession') when
// Alpine is on the page. It never touches a host's own stores.
//
// DORMANT WITHOUT A STAMP. A page with no meta tag (the partial did not render,
// or rendered nothing) leaves current().state null, fetches nothing and
// broadcasts nothing, until a Turbo navigation brings a stamp in.
//
// Written as ES5 with Promises and no framework, like the other engine assets,
// so every host's asset pipeline accepts it untouched.
(function () {
  "use strict";

  if (typeof window === "undefined" || typeof document === "undefined") return;
  if (window.StudioSession && window.StudioSession.loaded) return;

  var STATES = ["anonymous", "authenticated", "stale", "changed", "rehydrated", "signed_out"];
  var SESSION_SCOPE = "session";
  var BUILT_IN_SOURCES = ["peer", "expiry", "server"];
  var RESERVED_NAMES = BUILT_IN_SOURCES.concat([SESSION_SCOPE, "*"]);
  var SOURCE_NAME = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;
  var META_SELECTOR = 'meta[name="studio-session"]';
  var CHANNEL_NAME = "studio-session";
  var MESSAGE_VERSION = 1;
  // setTimeout's ceiling. A later expiry is re-armed by a later stamp.
  var MAX_TIMER_MS = 2147483647;

  var config = {
    // How long a tab must be hidden before coming back probes the server.
    revalidateAfterHiddenMs: 30000,
    // How long an expectChange hold lasts when the caller names no timeout.
    holdTimeoutMs: 60000
  };

  var tabId = Math.random().toString(36).slice(2) + Date.now().toString(36);

  var bound = null;         // the stamp this page last adopted
  var boundState = null;    // anonymous | authenticated | rehydrated | signed_out
  var context = null;       // the host payload from the last rehydrate
  var stale = null;         // { source, observed } while a rehydrate is due
  var mismatches = {};      // plug-in source name -> { bound, observed }
  var sources = {};         // plug-in source name -> entry
  var holds = [];
  var subscribers = [];

  var state = null;
  var lastReason = null;
  var lastSource = null;
  var lastExpected = false;

  var channel = null;
  var expiryTimer = null;
  var hiddenAt = null;
  var inFlight = null;

  // ---- reading --------------------------------------------------------------

  function readStamp() {
    var meta = document.querySelector ? document.querySelector(META_SELECTOR) : null;
    if (!meta) return null;
    try {
      var stamp = JSON.parse(meta.getAttribute("content"));
      return validStamp(stamp) ? stamp : null;
    } catch (e) {
      return null;
    }
  }

  function validStamp(stamp) {
    return !!(stamp && typeof stamp.fingerprint === "string" && stamp.fingerprint &&
      (stamp.state === "anonymous" || stamp.state === "authenticated") &&
      typeof stamp.issuedAt === "number");
  }

  function copy(object) {
    var out = {};
    if (!object) return out;
    for (var key in object) {
      if (Object.prototype.hasOwnProperty.call(object, key)) out[key] = object[key];
    }
    return out;
  }

  function keys(object) {
    var out = [];
    for (var key in object) {
      if (Object.prototype.hasOwnProperty.call(object, key)) out.push(key);
    }
    return out;
  }

  function current() {
    return {
      state: state,
      reason: lastReason,
      source: lastSource,
      expected: lastExpected,
      fingerprint: bound ? bound.fingerprint : null,
      identities: bound ? copy(bound.identities) : {},
      context: context,
      issuedAt: bound ? bound.issuedAt : null,
      expiresAt: bound ? (bound.expiresAt == null ? null : bound.expiresAt) : null,
      rehydrateUrl: bound ? (bound.rehydrateUrl || null) : null,
      mismatches: keys(mismatches)
    };
  }

  // ---- holds ----------------------------------------------------------------

  function isExpected(scope) {
    var now = Date.now();
    holds = holds.filter(function (hold) { return !hold.released && hold.until > now; });
    for (var i = 0; i < holds.length; i++) {
      if (holds[i].scopes.indexOf("*") !== -1 || holds[i].scopes.indexOf(scope) !== -1) return true;
    }
    return false;
  }

  function expectChange(scope, options) {
    var scopes = scope == null ? ["*"] : (Object.prototype.toString.call(scope) === "[object Array]" ? scope : [scope]);
    scopes = scopes.map(function (value) { return String(value); });
    var timeout = options && options.timeoutMs > 0 ? options.timeoutMs : config.holdTimeoutMs;
    var hold = { scopes: scopes, until: Date.now() + timeout, released: false };
    holds.push(hold);
    return {
      scopes: scopes.slice(),
      release: function () { hold.released = true; },
      isActive: function () { return !hold.released && hold.until > Date.now(); }
    };
  }

  // ---- transitions ----------------------------------------------------------

  function computeState() {
    if (!bound) return null;
    if (keys(mismatches).length) return "changed";
    if (stale) return "stale";
    return boundState;
  }

  // Emits when the state moves, or when the detail is drift or an adoption even
  // if the state label stays put (a second identity switch is still news).
  function transition(detail) {
    var previous = state;
    var next = computeState();
    if (next === previous && !detail.drift && !detail.adopted) return;

    state = next;
    lastReason = detail.reason || null;
    lastSource = detail.source || null;
    lastExpected = !!detail.expected;

    var payload = {
      state: next,
      previous: previous,
      reason: lastReason,
      source: lastSource,
      expected: lastExpected,
      drift: !!detail.drift,
      observed: detail.observed === undefined ? null : detail.observed,
      error: detail.error || null,
      snapshot: current()
    };

    subscribers.slice().forEach(function (fn) {
      try { fn(payload.snapshot, payload); } catch (e) { report(e); }
    });
    dispatch("session:changed", payload);
    if (payload.drift && !payload.expected) dispatch("session:mismatch", payload);
  }

  function dispatch(name, detail) {
    if (typeof document.dispatchEvent !== "function" || typeof CustomEvent !== "function") return;
    try { document.dispatchEvent(new CustomEvent(name, { detail: detail })); } catch (e) { report(e); }
  }

  function report(error) {
    if (typeof console !== "undefined" && console.error) console.error("[StudioSession]", error);
  }

  // ---- plug-in identity sources ---------------------------------------------

  function boundIdentityFor(entry) {
    var name = entry.name;
    if (typeof entry.source.bound === "function") {
      var value = entry.source.bound(current());
      return value == null || value === "" ? null : String(value);
    }
    var identities = bound && bound.identities;
    if (!identities || identities[name] == null || identities[name] === "") return null;
    return String(identities[name]);
  }

  function identitiesEqual(entry, boundValue, observed) {
    if (typeof entry.source.equals === "function") return !!entry.source.equals(boundValue, observed);
    return boundValue === observed;
  }

  // Recomputes one source's mismatch. Returns "new", "resolved" or null.
  // undefined means the source cannot tell, which changes nothing. An UNBOUND
  // source (no bound identity) records what it sees but never mismatches: an
  // anonymous page with an identity in view is not a warning.
  function evaluate(entry) {
    if (!bound || entry.observed === undefined) return null;
    var name = entry.name;
    var boundValue = boundIdentityFor(entry);
    var had = Object.prototype.hasOwnProperty.call(mismatches, name);
    var equal = boundValue === null || identitiesEqual(entry, boundValue, entry.observed);

    if (equal) {
      if (!had) return null;
      delete mismatches[name];
      return "resolved";
    }
    var previous = mismatches[name];
    mismatches[name] = { bound: boundValue, observed: entry.observed };
    return previous && previous.observed === entry.observed && previous.bound === boundValue ? null : "new";
  }

  function registerIdentitySource(source) {
    if (!source || typeof source.start !== "function") {
      throw new TypeError("StudioSession.registerIdentitySource: a source needs a start(report) function");
    }
    var name = String(source.name || "");
    if (!SOURCE_NAME.test(name) || RESERVED_NAMES.indexOf(name) !== -1) {
      throw new TypeError("StudioSession.registerIdentitySource: invalid or reserved source name " + JSON.stringify(name));
    }
    if (sources[name]) {
      throw new Error("StudioSession.registerIdentitySource: a source named " + JSON.stringify(name) + " is already registered");
    }

    var entry = { name: name, source: source, observed: undefined, stop: null };
    sources[name] = entry;

    var reportIdentity = function (value) {
      if (sources[name] !== entry) return;
      entry.observed = value === undefined ? undefined : (value === null ? null : String(value));
      var outcome = evaluate(entry);
      if (outcome === "new") {
        transition({ reason: "source", source: name, drift: true, expected: isExpected(name),
          observed: entry.observed });
      } else if (outcome === "resolved") {
        transition({ reason: "resolved", source: name, expected: true, observed: entry.observed });
      }
    };

    try {
      var stop = source.start(reportIdentity);
      entry.stop = typeof stop === "function" ? stop : null;
    } catch (e) {
      report(e);
    }

    return {
      name: name,
      unregister: function () {
        if (sources[name] !== entry) return;
        delete sources[name];
        if (entry.stop) {
          try { entry.stop(); } catch (e) { report(e); }
        }
        if (Object.prototype.hasOwnProperty.call(mismatches, name)) {
          delete mismatches[name];
          transition({ reason: "unregistered", source: name, expected: true });
        }
      }
    };
  }

  function observed(name) {
    var entry = sources[String(name)];
    return entry ? entry.observed : undefined;
  }

  // ---- adopting a stamp -----------------------------------------------------

  // How a page takes on a stamp. `navigation` is this tab rendering a new page:
  // a fresh render, so the plain server state and no drift. Anything else is a
  // rehydrate, where a different fingerprint IS drift.
  function adopt(stamp, hostContext, options) {
    var previousFingerprint = bound ? bound.fingerprint : null;
    var wasSignedIn = boundState === "authenticated" || boundState === "rehydrated";
    var fingerprintChanged = previousFingerprint !== stamp.fingerprint;

    bound = stamp;
    if (hostContext !== undefined) {
      context = hostContext;
    } else if (options.navigation) {
      // A new render carries its own host payload; the last rehydrate's is old.
      context = null;
    }
    stale = null;

    if (options.navigation || previousFingerprint === null) {
      boundState = stamp.state;
    } else if (fingerprintChanged) {
      if (stamp.state === "anonymous") {
        boundState = wasSignedIn ? "signed_out" : "anonymous";
      } else {
        boundState = "rehydrated";
      }
    }

    keys(sources).forEach(function (name) { evaluate(sources[name]); });
    armExpiry();

    var drift = fingerprintChanged && !options.navigation && previousFingerprint !== null;
    transition({
      reason: options.reason,
      source: options.source,
      expected: !!(options.navigation || options.manual || isExpected(options.scope || SESSION_SCOPE)),
      drift: drift,
      adopted: fingerprintChanged
    });

    if (fingerprintChanged) announce();
  }

  // ---- the web2 sources -----------------------------------------------------

  // A session source saw a different truth. With a rehydrate URL the page goes
  // stale and repairs itself; without one, stale is final and IS the drift.
  function markStale(source, observedValue) {
    if (!bound) return;
    stale = { source: source, observed: observedValue === undefined ? null : observedValue };
    var repairable = !!bound.rehydrateUrl && typeof fetch === "function";
    transition({ reason: source, source: source, expected: isExpected(SESSION_SCOPE),
      drift: !repairable, observed: stale.observed });
    if (repairable) rehydrate(source, false);
  }

  function armExpiry() {
    if (expiryTimer !== null) clearTimeout(expiryTimer);
    expiryTimer = null;
    if (!bound || bound.state !== "authenticated" || typeof bound.expiresAt !== "number") return;
    var delay = Math.max(0, bound.expiresAt - Date.now());
    if (delay > MAX_TIMER_MS) return;
    var armedFor = bound;
    expiryTimer = setTimeout(function () {
      expiryTimer = null;
      if (bound === armedFor) markStale("expiry", { expiresAt: armedFor.expiresAt });
    }, delay);
  }

  // A stale page knows its stamp is out of date, so it has nothing to tell a peer.
  function announce() {
    if (!channel || !bound || stale) return;
    try {
      channel.postMessage({ v: MESSAGE_VERSION, type: "announce", tabId: tabId,
        fingerprint: bound.fingerprint, state: bound.state, issuedAt: bound.issuedAt });
    } catch (e) { report(e); }
  }

  function hello() {
    if (!channel || !bound) return;
    try { channel.postMessage({ v: MESSAGE_VERSION, type: "hello", tabId: tabId }); } catch (e) { report(e); }
  }

  function onPeerMessage(event) {
    var message = event && event.data;
    if (!message || message.v !== MESSAGE_VERSION || message.tabId === tabId || !bound) return;
    if (message.type === "hello") { announce(); return; }
    if (message.type !== "announce" || typeof message.fingerprint !== "string") return;
    if (message.fingerprint === bound.fingerprint) return;
    if (typeof message.issuedAt !== "number") return;
    // Only a NEWER truth moves this page. An older one is the peer's problem, and
    // our own announce is what tells it. STRICTLY older: two tabs that disagree
    // at the same millisecond must not answer each other forever.
    if (message.issuedAt < bound.issuedAt) {
      announce();
      return;
    }
    if (message.issuedAt === bound.issuedAt) return;
    // The same drift, heard again (a peer answering another tab's hello), is not
    // news: one drift, one warning.
    if (stale && stale.source === "peer" && (inFlight || (stale.observed && stale.observed.fingerprint === message.fingerprint))) return;
    markStale("peer", { state: message.state, fingerprint: message.fingerprint, issuedAt: message.issuedAt });
  }

  // ---- rehydrate ------------------------------------------------------------

  function swapCsrf(token) {
    if (!token || !document.querySelector) return;
    var meta = document.querySelector('meta[name="csrf-token"]');
    if (meta) meta.setAttribute("content", token);
  }

  function rehydrate(source, manual) {
    if (!bound || !bound.rehydrateUrl || typeof fetch !== "function") return Promise.resolve(current());
    if (inFlight) {
      // A deliberate refresh must see the session as it is AFTER the caller's own
      // change. A probe already on the wire may have left before that change, so
      // a manual refresh waits for it and then asks again.
      return manual ? inFlight.then(function () { return rehydrate(source, true); }) : inFlight;
    }

    var url = bound.rehydrateUrl;
    inFlight = fetch(url, {
      method: "GET",
      credentials: "same-origin",
      cache: "no-store",
      headers: { "Accept": "application/json" }
    }).then(function (response) {
      if (response.status === 401) return { revoked: true };
      if (!response.ok) throw new Error("rehydrate answered HTTP " + response.status);
      return response.json();
    }).then(function (body) {
      inFlight = null;
      if (body && body.revoked) {
        revoke(source, manual);
        return current();
      }
      if (!body || !validStamp(body.session)) throw new Error("rehydrate returned no session stamp");
      swapCsrf(body.csrf);
      adopt(body.session, body.context === undefined ? null : body.context,
        { reason: manual ? "manual" : source, source: source, manual: manual });
      return current();
    }).catch(function (error) {
      inFlight = null;
      // A probe that fails on a page with no known drift changes nothing. A page
      // already stale could not confirm what it learned, so that IS drift.
      if (stale) {
        transition({ reason: "rehydrate_failed", source: source, expected: isExpected(SESSION_SCOPE),
          drift: true, error: String(error && error.message || error) });
      }
      return current();
    });
    return inFlight;
  }

  // The server refused the session (a host filter answered 401). The page is
  // now anonymous as far as this browser is concerned. issuedAt is NOT advanced:
  // this tab's clock is not the server's, and a peer should learn the same fact
  // from its own probe rather than trust a time this tab invented.
  function revoke(source, manual) {
    adopt({
      v: bound ? bound.v : 1,
      state: "anonymous",
      fingerprint: "anonymous",
      issuedAt: bound ? bound.issuedAt : Date.now(),
      expiresAt: null,
      rehydrateUrl: bound ? bound.rehydrateUrl : null,
      identities: {}
    }, null, { reason: "revoked", source: source, manual: manual });
  }

  // ---- lifecycle ------------------------------------------------------------

  function seat(reason) {
    var stamp = readStamp();
    if (!stamp) return;

    if (!bound) {
      adopt(stamp, undefined, { reason: reason, navigation: true });
      return;
    }
    if (stamp.fingerprint === bound.fingerprint) {
      bound = stamp;
      stale = null;
      boundState = stamp.state;
      keys(sources).forEach(function (name) { evaluate(sources[name]); });
      armExpiry();
      transition({ reason: reason, expected: true });
      return;
    }
    if (stamp.issuedAt >= bound.issuedAt) {
      adopt(stamp, undefined, { reason: reason, navigation: true });
    } else {
      // A restored snapshot (Turbo's cache) rendered for an OLDER session than
      // this tab already knows. The page on screen describes that stamp, so it is
      // what the store binds to; then it asks the server, and whatever differs
      // between the two is drift this page really has.
      bound = stamp;
      boundState = stamp.state;
      context = null;
      keys(sources).forEach(function (name) { evaluate(sources[name]); });
      armExpiry();
      markStale("restored", { fingerprint: stamp.fingerprint, issuedAt: stamp.issuedAt });
    }
  }

  function onVisibilityChange() {
    if (document.hidden) { hiddenAt = Date.now(); return; }
    if (hiddenAt === null) return;
    var away = Date.now() - hiddenAt;
    hiddenAt = null;
    if (away >= config.revalidateAfterHiddenMs) rehydrate("server", false);
  }

  function onPageShow(event) {
    if (!event || !event.persisted) return;
    hello();
    rehydrate("server", false);
  }

  function subscribe(fn) {
    if (typeof fn !== "function") throw new TypeError("StudioSession.subscribe needs a function");
    subscribers.push(fn);
    return function unsubscribe() {
      subscribers = subscribers.filter(function (candidate) { return candidate !== fn; });
    };
  }

  // A deliberate refresh by page code: whatever it finds is expected.
  function refresh() {
    return rehydrate("server", true);
  }

  function configure(options) {
    if (!options) return copy(config);
    if (options.revalidateAfterHiddenMs >= 0) config.revalidateAfterHiddenMs = options.revalidateAfterHiddenMs;
    if (options.holdTimeoutMs > 0) config.holdTimeoutMs = options.holdTimeoutMs;
    return copy(config);
  }

  // ---- Alpine bridge --------------------------------------------------------

  function alpineStoreValue(snapshot) {
    var value = copy(snapshot);
    value.is = function (name) { return this.state === name; };
    return value;
  }

  function installAlpineStore() {
    var Alpine = window.Alpine;
    if (!Alpine || typeof Alpine.store !== "function") return;
    if (!Alpine.store("studioSession")) Alpine.store("studioSession", alpineStoreValue(current()));
    subscribe(function (snapshot) {
      var store = Alpine.store("studioSession");
      if (!store) return;
      for (var key in snapshot) {
        if (Object.prototype.hasOwnProperty.call(snapshot, key)) store[key] = snapshot[key];
      }
    });
  }

  // ---- boot -----------------------------------------------------------------

  window.StudioSession = {
    loaded: true,
    version: 1,
    STATES: STATES.slice(),
    SESSION_SCOPE: SESSION_SCOPE,
    current: current,
    subscribe: subscribe,
    refresh: refresh,
    expectChange: expectChange,
    registerIdentitySource: registerIdentitySource,
    observed: observed,
    configure: configure
  };

  if (typeof BroadcastChannel === "function") {
    try {
      channel = new BroadcastChannel(CHANNEL_NAME);
      channel.onmessage = onPeerMessage;
    } catch (e) {
      channel = null;
    }
  }

  seat("render");
  hello();

  document.addEventListener("turbo:load", function () { seat("navigation"); });
  document.addEventListener("visibilitychange", onVisibilityChange);
  window.addEventListener("pageshow", onPageShow);

  if (window.Alpine) {
    installAlpineStore();
  } else {
    document.addEventListener("alpine:init", installAlpineStore);
  }
})();
