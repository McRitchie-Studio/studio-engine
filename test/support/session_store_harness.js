// Executes app/assets/javascripts/studio/session.js FOR REAL under node.
//
// Driven by test/views/studio_session_store_test.rb, which asserts every scenario
// below by NAME, so a scenario that silently stops running reddens the suite.
//
// Each "tab" is its own vm context: its own window, document, timers and copy of
// the store, exactly as two browser tabs each load their own copy of the script.
// Tabs in one scenario share two things a real browser shares: a BroadcastChannel
// bus (messages are structured-cloned and delivered asynchronously, never to the
// sender) and a fake server holding the one cookie session they all send.
//
// Output: one "PASS <name>" or "FAIL <name>: <reason>" line per scenario, then
// "SESSION-STORE-SCENARIOS <passed>/<total>". Exit status is 1 on any failure.
"use strict";

const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

const SOURCE_PATH = process.argv[2];
if (!SOURCE_PATH) {
  console.error("usage: node session_store_harness.js <path to studio/session.js>");
  process.exit(2);
}
const SOURCE = fs.readFileSync(SOURCE_PATH, "utf8");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Each tab is its own realm, so its TypeError is not this file's TypeError.
const isTypeError = (error) => !!error && error.name === "TypeError";

// ---- the shared browser world ----------------------------------------------

function makeWorld() {
  const channels = new Set();
  const posted = [];

  class BroadcastChannel {
    constructor(name) {
      this.name = name;
      this.onmessage = null;
      channels.add(this);
    }
    postMessage(data) {
      const payload = JSON.parse(JSON.stringify(data));
      posted.push(payload);
      for (const peer of channels) {
        if (peer === this || peer.name !== this.name) continue;
        setTimeout(() => { if (channels.has(peer) && peer.onmessage) peer.onmessage({ data: payload }); }, 0);
      }
    }
    close() { channels.delete(this); }
  }

  let seq = 0;
  const server = {
    // The one cookie session every tab sends.
    session: { user: null, identities: {} },
    rehydrateUrl: "/session/state",
    status: 200,
    delayMs: 0,
    fail: false,
    requests: 0,
    csrfCounter: 0,
    expiresInMs: null,
    signIn(user, identities) { this.session = { user, identities: identities || {} }; },
    signOut() { this.session = { user: null, identities: {} }; },
    stamp(overrides) {
      const s = this.session;
      const ids = s.identities || {};
      const idKey = Object.keys(ids).sort().map((k) => k + "=" + ids[k]).join("&");
      const anonymous = s.user === null && idKey === "";
      const stamp = {
        v: 1,
        state: s.user === null ? "anonymous" : "authenticated",
        fingerprint: anonymous ? "anonymous" : "fp-" + s.user + (idKey ? "-" + idKey : ""),
        issuedAt: Date.now() * 10 + (++seq),
        expiresAt: s.user !== null && this.expiresInMs !== null ? Date.now() + this.expiresInMs : null,
        rehydrateUrl: this.rehydrateUrl,
        identities: Object.assign({}, ids)
      };
      return Object.assign(stamp, overrides || {});
    }
  };

  return { BroadcastChannel, server, posted, channels };
}

function makeElement(attrs) {
  return {
    attrs: Object.assign({}, attrs),
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
    setAttribute(name, value) { this.attrs[name] = String(value); }
  };
}

