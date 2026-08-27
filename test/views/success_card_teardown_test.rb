# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "tempfile"
require "cgi"

# [unit] blocks/_success_card must CANCEL its timers when the card unmounts.
#
# THE DEFECT THIS EXISTS TO CATCH (found 2026-08-27 by Carl, reviewing turf PR
# 448). startCountdown() opened a setInterval ending in
# `window.location.href = url`, and the x-data defined NO destroy(). Because
# blocks/_entry_confirmed hard-codes cta_drain: true, EVERY render carried a
# live timer with no opt-out. Dismiss the card, press Escape, or click the
# backdrop inside the 5-second window and the modal closed — then the browser
# navigated to the contest lobby anyway.
#
# WHY THIS IS RUN UNDER NODE RATHER THAN ASSERTED AS MARKUP. The obvious test —
# assert the rendered x-data contains "destroy()" — passes against a destroy()
# that clears the WRONG field, clears nothing, or is never reached. The bug is
# about a timer still firing after teardown, so the timers are stubbed, the
# card's own program is executed, destroy() is CALLED, and the clock is then
# advanced past the redirect. The question asked is the user's question: after
# dismissing, does the browser navigate?
#
# turf-monster's now-deleted fork drove its redirect through
# blocks/_cta_redirect, whose destroy() at :46-48 cleared it — so the fork was
# CORRECT here where the engine was not, and adopting the engine card without
# this fix traded a working teardown for a leak.
class SuccessCardTeardownTest < Minitest::Test
  # A missing node runtime FAILS; it must never `skip`. This file is the only
  # coverage that executes the card's teardown, so a skip would report green on
  # exactly the behaviour it exists to observe.
  def test_node_runtime_is_available
    refute_empty node_path,
                 "node runtime NOT FOUND on PATH. This suite executes the success card's " \
                 "own JavaScript and is the only coverage of its teardown — skipping would " \
                 "report green with zero coverage. Install node (mise install node@20)."
  end

  def test_destroy_cancels_the_redirect_and_the_browser_never_navigates
    out = run_harness

    assert_includes out, "REDIRECT-CANCELLED-ON-DESTROY", out
    assert_includes out, "NO-NAVIGATION-AFTER-DESTROY", out
  end

  def test_destroy_cancels_the_confetti_timer
    out = run_harness

    assert_includes out, "CONFETTI-CANCELLED-ON-DESTROY", out
  end

  def test_a_card_left_open_still_redirects
    out = run_harness

    assert_includes out, "STILL-REDIRECTS-WHEN-NOT-DESTROYED", out
  end

  # Guard-the-guard: the harness must be capable of FAILING. If the card ever
  # stops emitting an x-data with a destroy(), or the extraction silently yields
  # an empty program, every assertion above would pass vacuously against a
  # no-op. Assert the extracted program carries the two clears by name.
  def test_the_extracted_program_is_the_real_one
    prog = card_x_data

    assert_includes prog, "destroy()",
                    "the rendered success card emitted no destroy() — the harness would " \
                    "have executed a program with nothing to tear down"
    assert_includes prog, "clearInterval", prog
    assert_includes prog, "clearTimeout", prog
  end

  private

  def node_path
    @node_path ||= `which node 2>/dev/null`.strip
  end

  def view
    @view ||= ActionController::Base.new.view_context
  end

  # The card's x-data, rendered and HTML-unescaped. The attribute carries `<=`
  # as `&lt;=`, so a raw slice would hand node a syntax error rather than the
  # card's program.
  def card_x_data
    @card_x_data ||= begin
      html = view.render(partial: "studio/modals/blocks/success_card",
                         locals: { title: "Good Luck",
                                   auto_redirect_url_key: "'/contests/demo'",
                                   auto_redirect_seconds: 5,
                                   cta_drain: true,
                                   confetti: true,
                                   cta_label: "View contest",
                                   cta_href_key: "'/contests/demo'" })
      attr = html[/x-data="(.*?)"/m, 1]
      refute_nil attr, "expected the success card to emit an x-data attribute"
      CGI.unescapeHTML(attr)
    end
  end

  HARNESS = <<~'JS'
    'use strict';
    // ---- fake clock + a location we can observe -----------------------------
    let now = 0;
    let seq = 0;
    const live = new Map();            // handle -> {due, fn, every}
    globalThis.setInterval = (fn, ms) => { const h = ++seq; live.set(h, { due: now + ms, fn, every: ms }); return h; };
    globalThis.setTimeout  = (fn, ms) => { const h = ++seq; live.set(h, { due: now + ms, fn, every: null }); return h; };
    globalThis.clearInterval = (h) => { live.delete(h); };
    globalThis.clearTimeout  = (h) => { live.delete(h); };
    function advance(ms) {
      const end = now + ms;
      let guard = 0;
      while (guard++ < 10000) {
        let next = null;
        for (const [h, t] of live) if (t.due <= end && (next === null || t.due < live.get(next).due)) next = h;
        if (next === null) break;
        const t = live.get(next);
        now = t.due;
        if (t.every === null) live.delete(next); else t.due = now + t.every;
        t.fn();
      }
      now = end;
    }

    let navigatedTo = null;
    globalThis.window = globalThis;
    globalThis.location = { set href(u) { navigatedTo = u; }, get href() { return navigatedTo; } };
    let confettiFired = 0;
    globalThis.fireSuccessConfetti = () => { confettiFired++; };

    function mount() { return eval('(' + globalThis.CARD_X_DATA + ')'); }
    function reset() { now = 0; seq = 0; live.clear(); navigatedTo = null; confettiFired = 0; }

    function assert(cond, tag, detail) {
      if (!cond) { console.log('FAIL ' + tag + (detail ? ' :: ' + detail : '')); process.exit(1); }
      console.log(tag);
    }

    // 1. destroy() cancels the redirect, and nothing navigates afterwards.
    reset();
    let card = mount();
    card.startCountdown('/contests/demo');
    advance(2000);                       // two ticks in, still counting
    assert(live.size > 0, 'PRECONDITION-TIMER-LIVE', 'startCountdown registered no timer');
    if (typeof card.destroy !== 'function') { console.log('FAIL NO-DESTROY :: the card defines no destroy()'); process.exit(1); }
    card.destroy();
    assert(card._redirectTimer === null, 'REDIRECT-CANCELLED-ON-DESTROY', '_redirectTimer was ' + card._redirectTimer);
    advance(60000);                      // long past the 5s redirect
    assert(navigatedTo === null, 'NO-NAVIGATION-AFTER-DESTROY', 'navigated to ' + navigatedTo);

    // 2. destroy() cancels the confetti timer too.
    reset();
    card = mount();
    card.fireConfetti();
    card.destroy();
    advance(60000);
    assert(confettiFired === 0, 'CONFETTI-CANCELLED-ON-DESTROY', 'confetti fired ' + confettiFired + ' time(s)');

    // 3. THE CONTROL. A card left open must STILL redirect — a destroy() that
    //    cancelled unconditionally would pass every assertion above while
    //    deleting the feature.
    reset();
    card = mount();
    card.startCountdown('/contests/demo');
    advance(60000);
    assert(navigatedTo === '/contests/demo', 'STILL-REDIRECTS-WHEN-NOT-DESTROYED', 'navigated to ' + navigatedTo);

    console.log('ALL-TEARDOWN-SCENARIOS-PASS');
  JS

  def run_harness
    @run_harness ||= begin
      node = node_path
      out = nil
      Tempfile.create(["success_card_teardown", ".js"]) do |f|
        f.write("globalThis.CARD_X_DATA = #{card_x_data.to_json};\n", HARNESS)
        f.flush
        out = `#{node} #{f.path} 2>&1`
      end
      assert $?.success?, "node harness failed:\n#{out}"
      out
    end
  end
end
