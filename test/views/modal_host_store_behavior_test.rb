# frozen_string_literal: true

require "test_helper"
require "action_view"
require "tempfile"

# Executes the modal host's Alpine store FOR REAL. The other host tests
# assert on the emitted source; review proved that is structurally blind to
# resolution bugs (cardClasses() clobbered the registry 'slide' classes while
# every string assertion stayed green). Here the rendered partial's <script>
# is extracted and run under node with minimal window/document/Alpine stubs,
# and the store's behavior — cardClasses() resolution, registry merge,
# animated close timing, swap races, late registry replacement — is asserted
# by CALLING it, not by grepping it.
class ModalHostStoreBehaviorTest < Minitest::Test
  # A missing node runtime FAILS here; it must never `skip`. This is the only
  # test that observes the store's real resolution behavior, so a skip would
  # read as a pass on exactly the host where the coverage is absent — the
  # "green by not running" shape this suite exists to catch. CI installs node
  # in the engine-suite lane (.github/workflows/engine-ci.yml); locally it
  # comes from mise (`mise install node@20`).
  def test_node_runtime_is_available
    refute_empty node_path,
                 "node runtime NOT FOUND on PATH. The modal-host store behavior suite " \
                 "executes the store for real and is the only coverage of cardClasses() " \
                 "resolution — skipping it would report green with zero coverage. " \
                 "Install node (mise install node@20) and re-run."
  end

  def test_store_behavior_under_node
    node = node_path

    html = ActionView::Base.with_empty_template_cache
                           .with_view_paths(["app/views"])
                           .render(partial: "studio/modals/host")
    script = html[%r{<script>(.*?)</script>}m, 1]
    refute_nil script, "expected the host to emit its store <script>"

    out = nil
    Tempfile.create(["modal_host_harness", ".js"]) do |f|
      f.write(HARNESS_PRELUDE, script, HARNESS_SCENARIOS)
      f.flush
      out = `#{node} #{f.path} 2>&1`
    end

    assert $?.success?, "node harness failed:\n#{out}"
    assert_includes out, "ALL-MODAL-STORE-SCENARIOS-PASS", out
  end

  # --- isLive(): the lifecycle matrix -----------------------------------
  #
  # isLive(id) answers "is a card with this id up, and not on its way out"
  # — the question isOpen(id) cannot answer, because a closing entry stays
  # on the stack for the whole exit animation. Both are executed for real
  # here; a string assertion cannot tell the two apart at all.
  #
  # Every lifecycle flag these scenarios care about is set SYNCHRONOUSLY by
  # the call that causes it (close() flips _closing before it returns,
  # advance() flips _swappingOut before it returns), so the assertions run
  # immediately after the call rather than sampling on a timer. That is
  # deliberate: a poll cannot be trusted to observe a transient, and a
  # timing guess against a timing bug is the same bug with a smaller
  # window. The only sleeps below wait for a SETTLED end state (the splice).

  def test_is_live_lifecycle_matrix_on_the_shared_host
    out = run_is_live_harness(host_script, "modals")

    assert_includes out, "ALL-ISLIVE-SCENARIOS-PASS", out
  end

  # The page-scoped host ships the same primitive on its own store, so it
  # gets the same matrix. Without this the scoped copy would be a shipped
  # code path with zero observed behavior.
  def test_is_live_lifecycle_matrix_on_the_scoped_host
    out = run_is_live_harness(scoped_host_script, "pageModals")

    assert_includes out, "ALL-ISLIVE-SCENARIOS-PASS", out
  end

  def node_path
    @node_path ||= `which node 2>/dev/null`.strip
  end

  # Minimal browser stubs. The host script registers listeners on document
  # (alpine:init, turbo:before-cache) and window (pageshow), reads/writes
  # window.ModalAnimations / window.StudioModals / window.Alpine, and touches
  # document.body.classList in _sync(). A consumer registry entry is
  # PRE-registered (enter.wobble) to exercise the merge path.
  HARNESS_PRELUDE = <<~'JS'
    'use strict';
    const pendingEvents = {};
    const document = {
      addEventListener(ev, fn) { (pendingEvents[ev] = pendingEvents[ev] || []).push(fn); },
      body: { classList: { add() {}, remove() {} } }
    };
    const window = globalThis;
    globalThis.addEventListener = () => {};
    const alpineStores = {};
    const Alpine = {
      store(name, def) {
        if (def === undefined) return alpineStores[name];
        alpineStores[name] = def;
      }
    };
    globalThis.Alpine = Alpine;

    // Consumer pre-registration BEFORE the host script runs — must merge
    // over the defaults, not replace them.
    globalThis.ModalAnimations = { enter: { wobble: { cls: 'custom-wobble', ms: 90 } } };

    // ==== the host's <script>, verbatim, follows ====
  JS

  HARNESS_SCENARIOS = <<~'JS'
    // ==== scenarios ====
    function assert(cond, msg) {
      if (!cond) { console.error('FAIL: ' + msg); process.exit(1); }
    }
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    (async function () {
      (pendingEvents['alpine:init'] || []).forEach((fn) => fn());
      const store = alpineStores['modals'];
      assert(store, 'alpine:init must register the modals store');

      // 1. Registry merge: consumer wobble present AND defaults preserved.
      const reg = globalThis.ModalAnimations;
      assert(reg.enter.wobble && reg.enter.wobble.cls === 'custom-wobble', 'consumer enter.wobble kept');
      assert(reg.enter.pop && reg.enter.shake && reg.enter.slide, 'default enter keys preserved');
      assert(reg.exit.pop && reg.exit.slide, 'default exit keys preserved');

      // 2. Default mount resolves through the registry.
      store.open('plain');
      assert(store.cardClasses()['modal-card-mount'] === true, 'default mount class');
      assert(!store.cardClasses()['modal-card-swap-in'], 'no swap-in on plain mount');
      store.closeAll();

      // 3. BLOCKER: enterAnim slide resolves to a truthy class through
      // cardClasses() even though it names a fixed swap class.
      store.open('slide-in', { enterAnim: 'slide' });
      assert(store.cardClasses()['modal-card-swap-in'] === true,
             "enterAnim:'slide' must yield modal-card-swap-in (was clobbered to false)");
      store.closeAll();

      // 4. Consumer-registered animation resolves.
      store.open('wob', { enterAnim: 'wobble' });
      assert(store.cardClasses()['custom-wobble'] === true, 'custom registered enter animation resolves');
      store.closeAll();

      // 5. BLOCKER: exitAnim slide through close() — class present while
      // closing, splice waits the registry duration.
      store.open('slide-out', { exitAnim: 'slide' });
      store.close();
      assert(store.cardClasses()['modal-card-swap-out'] === true,
             "exitAnim:'slide' must yield modal-card-swap-out during close (was clobbered => frozen card)");
      assert(!store.cardClasses()['modal-card-unmount'], 'default exit class must not double up');
      assert(store.stack.length === 1, 'entry stays on stack while the exit plays');
      await sleep(320);
      assert(store.stack.length === 0, 'entry spliced after the exit duration');

      // 6. Default close animates then splices.
      store.open('bye');
      store.close();
      assert(store.cardClasses()['modal-card-unmount'] === true, 'default exit class while closing');
      await sleep(320);
      assert(store.stack.length === 0, 'default close splices');

      // 7. Two swap() calls within CLOSE_ANIM_MS: the stale phase-2
      // replacement is DROPPED, not resurrected.
      store.open('A');
      store.swap('B');
      store.swap('C');
      await sleep(700);
      assert(store.stack.length === 1, 'double swap leaves ONE entry, got ' + store.stack.length);
      assert(store.stack[0].id === 'C', 'the LAST swap wins, got ' + store.stack[0].id);
      store.closeAll();

      // 8. Documented behavioral delta: double close() inside the animation
      // window pops ONE stacked entry, not two.
      store.open('base');
      store.open('top');
      store.close();
      store.close();
      await sleep(400);
      assert(store.stack.length === 1 && store.stack[0].id === 'base',
             'double close pops one entry (documented delta)');
      store.closeAll();

      // 9. Late FULL replacement of the registry (importmap module case):
      // close() must not throw, falling back to the built-in pop.
      globalThis.ModalAnimations = {};
      store.open('late');
      assert(store.cardClasses()['modal-card-mount'] === true, 'gutted registry falls back to pop on enter');
      let threw = false;
      try { store.close(); } catch (e) { threw = true; }
      assert(!threw, 'close() must not throw when the registry was replaced');
      assert(store.cardClasses()['modal-card-unmount'] === true, 'gutted registry falls back to pop on exit');
      await sleep(320);
      assert(store.stack.length === 0, 'fallback close still splices');

      console.log('ALL-MODAL-STORE-SCENARIOS-PASS');
    })().catch((e) => { console.error('FAIL: ' + (e && e.stack || e)); process.exit(1); });
  JS

  # --- isLive harness ----------------------------------------------------

  # Same stub shape as HARNESS_PRELUDE, plus classList.toggle (the scoped
  # host's _sync uses toggle where the shared host uses add/remove) and the
  # store name under test. __STORE_NAME__ is substituted per host.
  IS_LIVE_PRELUDE = <<~'JS'
    'use strict';
    const pendingEvents = {};
    const document = {
      addEventListener(ev, fn) { (pendingEvents[ev] = pendingEvents[ev] || []).push(fn); },
      body: { classList: { add() {}, remove() {}, toggle() {} } }
    };
    const window = globalThis;
    globalThis.addEventListener = () => {};
    const alpineStores = {};
    const Alpine = {
      store(name, def) {
        if (def === undefined) return alpineStores[name];
        alpineStores[name] = def;
      }
    };
    globalThis.Alpine = Alpine;
    const STORE_NAME = '__STORE_NAME__';

    // ==== the partial's <script>, verbatim, follows ====
  JS

  # The lifecycle matrix. Runs against BOTH hosts; the one scenario that
  # needs advance() adapts where the scoped host does not ship it.
  IS_LIVE_SCENARIOS = <<~'JS'
    // ==== scenarios ====
    function assert(cond, msg) {
      if (!cond) { console.error('FAIL: ' + msg); process.exit(1); }
    }
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    (async function () {
      // The shared host registers on alpine:init; the scoped host registers
      // immediately because window.Alpine is already set. Cover both.
      (pendingEvents['alpine:init'] || []).forEach((fn) => fn());
      const store = alpineStores[STORE_NAME];
      assert(store, 'store ' + STORE_NAME + ' must be registered');
      assert(typeof store.isLive === 'function', 'store must expose isLive()');

      // --- STATE 1: ABSENT --------------------------------------------
      assert(store.isLive('ghost') === false, 'absent card is not live');
      assert(store.isOpen('ghost') === false, 'absent card is not open');

      // --- STATE 2: OPEN ----------------------------------------------
      store.open('plain');
      assert(store.isLive('plain') === true, 'open card is live');
      assert(store.isOpen('plain') === true, 'open card is open');
      assert(store.isLive('other') === false, 'isLive matches on id, not on any card being up');
      store.closeAll();

      // --- STATE 3: CLOSING -------------------------------------------
      // close() flips _closing synchronously and splices only after the
      // exit animation. Asserted on the very next line — no timer — so a
      // regression cannot hide inside a sampling interval.
      store.open('leaving');
      store.close();
      assert(store.stack.length === 1, 'closing card is still ON the stack (precondition)');
      assert(store.current()._closing === true, 'close() flips _closing synchronously (precondition)');
      assert(store.isLive('leaving') === false, 'CLOSING card must NOT be live');
      // The existing isOpen contract: unchanged, still true while closing.
      assert(store.isOpen('leaving') === true,
             'isOpen must STILL report a closing card as open — that contract predates isLive');
      await sleep(400);

      // --- STATE 4: SPLICED (settled end state, safe to await) --------
      assert(store.isOpen('leaving') === false, 'spliced card is not open');
      assert(store.isLive('leaving') === false, 'spliced card is not live');

      // --- STATE 5: _swappingOut WITHOUT _closing must stay LIVE ------
      // The load-bearing asymmetry. advance() slides the SAME card between
      // steps of its own flow: it sets _swappingOut and nothing else, and
      // the card is still up. Treating _swappingOut as "leaving" makes an
      // in-flow hand-off look to a caller like a dismissal.
      store.open('wizard');
      if (typeof store.advance === 'function') {
        store.advance({ step: 'two' });
      } else {
        // The scoped host ships no advance(); set the flag the same way
        // advance() would, so the invariant is pinned on this host too.
        store.current()._swappingOut = true;
      }
      assert(store.current()._swappingOut === true, '_swappingOut is set (precondition)');
      assert(!store.current()._closing, '_closing must NOT be set by an in-flow advance (precondition)');
      assert(store.isLive('wizard') === true,
             'a _swappingOut card with no _closing is MID-ADVANCE and must stay LIVE');
      assert(store.isOpen('wizard') === true, 'mid-advance card is open');
      await sleep(500);
      store.closeAll();

      // --- STATE 6: the swap() LEAVING entry is not live ---------------
      // The two hosts swap differently, and the test says so rather than
      // assuming: the shared host runs an animated slide, so the outgoing
      // entry holds the slot for CLOSE_ANIM_MS carrying BOTH _swappingOut
      // AND _closing; the scoped host replaces the top entry outright.
      store.open('first');
      store.swap('second');
      if (store.current().id === 'first') {
        assert(store.current()._swappingOut === true && store.current()._closing === true,
               'animated swap sets BOTH flags on the leaving entry (precondition)');
        assert(store.isLive('first') === false,
               'the card being SWAPPED AWAY must not be live — a different card is taking the screen');
        await sleep(600);
      }
      assert(store.isLive('second') === true, 'the card swapped IN is live once it lands');
      assert(store.isLive('first') === false, 'the swapped-away card is not live once the swap lands');
      store.closeAll();

      // --- Array form: "is any card of this flow still up?" ------------
      store.open('step-a');
      assert(store.isLive(['step-a', 'step-b']) === true, 'array form is true when ANY id is live');
      assert(store.isLive(['step-b', 'step-c']) === false, 'array form is false when NO id is live');
      store.close();
      assert(store.isLive(['step-a', 'step-b']) === false,
             'array form respects _closing exactly as the single-id form does');
      await sleep(400);
      store.closeAll();

      // --- Stacked: a closing card on top of a live one ----------------
      // The scan must not stop at the top entry.
      store.open('base');
      store.open('top');
      store.close();
      assert(store.isLive('top') === false, 'closing top card is not live');
      assert(store.isLive('base') === true, 'the live card UNDER a closing one is still live');
      await sleep(400);
      store.closeAll();

      console.log('ALL-ISLIVE-SCENARIOS-PASS');
    })().catch((e) => { console.error('FAIL: ' + (e && e.stack || e)); process.exit(1); });
  JS

  private

  def host_script
    extract_script(render_partial("studio/modals/host"))
  end

  def scoped_host_script
    extract_script(render_partial("studio/modals/scoped_host", store: "pageModals"))
  end

  def render_partial(partial, locals = {})
    ActionView::Base.with_empty_template_cache
                    .with_view_paths(["app/views"])
                    .render(partial: partial, locals: locals)
  end

  # Both partials keep their store in the FIRST <script> block on purpose
  # (the shared host carries a comment saying so) — this non-greedy match is
  # what depends on it.
  def extract_script(html)
    script = html[%r{<script>(.*?)</script>}m, 1]
    refute_nil script, "expected the partial to emit its store <script>"
    script
  end

  def run_is_live_harness(script, store_name)
    node = node_path
    out = nil
    Tempfile.create(["modal_is_live_harness", ".js"]) do |f|
      f.write(IS_LIVE_PRELUDE.sub("__STORE_NAME__", store_name), script, IS_LIVE_SCENARIOS)
      f.flush
      out = `#{node} #{f.path} 2>&1`
    end
    assert $?.success?, "node harness failed for store #{store_name}:\n#{out}"
    out
  end
end