function makeTab(world, options) {
  const opts = options || {};
  const listeners = {};
  const windowListeners = {};
  const metas = {};
  const events = [];
  const fetches = [];

  const on = (table, type, fn) => { (table[type] = table[type] || []).push(fn); };
  const fire = (table, event) => { (table[event.type] || []).slice().forEach((fn) => fn(event)); };

  const document = {
    hidden: false,
    querySelector(selector) {
      const match = /^meta\[name="([^"]+)"\]$/.exec(selector);
      return match ? metas[match[1]] || null : null;
    },
    addEventListener(type, fn) { on(listeners, type, fn); },
    dispatchEvent(event) { fire(listeners, event); return true; }
  };

  function setMeta(name, content) {
    if (content === null || content === undefined) delete metas[name];
    else metas[name] = makeElement({ name, content });
  }

  if (opts.stamp !== undefined) {
    setMeta("studio-session", typeof opts.stamp === "string" ? opts.stamp : JSON.stringify(opts.stamp));
  }
  setMeta("csrf-token", "csrf-initial");

  const server = world.server;
  function fetch(url, init) {
    fetches.push({ url, init });
    server.requests += 1;
    const respond = () => {
      if (server.fail) return Promise.reject(new Error("network down"));
      const status = server.status;
      const body = status === 200
        ? { session: server.stamp(), context: { host: "payload", user: server.session.user }, csrf: "csrf-" + (++server.csrfCounter) }
        : { error: "session expired" };
      return Promise.resolve({ status, ok: status >= 200 && status < 300, json: () => Promise.resolve(body) });
    };
    if (server.delayMs > 0) {
      // Freeze the answer at request time, as a real request would.
      const frozen = respond();
      return new Promise((resolve, reject) => setTimeout(() => frozen.then(resolve, reject), server.delayMs));
    }
    return respond();
  }

  class CustomEvent {
    constructor(type, init) { this.type = type; this.detail = init ? init.detail : undefined; }
  }

  const sandbox = {
    document,
    CustomEvent,
    BroadcastChannel: opts.noChannel ? undefined : world.BroadcastChannel,
    fetch: opts.noFetch ? undefined : fetch,
    setTimeout,
    clearTimeout,
    console: { error() {}, warn() {}, log() {} },
    addEventListener(type, fn) { on(windowListeners, type, fn); },
    Alpine: opts.Alpine
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);

  document.addEventListener("session:changed", (event) => events.push({ type: "changed", detail: event.detail }));
  document.addEventListener("session:mismatch", (event) => events.push({ type: "mismatch", detail: event.detail }));

  vm.runInContext(SOURCE, sandbox, { filename: "studio/session.js" });

  return {
    sandbox,
    document,
    events,
    fetches,
    store: sandbox.StudioSession,
    setMeta,
    csrf() { return metas["csrf-token"].getAttribute("content"); },
    navigate(stamp) {
      setMeta("studio-session", JSON.stringify(stamp));
      fire(listeners, { type: "turbo:load" });
    },
    hide() { document.hidden = true; fire(listeners, { type: "visibilitychange" }); },
    show() { document.hidden = false; fire(listeners, { type: "visibilitychange" }); },
    pageshow(persisted) { fire(windowListeners, { type: "pageshow", persisted: !!persisted }); },
    fireDocument(type) { fire(listeners, { type }); },
    changed() { return events.filter((e) => e.type === "changed").map((e) => e.detail); },
    mismatches() { return events.filter((e) => e.type === "mismatch").map((e) => e.detail); },
    clearEvents() { events.length = 0; }
  };
}

// ---- scenarios ---------------------------------------------------------------

const scenarios = [];
const scenario = (name, fn) => scenarios.push({ name, fn });

scenario("seats_an_anonymous_page", async () => {
  const world = makeWorld();
  const tab = makeTab(world, { stamp: world.server.stamp() });
  const snap = tab.store.current();
  assert.strictEqual(snap.state, "anonymous");
  assert.strictEqual(snap.fingerprint, "anonymous");
  assert.deepStrictEqual(Array.from(snap.mismatches), []);
  assert.deepStrictEqual(Array.from(tab.store.STATES),
    ["anonymous", "authenticated", "stale", "changed", "rehydrated", "signed_out"]);
});

scenario("seats_an_authenticated_page", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const tab = makeTab(world, { stamp: world.server.stamp() });
  const snap = tab.store.current();
  assert.strictEqual(snap.state, "authenticated");
  assert.strictEqual(snap.fingerprint, "fp-u1");
  assert.strictEqual(snap.rehydrateUrl, "/session/state");
});

scenario("stays_dormant_without_a_stamp", async () => {
  const world = makeWorld();
  const tab = makeTab(world, {});
  assert.strictEqual(tab.store.current().state, null);
  tab.hide();
  tab.show();
  await tab.store.refresh();
  await sleep(10);
  assert.strictEqual(tab.fetches.length, 0, "a dormant store fetches nothing");
  assert.strictEqual(world.posted.length, 0, "a dormant store broadcasts nothing");
  assert.strictEqual(tab.changed().length, 0);
});

