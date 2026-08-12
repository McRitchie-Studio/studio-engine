# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "tempfile"

# [component] Regression guard for the /admin/style page-scoped modal store
# (dsModals) surviving Turbo Drive navigation.
#
# THE BUG (fixed 0.26.1): the dsModals + dsSolanaModal stores were registered
# ONLY inside a `document.addEventListener('alpine:init', ...)` handler in the
# page body. Alpine loads via a deferred CDN <script> in the engine head and
# fires alpine:init exactly ONCE — on the first full-document load. A Turbo Drive
# advance visit (the admin sidebar "Design System" link) swaps <body> without
# reloading that head script, so alpine:init never fires again; the body script
# re-runs but only re-attaches a listener that will not fire. Result: on a Turbo
# visit $store.dsModals was undefined, every specimen card's @click / :style /
# <template x-if> that reads it threw, modals would not open, and the throwing
# :style wiped each card's static --studio-team-glow-opacity: 0 so every glow lit.
#
# We do NOT assert on the emitted source string — a string match is structurally
# blind to the actual failure (an alpine:init-only registration and a dual-guard
# both contain "dsModals"). Instead the rendered <script> is EXECUTED under node
# with minimal window/document/Alpine stubs, in BOTH nav paths, and the store's
# registration is asserted by observing whether it lands — the property the bug
# violated. Revert to alpine:init-only and the Turbo scenario fails loudly.
class DesignSystemModalsTurboRegistrationTest < ActiveSupport::TestCase
  # A missing node runtime FAILS here; it must never `skip`. This is the only
  # coverage that observes the store's real registration behavior, so a skip would
  # read as a pass on exactly the mechanism this test exists to protect. CI
  # installs node in the engine-suite lane (.github/workflows/engine-ci.yml);
  # locally it comes from mise (`mise install node@20`).
  def test_node_runtime_is_available
    refute_empty node_path,
                 "node runtime NOT FOUND on PATH. The dsModals Turbo-registration suite " \
                 "executes the store registration for real; skipping it would report green " \
                 "with zero coverage. Install node (mise install node@20) and re-run."
  end

  def test_dsmodals_registers_on_turbo_visit_and_on_first_load
    node = node_path

    script = ds_modals_script
    refute_nil script, "expected /admin/style to emit the dsModals registration <script>"
    assert_includes script, "registerDsModals",
      "the dsModals store must be registered through a named function the dual-guard can call " \
      "directly on a Turbo visit (not an alpine:init-only callback)"

    out = nil
    Tempfile.create(["ds_modals_turbo_harness", ".js"]) do |f|
      f.write(HARNESS_PRELUDE, "\nfunction runScript() {\n", script, "\n}\n", HARNESS_SCENARIOS)
      f.flush
      out = `#{node} #{f.path} 2>&1`
    end

    assert $?.success?, "node harness failed:\n#{out}"
    assert_includes out, "ALL-DSMODALS-TURBO-SCENARIOS-PASS", out
  end

  private

  def node_path
    @node_path ||= `which node 2>/dev/null`.strip
  end

  # Render the real /admin/style page (same path style_page_test.rb exercises)
  # and extract the ONE <script> block that registers the page-scoped dsModals
  # store — identified by the registration function, not a bare id match.
  def ds_modals_script
    # The style page's at-format specimens call Studio::AtTimeHelper. A host gets
    # every engine helper for free (no isolate_namespace); a bare test view does not.
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::AtTimeHelper)
    html = view.render(template: "style/index")
    html.scan(%r{<script[^>]*>(.*?)</script>}m)
        .map(&:first)
        .find { |s| s.include?("registerDsModals") && s.include?("Alpine.store('dsModals'") }
  end

  # Minimal browser stubs. The dsModals script assigns the credential stubs onto
  # window, defines registerDsModals(), then dual-guards its invocation on
  # window.Alpine. document.addEventListener queues listeners so a first-load
  # alpine:init can be fired on demand; Alpine.store(name[, def]) is the single
  # global registry both a "started" and a "late" Alpine share.
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
    function makeAlpine() {
      return {
        store(name, def) {
          if (def === undefined) return alpineStores[name];
          alpineStores[name] = def;
        }
      };
    }
    // ==== the page's dsModals <script>, wrapped as runScript(), follows ====
  JS

  HARNESS_SCENARIOS = <<~'JS'
    // ==== scenarios ====
    function assert(cond, msg) {
      if (!cond) { console.error('FAIL: ' + msg); process.exit(1); }
    }
    function reset() {
      for (const k in pendingEvents) delete pendingEvents[k];
      for (const k in alpineStores) delete alpineStores[k];
      globalThis.Alpine = undefined;
    }
    function fire(ev) { (pendingEvents[ev] || []).slice().forEach((fn) => fn()); }

    // Scenario A — Turbo Drive advance visit: Alpine has ALREADY started before
    // the body script re-runs. The store MUST register immediately, without any
    // alpine:init (which never fires again on a Turbo visit). This is the exact
    // property the bug violated.
    reset();
    globalThis.Alpine = makeAlpine();
    runScript();
    assert(alpineStores['dsModals'],
      'TURBO: dsModals must register immediately when Alpine is already started (no alpine:init)');
    assert(alpineStores['dsSolanaModal'],
      'TURBO: dsSolanaModal must register immediately alongside dsModals');
    assert((pendingEvents['alpine:init'] || []).length === 0,
      'TURBO: registration must NOT depend on an alpine:init listener when Alpine is already up');

    // Scenario B — first full-document load: Alpine is not booted when the body
    // script runs, so registration correctly defers to alpine:init.
    reset();
    runScript();
    assert(!alpineStores['dsModals'],
      'FIRST-LOAD: dsModals must not exist before Alpine boots');
    assert((pendingEvents['alpine:init'] || []).length > 0,
      'FIRST-LOAD: registration must defer to alpine:init when Alpine has not started');
    globalThis.Alpine = makeAlpine();
    fire('alpine:init');
    assert(alpineStores['dsModals'],
      'FIRST-LOAD: dsModals registers when alpine:init fires');
    assert(alpineStores['dsSolanaModal'],
      'FIRST-LOAD: dsSolanaModal registers when alpine:init fires');

    // Scenario C — idempotent: a second render (another Turbo visit) plus a later
    // alpine:init must keep the ORIGINAL store instance (the in-function guard
    // `if (Alpine.store('dsModals')) return;` short-circuits), never throw or
    // clobber live modal state.
    reset();
    globalThis.Alpine = makeAlpine();
    runScript();
    const firstRef = alpineStores['dsModals'];
    runScript();
    fire('alpine:init');
    assert(alpineStores['dsModals'] === firstRef,
      'IDEMPOTENT: re-registration keeps the original store (guard returns early)');

    console.log('ALL-DSMODALS-TURBO-SCENARIOS-PASS');
  JS
end
