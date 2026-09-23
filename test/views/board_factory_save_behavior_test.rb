# frozen_string_literal: true

require "test_helper"
require "action_view"
require "tempfile"

# Executes the studioBoard factory FOR REAL. board_primitive_test.rb asserts the
# board's rendered MARKUP contract and, for the factory itself, source substrings —
# and it says so out loud, because until this file landed the engine had no way to
# run the factory at all.
#
# THAT BLINDNESS SHIPPED A DEFECT. Through 0.76.2 saveOrder ended:
#
#     this.request(this.reorderUrl, "POST", payload).catch(function () {
#       // Order save failed — positions are stale but the board stays functional.
#     });
#
# Two layers of silence, and every source assertion in the suite stayed green
# across both. `window.fetch` RESOLVES on 4xx, so a 422 never reached that catch;
# and the catch was empty regardless. The server had already written the operator
# its reason — "That order does not match this week's games — reload and try
# again." — and that sentence was unreachable by construction on all five boards
# that ride this factory, while the CSS counter renumbered the cards as though the
# save had landed. Only a test that CALLS saveOrder and reads the toast can tell
# the fixed build from the broken one; a substring assertion cannot, because the
# broken build contained the word "catch" too.
#
# So: the page-level partial's <script> is extracted and run under node with
# minimal window/document/fetch stubs, and the save path's behavior is asserted by
# invoking it.
class BoardFactorySaveBehaviorTest < Minitest::Test
  # A missing node runtime FAILS here; it must never `skip`. This is the only
  # coverage that observes the factory's failure handling, so a skip would read as
  # a pass on exactly the host where the coverage is absent. Same discipline as
  # modal_host_store_behavior_test.rb, for the same reason.
  def test_node_runtime_is_available
    refute_empty node_path,
                 "node runtime NOT FOUND on PATH. The board factory save-behavior suite " \
                 "executes the factory for real and is the only coverage of how a refused " \
                 "reorder reaches the operator — skipping it would report green with zero " \
                 "coverage. Install node (mise install node@20) and re-run."
  end

  def test_save_order_surfaces_refusals_under_node
    out = run_harness

    assert_includes out, "ALL-BOARD-SAVE-SCENARIOS-PASS", out
  end

  private

  def node_path
    @node_path ||= `which node 2>/dev/null`.strip
  end

  def factory_script
    html = ActionView::Base.with_empty_template_cache
                           .with_view_paths(["app/views"])
                           .render(partial: "studio/board_assets")
    script = html[%r{<script>(.*?)</script>}m, 1]
    refute_nil script, "expected studio/_board_assets to emit its factory <script>"
    script
  end

  def run_harness
    node = node_path
    script = factory_script
    out = nil
    Tempfile.create(["board_factory_harness", ".js"]) do |f|
      f.write(HARNESS_PRELUDE, script, HARNESS_SCENARIOS)
      f.flush
      out = `#{node} #{f.path} 2>&1`
    end
    assert $?.success?, "node harness failed:\n#{out}"
    out
  end

  # Minimal browser stubs. The factory reads document.querySelector (the CSRF
  # meta), window.authedFetch || window.fetch, window.dispatchEvent/CustomEvent
  # (the event seam), window.alert (the toast-less fallback), and
  # document.querySelectorAll in updateCounts. Nothing here touches Alpine or
  # SortableJS: init() is never called, so the factory is exercised as the plain
  # object it is.
  HARNESS_PRELUDE = <<~'JS'
    'use strict';
    const dispatched = [];
    const alerted = [];
    const document = {
      // No CSRF meta on the harness page — request() already tolerates that
      // ((… || {}).content || ""), and asserting the header is not this file's job.
      querySelector() { return null; },
      querySelectorAll() { return []; },
      addEventListener() {}
    };
    const window = globalThis;
    globalThis.document = document;
    globalThis.CustomEvent = function (name, init) {
      this.type = name;
      this.detail = (init || {}).detail;
    };
    globalThis.dispatchEvent = function (ev) { dispatched.push(ev); };
    globalThis.alert = function (msg) { alerted.push(msg); };

    // ==== the factory's <script>, verbatim, follows ====
  JS

  HARNESS_SCENARIOS = <<~'JS'
    // ==== scenarios ====
    function assert(cond, msg) {
      if (!cond) { console.error('FAIL: ' + msg); process.exit(1); }
    }

    // The exact sentence turf-monster's Admin::Nfl::WeeksController#reorder renders
    // beside its 422. It is quoted here on purpose: this suite exists to prove THIS
    // text reaches a human, so a paraphrase would defeat the whole file.
    const WEEK_422 = "That order does not match this week's games — reload and try again.";

    let lastRequest = null;

    function record(url, opts) {
      lastRequest = { url: url, opts: opts, body: JSON.parse(opts.body) };
    }
    function installFetch(fn) {
      lastRequest = null;
      delete globalThis.authedFetch;
      globalThis.fetch = function (url, opts) { record(url, opts); return fn(url, opts); };
    }
    // The turf-monster host defines window.authedFetch; request() must prefer it.
    function installAuthedFetch(fn) {
      lastRequest = null;
      globalThis.authedFetch = function (url, opts) { record(url, opts); return fn(url, opts); };
      globalThis.fetch = function () {
        throw new Error('authedFetch must win over fetch when the host defines it');
      };
    }
    function installNoFetch() {
      lastRequest = null;
      delete globalThis.authedFetch;
      globalThis.fetch = function () { throw new Error('no request was expected here'); };
    }

    const jsonResponse = (status, body) => ({
      ok: status >= 200 && status < 300,
      status: status,
      json: () => Promise.resolve(body)
    });
    // A refusal that rendered HTML (a proxy error page, a 500 through the rack
    // stack): resp.json() REJECTS, and the operator must still learn something.
    const unparseableResponse = (status) => ({
      ok: false,
      status: status,
      json: () => Promise.reject(new SyntaxError('Unexpected token < in JSON at position 0'))
    });

    const REORDER_URL = '/admin/nfl/weeks/2026-w3/reorder';
    function makeBoard(extra) {
      return window.studioBoard(Object.assign({ reorderUrl: REORDER_URL }, extra || {}));
    }
    // A dropzone as saveOrder reads it: zoneKey() off data-<zoneAttr>, and an
    // ordered card list off querySelectorAll(cardSelector).
    function makeZone(key, ids) {
      return {
        getAttribute(name) { return name === 'data-stage' ? key : null; },
        querySelectorAll() {
          return ids.map(function (id) {
            return { getAttribute(n) { return n === 'data-slug' ? id : null; } };
          });
        }
      };
    }
    // applyMove's zones additionally take the reverted card back.
    function makeMoveZone(key) {
      return {
        inserted: [],
        getAttribute(name) { return name === 'data-stage' ? key : null; },
        querySelectorAll() { return []; },
        querySelector() { return null; },
        insertBefore(node) { this.inserted.push(node); }
      };
    }
    function makeCard(id) {
      return {
        attrs: { 'data-slug': id, 'data-stage': 'designed' },
        getAttribute(n) { return this.attrs[n] === undefined ? null : this.attrs[n]; },
        setAttribute(n, v) { this.attrs[n] = v; },
        classList: { add() {}, remove() {} }
      };
    }

    (async function () {
      assert(typeof window.studioBoard === 'function', 'the partial must define window.studioBoard');

      // ------------------------------------------------------------------
      // 1. THE DEFECT. A 422 carrying the server's own sentence reaches the
      //    operator. `fetch` RESOLVES on 4xx, so nothing but an explicit
      //    !resp.ok check can see this — and before 0.76.3 nothing did.
      // ------------------------------------------------------------------
      {
        const board = makeBoard();
        installFetch(() => Promise.resolve(jsonResponse(422, { error: WEEK_422 })));

        const ok = await board.saveOrder(makeZone('focus', ['g1', 'g2', 'g3']));

        assert(ok === false, 'a refused save must resolve false, got ' + ok);
        assert(board.toasts.length === 1,
               'a refused save raises exactly one toast, got ' + board.toasts.length);
        assert(board.toasts[0].message === WEEK_422,
               "the operator must see the SERVER'S words, got: " + board.toasts[0].message);
        assert(board.toasts[0].type === 'error', 'the refusal toasts as an error');
        assert(board.toasts[0].visible === true, 'the toast is pushed visible');

        // ...and the POST it refused carried the DOM order under the neutral key.
        assert(lastRequest !== null, 'the reorder must actually POST');
        assert(lastRequest.url === REORDER_URL, 'the POST goes to reorderUrl');
        assert(lastRequest.opts.method === 'POST', 'reorder is a POST');
        assert(JSON.stringify(lastRequest.body.slugs) === JSON.stringify(['g1', 'g2', 'g3']),
               'the ordered ids ride under the neutral payload key, got ' + JSON.stringify(lastRequest.body));
        assert(lastRequest.body.zone === 'focus', 'the advisory zone rides along');
      }

      // ------------------------------------------------------------------
      // 2. THE NULL PATH. turf-monster's authedFetch resolves to NULL on an
      //    expired session (401) or a rate-limited tier (429). saveOrder never
      //    checked it, so a session-expired drag was lost in silence too.
      // ------------------------------------------------------------------
      {
        const board = makeBoard();
        installAuthedFetch(() => Promise.resolve(null));

        const ok = await board.saveOrder(makeZone('focus', ['g1', 'g2']));

        assert(ok === false, 'a null response must resolve false, got ' + ok);
        assert(board.toasts.length === 1,
               'a null response raises exactly one toast, got ' + board.toasts.length);
        assert(board.toasts[0].message === 'Session expired — please sign in again.',
               'a null response must name the expired session, got: ' + board.toasts[0].message);
        assert(board.toasts[0].type === 'error', 'an expired session toasts as an error');
        assert(lastRequest !== null, 'authedFetch is preferred over fetch when the host defines it');
      }

      // ------------------------------------------------------------------
      // 3. A refusal whose body is not JSON still names the status, rather
      //    than dying inside resp.json() and re-entering the silence.
      // ------------------------------------------------------------------
      {
        const board = makeBoard();
        installFetch(() => Promise.resolve(unparseableResponse(500)));

        const ok = await board.saveOrder(makeZone('focus', ['g1']));

        assert(ok === false, 'an unparseable refusal resolves false');
        assert(board.toasts.length === 1, 'an unparseable refusal still toasts');
        assert(board.toasts[0].message === 'Failed (500)',
               'an unparseable refusal falls back to the status, got: ' + board.toasts[0].message);
      }

      // ------------------------------------------------------------------
      // 4. A SAVED ORDER SAYS NOTHING. The page already shows the new order;
      //    a success toast on every drop would be noise. Silence is now
      //    meaningful precisely because failure is not silent.
      // ------------------------------------------------------------------
      {
        const board = makeBoard();
        installFetch(() => Promise.resolve(jsonResponse(200, { success: true })));

        const ok = await board.saveOrder(makeZone('focus', ['g1', 'g2']));

        assert(ok === true, 'a saved order resolves true, got ' + ok);
        assert(board.toasts.length === 0,
               'a saved order raises no toast, got ' + JSON.stringify(board.toasts));
      }

      // ------------------------------------------------------------------
      // 5. THE TOAST-LESS BOARD still surfaces it. mcritchie-studio's depth
      //    chart passes toasts: false, so toast() falls back to window.alert
      //    for errors — louder, not quieter, which is the right trade for a
      //    save the operator would otherwise believe had landed.
      // ------------------------------------------------------------------
      {
        alerted.length = 0;
        const board = makeBoard({ toasts: false });
        installFetch(() => Promise.resolve(jsonResponse(422, { error: 'Depth chart is locked' })));

        const ok = await board.saveOrder(makeZone('qb', ['11', '12']));

        assert(ok === false, 'a toast-less board still resolves false on a refusal');
        assert(board.toasts.length === 0, 'a toast-less board pushes no toast');
        assert(alerted.length === 1 && alerted[0] === 'Depth chart is locked',
               'a toast-less board alerts the refusal, got ' + JSON.stringify(alerted));
      }

      // ------------------------------------------------------------------
      // 6. The no-op saves RESOLVE rather than returning undefined, so a
      //    caller can chain on saveOrder unconditionally.
      // ------------------------------------------------------------------
      {
        installNoFetch();
        const demo = makeBoard({ demo: true });
        const demoOk = await demo.saveOrder(makeZone('focus', ['g1']));
        assert(demoOk === true, 'a demo save resolves true, got ' + demoOk);
        assert(lastRequest === null, 'a demo board sends no request');

        installNoFetch();
        const unconfigured = window.studioBoard({});
        const unconfiguredOk = await unconfigured.saveOrder(makeZone('focus', ['g1']));
        assert(unconfiguredOk === true, 'an unconfigured reorder resolves true, got ' + unconfiguredOk);
        assert(lastRequest === null, 'a board with no reorderUrl sends no request');
      }

      // ------------------------------------------------------------------
      // 7. The extension seam is UNCHANGED: the window event and the drop
      //    hook still fire, and still fire BEFORE the POST is answered, so an
      //    app's optimistic renumber is not delayed by the round trip.
      // ------------------------------------------------------------------
      {
        dispatched.length = 0;
        const hookCalls = [];
        globalThis.depthChartRenumber = (detail) => hookCalls.push(detail);
        const board = makeBoard({ onDropHook: 'depthChartRenumber' });
        installFetch(() => Promise.resolve(jsonResponse(422, { error: 'nope' })));

        await board.saveOrder(makeZone('qb', ['a', 'b']));

        assert(hookCalls.length === 1, 'onDropHook fires exactly once, got ' + hookCalls.length);
        assert(JSON.stringify(hookCalls[0].ids) === JSON.stringify(['a', 'b']),
               'onDropHook receives the ordered ids');
        const events = dispatched.filter((e) => e.type === 'studio:board-reordered');
        assert(events.length === 1, 'studio:board-reordered dispatches once, got ' + events.length);
        assert(JSON.stringify(events[0].detail.ids) === JSON.stringify(['a', 'b']),
               'the event carries the ordered ids');
      }

      // ------------------------------------------------------------------
      // 8. applyMove kept its behavior when its !resp.ok check moved to the
      //    request() seam: a refused move still toasts the server's message
      //    and still reverts the card into its source zone.
      // ------------------------------------------------------------------
      {
        const board = makeBoard({ moveUrl: '/tasks/:id.json', moveParam: { resource: 'task', attr: 'stage' } });
        const card = makeCard('alpha');
        const fromZone = makeMoveZone('designed');
        const toZone = makeMoveZone('shipped');
        installFetch(() => Promise.resolve(jsonResponse(422, { error: 'Stage transition refused' })));

        const ok = await board.applyMove(card, fromZone, toZone, 'alpha');

        assert(ok === false, 'a refused move resolves false, got ' + ok);
        assert(board.toasts.length === 1, 'a refused move raises one toast');
        assert(board.toasts[0].message === 'Stage transition refused',
               "a refused move shows the server's message, got: " + board.toasts[0].message);
        assert(board.toasts[0].type === 'error', 'a refused move toasts as an error');
        assert(fromZone.inserted.indexOf(card) !== -1, 'a refused move reverts the card to its source zone');
        assert(card.getAttribute('data-stage') === 'designed', 'a refused move does not restamp the zone');
        assert(lastRequest.opts.method === 'PATCH', 'a move is a PATCH');
      }

      // ------------------------------------------------------------------
      // 9. ...and a SUCCESSFUL move still restamps, toasts and emits.
      // ------------------------------------------------------------------
      {
        dispatched.length = 0;
        const board = makeBoard({ moveUrl: '/tasks/:id.json', moveParam: { resource: 'task', attr: 'stage' } });
        const card = makeCard('alpha');
        const fromZone = makeMoveZone('designed');
        const toZone = makeMoveZone('shipped');
        installFetch(() => Promise.resolve(jsonResponse(200, { ok: true })));

        const ok = await board.applyMove(card, fromZone, toZone, 'alpha');

        assert(ok === true, 'a successful move resolves true, got ' + ok);
        assert(card.getAttribute('data-stage') === 'shipped', 'a successful move restamps the card zone');
        assert(fromZone.inserted.length === 0, 'a successful move does not revert');
        assert(board.toasts.length === 1 && board.toasts[0].type === 'success',
               'a successful move toasts success');
        const moved = dispatched.filter((e) => e.type === 'studio:board-moved');
        assert(moved.length === 1, 'studio:board-moved dispatches once, got ' + moved.length);
      }

      console.log('ALL-BOARD-SAVE-SCENARIOS-PASS');
    })().catch((e) => { console.error('FAIL: ' + ((e && e.stack) || e)); process.exit(1); });
  JS
end