scenario("treats_an_unreadable_stamp_as_dormant", async () => {
  const world = makeWorld();
  const tab = makeTab(world, { stamp: "{not json" });
  assert.strictEqual(tab.store.current().state, null);
  const tab2 = makeTab(world, { stamp: JSON.stringify({ state: "weird", fingerprint: "x", issuedAt: 1 }) });
  assert.strictEqual(tab2.store.current().state, null);
});

scenario("peer_sign_out_rehydrates_to_signed_out", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const a = makeTab(world, { stamp: world.server.stamp() });
  const b = makeTab(world, { stamp: world.server.stamp() });
  await sleep(10);
  a.clearEvents();
  b.clearEvents();

  world.server.signOut();
  b.navigate(world.server.stamp());
  await sleep(20);

  assert.strictEqual(b.store.current().state, "anonymous", "the tab that signed out navigated to a fresh render");
  assert.strictEqual(b.mismatches().length, 0, "a tab's own navigation is never a mismatch");

  assert.strictEqual(a.store.current().state, "signed_out");
  const states = a.changed().map((d) => d.state);
  assert.deepStrictEqual(states, ["stale", "signed_out"]);
  const last = a.changed()[1];
  assert.strictEqual(last.reason, "peer");
  assert.strictEqual(last.drift, true);
  assert.strictEqual(last.expected, false);
  assert.strictEqual(a.mismatches().length, 1, "exactly one mismatch warning");
  assert.strictEqual(a.csrf(), "csrf-1", "the rehydrate swapped in a fresh CSRF token");
  assert.deepStrictEqual(a.store.current().context, { host: "payload", user: null });
});

scenario("peer_sign_in_rehydrates_an_anonymous_page", async () => {
  const world = makeWorld();
  const a = makeTab(world, { stamp: world.server.stamp() });
  const b = makeTab(world, { stamp: world.server.stamp() });
  await sleep(10);
  a.clearEvents();

  world.server.signIn("u2");
  b.navigate(world.server.stamp());
  await sleep(20);

  const snap = a.store.current();
  assert.strictEqual(snap.state, "rehydrated");
  assert.strictEqual(snap.fingerprint, "fp-u2");
  assert.strictEqual(a.mismatches().length, 1);
});

scenario("peer_drift_without_a_rehydrate_url_stays_stale_and_warns", async () => {
  const world = makeWorld();
  world.server.rehydrateUrl = null;
  world.server.signIn("u1");
  const a = makeTab(world, { stamp: world.server.stamp() });
  const b = makeTab(world, { stamp: world.server.stamp() });
  await sleep(10);
  a.clearEvents();

  world.server.signOut();
  b.navigate(world.server.stamp());
  await sleep(20);

  assert.strictEqual(a.store.current().state, "stale");
  assert.strictEqual(a.fetches.length, 0, "no URL, no request");
  assert.strictEqual(a.mismatches().length, 1, "unrepairable drift is the warning");
  assert.deepStrictEqual(a.changed()[0].observed.state, "anonymous");
});

scenario("one_drift_warns_once_however_often_it_is_heard", async () => {
  const world = makeWorld();
  world.server.rehydrateUrl = null;
  world.server.signIn("u1");
  const a = makeTab(world, { stamp: world.server.stamp() });
  await sleep(10);
  a.clearEvents();

  // A new tab BOOTS (announce + hello) under a newer session. Its hello makes A
  // answer, and A's older answer makes the new tab repeat itself, so A hears the
  // same drift more than once.
  world.server.signOut();
  const b = makeTab(world, { stamp: world.server.stamp() });
  const c = makeTab(world, { stamp: world.server.stamp() });
  await sleep(40);

  assert.strictEqual(a.store.current().state, "stale");
  assert.strictEqual(a.mismatches().length, 1, "saw " + a.mismatches().length + " warnings for one drift");
  assert.strictEqual(b.store.current().state, "anonymous");
  assert.strictEqual(c.store.current().state, "anonymous");
});

scenario("an_older_peer_never_moves_a_newer_tab", async () => {
  const world = makeWorld();
  const old = world.server.stamp();
  world.server.signIn("u1");
  const fresh = world.server.stamp();
  world.server.status = 200;

  const newer = makeTab(world, { stamp: fresh });
  await sleep(10);
  newer.clearEvents();
  const older = makeTab(world, { stamp: old, noFetch: true });
  await sleep(30);

  assert.strictEqual(newer.store.current().state, "authenticated", "the newer tab ignores the older truth");
  assert.strictEqual(newer.changed().length, 0);
  assert.strictEqual(older.store.current().state, "stale", "the newer tab's answer reached the older one");
});

scenario("answers_an_older_announce_with_its_own", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const tab = makeTab(world, { stamp: world.server.stamp() });
  const outsider = new world.BroadcastChannel("studio-session");
  const heard = [];
  outsider.onmessage = (event) => heard.push(event.data);
  await sleep(10);
  heard.length = 0;

  // No hello: only the announce itself can prompt the answer.
  outsider.postMessage({ v: 1, type: "announce", tabId: "outsider", fingerprint: "anonymous", state: "anonymous", issuedAt: 1 });
  await sleep(20);

  assert.strictEqual(tab.store.current().state, "authenticated", "an older truth does not move this tab");
  const answers = heard.filter((m) => m.type === "announce" && m.fingerprint === "fp-u1");
  assert.strictEqual(answers.length, 1, "the tab answered the older peer with its newer session");
  outsider.close();
});

scenario("same_millisecond_disagreement_does_not_ping_pong", async () => {
  const world = makeWorld();
  const a = makeTab(world, { stamp: { v: 1, state: "authenticated", fingerprint: "fp-a", issuedAt: 500, expiresAt: null, rehydrateUrl: null, identities: {} } });
  const b = makeTab(world, { stamp: { v: 1, state: "authenticated", fingerprint: "fp-b", issuedAt: 500, expiresAt: null, rehydrateUrl: null, identities: {} } });
  await sleep(50);
  assert.ok(world.posted.length <= 6, "bounded chatter, saw " + world.posted.length + " messages");
  assert.strictEqual(a.store.current().state, "authenticated");
  assert.strictEqual(b.store.current().state, "authenticated");
});

scenario("server_401_on_return_reads_as_revoked", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const tab = makeTab(world, { stamp: world.server.stamp() });
  tab.store.configure({ revalidateAfterHiddenMs: 0 });
  tab.clearEvents();

  world.server.status = 401;
  tab.hide();
  tab.show();
  await sleep(20);

  const snap = tab.store.current();
  assert.strictEqual(snap.state, "signed_out");
  assert.strictEqual(snap.reason, "revoked");
  assert.strictEqual(snap.fingerprint, "anonymous");
  assert.strictEqual(tab.mismatches().length, 1);
});

scenario("server_probe_of_an_unchanged_session_is_silent", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const tab = makeTab(world, { stamp: world.server.stamp() });
  tab.store.configure({ revalidateAfterHiddenMs: 0 });
  tab.clearEvents();

  tab.hide();
  tab.show();
  await sleep(20);

  assert.strictEqual(tab.fetches.length, 1, "returning to the tab probed the server");
  assert.strictEqual(tab.store.current().state, "authenticated");
  assert.strictEqual(tab.changed().length, 0, "no drift, no event");
  assert.strictEqual(tab.csrf(), "csrf-1", "the probe still refreshed the CSRF token");
});

scenario("a_short_absence_does_not_probe", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const tab = makeTab(world, { stamp: world.server.stamp() });
  tab.hide();
  tab.show();
  await sleep(10);
  assert.strictEqual(tab.fetches.length, 0, "under revalidateAfterHiddenMs (30s default) nothing is fetched");
});

scenario("bfcache_restore_probes_the_server", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const tab = makeTab(world, { stamp: world.server.stamp() });
  tab.clearEvents();
  world.server.signOut();
  tab.pageshow(false);
  await sleep(10);
  assert.strictEqual(tab.fetches.length, 0, "an ordinary pageshow is not a restore");
  tab.pageshow(true);
  await sleep(20);
  assert.strictEqual(tab.store.current().state, "signed_out");
});

scenario("expiry_marks_stale_then_rehydrates", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  world.server.expiresInMs = 25;
  const tab = makeTab(world, { stamp: world.server.stamp() });
  tab.clearEvents();
  world.server.signOut(); // the cookie lapsed: the next request carries no session
  await sleep(80);

  const states = tab.changed().map((d) => d.state);
  assert.deepStrictEqual(states, ["stale", "signed_out"]);
  assert.strictEqual(tab.changed()[0].reason, "expiry");
});

scenario("plugin_source_mismatch_then_resolve", async () => {
  const world = makeWorld();
  world.server.signIn("u1", { acct: "id-1" });
  const tab = makeTab(world, { stamp: world.server.stamp() });
  let report = null;
  let stopped = false;
  const handle = tab.store.registerIdentitySource({ name: "acct", start(r) { report = r; return () => { stopped = true; }; } });
  tab.clearEvents();

  report("id-1");
  assert.strictEqual(tab.changed().length, 0, "matching the bound identity is not news");

  report("id-2");
  let snap = tab.store.current();
  assert.strictEqual(snap.state, "changed");
  assert.deepStrictEqual(Array.from(snap.mismatches), ["acct"]);
  assert.strictEqual(tab.store.observed("acct"), "id-2");
  assert.strictEqual(tab.mismatches().length, 1);
  assert.strictEqual(tab.mismatches()[0].source, "acct");

  report("id-2");
  assert.strictEqual(tab.mismatches().length, 1, "the same observation twice is one warning");

  report(undefined);
  assert.strictEqual(tab.store.current().state, "changed", "undefined means cannot tell, which changes nothing");

  report("id-1");
  snap = tab.store.current();
  assert.strictEqual(snap.state, "authenticated");
  assert.strictEqual(tab.changed().pop().reason, "resolved");
  assert.strictEqual(tab.mismatches().length, 1, "resolution is not a warning");

  handle.unregister();
  assert.strictEqual(stopped, true, "unregister calls the source's stop function");
});

scenario("an_unbound_source_never_mismatches", async () => {
  const world = makeWorld();
  const tab = makeTab(world, { stamp: world.server.stamp() });
  tab.clearEvents();
  let report = null;
  tab.store.registerIdentitySource({ name: "acct", start(r) { report = r; } });
  report("id-9");
  assert.strictEqual(tab.store.current().state, "anonymous");
  assert.strictEqual(tab.changed().length, 0);
  assert.strictEqual(tab.store.observed("acct"), "id-9", "the observation is still recorded");
});

scenario("a_source_can_supply_its_own_bound_and_equality", async () => {
  const world = makeWorld();
  world.server.signIn("u1", { acct: "ABC" });
  const tab = makeTab(world, { stamp: world.server.stamp() });
  let report = null;
  tab.store.registerIdentitySource({
    name: "acct",
    start(r) { report = r; },
    equals(bound, observed) { return String(bound).toLowerCase() === String(observed).toLowerCase(); }
  });
  report("abc");
  assert.strictEqual(tab.store.current().state, "authenticated", "equals() decides");

  let reportOther = null;
  tab.store.registerIdentitySource({ name: "device", start(r) { reportOther = r; }, bound() { return "d-1"; } });
  reportOther("d-2");
  assert.strictEqual(tab.store.current().state, "changed", "bound() decides");
});

scenario("expect_change_suppresses_the_mismatch_warning", async () => {
  const world = makeWorld();
  world.server.signIn("u1", { acct: "id-1" });
  const tab = makeTab(world, { stamp: world.server.stamp() });
  let report = null;
  tab.store.registerIdentitySource({ name: "acct", start(r) { report = r; } });
  report("id-1");
  tab.clearEvents();

  const hold = tab.store.expectChange("acct");
  report("id-2");
  assert.strictEqual(tab.store.current().state, "changed");
  assert.strictEqual(tab.changed()[0].expected, true);
  assert.strictEqual(tab.mismatches().length, 0, "a declared switch raises no warning");

  // The flow re-binds the session, then refreshes deliberately.
  world.server.signIn("u1", { acct: "id-2" });
  const snap = await tab.store.refresh();
  assert.strictEqual(snap.state, "rehydrated");
  assert.deepStrictEqual(Array.from(snap.mismatches), []);
  assert.strictEqual(tab.mismatches().length, 0, "a deliberate refresh is expected");
  assert.strictEqual(hold.isActive(), true);
  hold.release();
  assert.strictEqual(hold.isActive(), false);

  report("id-3");
  assert.strictEqual(tab.mismatches().length, 1, "after release, drift warns again");
});

scenario("holds_expire_and_match_only_their_scope", async () => {
  const world = makeWorld();
  world.server.signIn("u1", { acct: "id-1", other: "o-1" });
  const tab = makeTab(world, { stamp: world.server.stamp() });
  let report = null;
  tab.store.registerIdentitySource({ name: "acct", start(r) { report = r; } });

  tab.store.expectChange("other");
  report("id-2");
  assert.strictEqual(tab.mismatches().length, 1, "a hold on another scope does not cover this source");
  report("id-1");

  tab.store.expectChange("acct", { timeoutMs: 15 });
  await sleep(40);
  report("id-3");
  assert.strictEqual(tab.mismatches().length, 2, "an expired hold covers nothing");
  report("id-1");

  const all = tab.store.expectChange("*");
  report("id-4");
  assert.strictEqual(tab.mismatches().length, 2, "the * scope covers every source");
  all.release();

  const both = tab.store.expectChange(["session", "acct"]);
  report("id-5");
  assert.strictEqual(tab.mismatches().length, 2, "an array of scopes covers each of them");
  both.release();
});

scenario("session_scope_hold_covers_web2_drift", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const a = makeTab(world, { stamp: world.server.stamp() });
  const b = makeTab(world, { stamp: world.server.stamp() });
  await sleep(10);
  a.clearEvents();
  a.store.expectChange("session");

  world.server.signIn("u3");
  b.navigate(world.server.stamp());
  await sleep(20);
  assert.strictEqual(a.store.current().state, "rehydrated");
  assert.strictEqual(a.mismatches().length, 0);
});

scenario("manual_refresh_waits_for_a_probe_already_in_flight", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const tab = makeTab(world, { stamp: world.server.stamp() });
  tab.store.configure({ revalidateAfterHiddenMs: 0 });
  world.server.delayMs = 20;

  tab.hide();
  tab.show(); // a probe leaves carrying the u1 session
  world.server.signIn("u4"); // the page's own flow changes the session
  const snap = await tab.store.refresh();

  assert.strictEqual(tab.fetches.length, 2, "the manual refresh asked again after the probe");
  assert.strictEqual(snap.fingerprint, "fp-u4");
  assert.strictEqual(snap.state, "rehydrated");
});

scenario("navigation_adopts_a_new_session_without_a_warning", async () => {
  const world = makeWorld();
  const tab = makeTab(world, { stamp: world.server.stamp() });
  tab.clearEvents();
  const before = world.posted.length;

  world.server.signIn("u1");
  tab.navigate(world.server.stamp());

  const snap = tab.store.current();
  assert.strictEqual(snap.state, "authenticated");
  assert.strictEqual(snap.reason, "navigation");
  assert.strictEqual(tab.changed()[0].expected, true);
  assert.strictEqual(tab.changed()[0].drift, false, "a tab's own navigation is not drift");
  assert.strictEqual(tab.mismatches().length, 0);
  assert.ok(world.posted.length > before, "the new session was announced to peers");
});

scenario("a_restored_older_snapshot_goes_stale_and_rechecks", async () => {
  const world = makeWorld();
  const oldStamp = world.server.stamp();
  const tab = makeTab(world, { stamp: oldStamp });
  world.server.signIn("u1");
  tab.navigate(world.server.stamp());
  tab.clearEvents();

  tab.navigate(oldStamp); // Turbo restores a cached page rendered before sign-in
  await sleep(20);

  const states = tab.changed().map((d) => d.state);
  assert.strictEqual(states[0], "stale");
  assert.strictEqual(tab.changed()[0].reason, "restored");
  assert.strictEqual(tab.store.current().state, "rehydrated");
});

scenario("a_failed_rehydrate_on_a_stale_page_is_drift", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const a = makeTab(world, { stamp: world.server.stamp() });
  const b = makeTab(world, { stamp: world.server.stamp() });
  await sleep(10);
  a.clearEvents();

  world.server.fail = true;
  world.server.signOut();
  b.navigate(world.server.stamp());
  await sleep(20);

  assert.strictEqual(a.store.current().state, "stale");
  const last = a.changed().pop();
  assert.strictEqual(last.reason, "rehydrate_failed");
  assert.ok(last.error);
  assert.strictEqual(a.mismatches().length, 1);
});

scenario("register_refuses_bad_reserved_and_duplicate_names", async () => {
  const world = makeWorld();
  const tab = makeTab(world, { stamp: world.server.stamp() });
  const start = () => {};
  for (const name of ["", "has space", "peer", "expiry", "server", "session", "*"]) {
    assert.throws(() => tab.store.registerIdentitySource({ name, start }), isTypeError, "refused " + JSON.stringify(name));
  }
  assert.throws(() => tab.store.registerIdentitySource({ name: "acct" }), isTypeError, "start() is required");
  tab.store.registerIdentitySource({ name: "acct", start });
  assert.throws(() => tab.store.registerIdentitySource({ name: "acct", start }), /already registered/);
});

scenario("subscribers_receive_transitions_and_can_leave", async () => {
  const world = makeWorld();
  world.server.signIn("u1", { acct: "id-1" });
  const tab = makeTab(world, { stamp: world.server.stamp() });
  let report = null;
  tab.store.registerIdentitySource({ name: "acct", start(r) { report = r; } });

  const seen = [];
  tab.store.subscribe(() => { throw new Error("a broken subscriber"); });
  const leave = tab.store.subscribe((snapshot, detail) => seen.push([snapshot.state, detail.previous]));
  report("id-2");
  assert.deepStrictEqual(seen, [["changed", "authenticated"]], "a throwing subscriber does not starve the next");
  leave();
  report("id-1");
  assert.strictEqual(seen.length, 1, "unsubscribed");
});

scenario("mirrors_into_an_alpine_store_without_touching_host_stores", async () => {
  const stores = {};
  const Alpine = { store(name, value) { if (value === undefined) return stores[name]; stores[name] = value; return value; } };
  stores.session = { mine: "host" };
  const world = makeWorld();
  world.server.signIn("u1", { acct: "id-1" });
  const tab = makeTab(world, { stamp: world.server.stamp(), Alpine });

  assert.strictEqual(stores.studioSession.state, "authenticated");
  assert.strictEqual(stores.studioSession.is("authenticated"), true);
  let report = null;
  tab.store.registerIdentitySource({ name: "acct", start(r) { report = r; } });
  report("id-2");
  assert.strictEqual(stores.studioSession.state, "changed");
  assert.deepStrictEqual(stores.session, { mine: "host" }, "the host's own session store is untouched");

  // Alpine arriving AFTER the store: the alpine:init path.
  const late = {};
  const LateAlpine = { store(name, value) { if (value === undefined) return late[name]; late[name] = value; return value; } };
  const tab2 = makeTab(world, { stamp: world.server.stamp() });
  tab2.sandbox.Alpine = LateAlpine;
  tab2.fireDocument("alpine:init");
  assert.strictEqual(late.studioSession.state, "authenticated");
});

scenario("works_without_broadcast_channel", async () => {
  const world = makeWorld();
  world.server.signIn("u1");
  const tab = makeTab(world, { stamp: world.server.stamp(), noChannel: true });
  assert.strictEqual(tab.store.current().state, "authenticated");
  tab.store.configure({ revalidateAfterHiddenMs: 0 });
  world.server.signOut();
  tab.hide();
  tab.show();
  await sleep(20);
  assert.strictEqual(tab.store.current().state, "signed_out", "the server source still works alone");
});

(async () => {
  let passed = 0;
  for (const { name, fn } of scenarios) {
    try {
      await fn();
      passed += 1;
      console.log("PASS " + name);
    } catch (error) {
      console.log("FAIL " + name + ": " + (error && error.message ? error.message : error));
    }
  }
  console.log("SESSION-STORE-SCENARIOS " + passed + "/" + scenarios.length);
  process.exit(passed === scenarios.length ? 0 : 1);
})();
