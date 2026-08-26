# frozen_string_literal: true

require "test_helper"
require "action_view"
require "tempfile"
require "json"

# [unit] THE RETURN TRIP — the age-gate card's back link, and whether the date
# the person already entered comes back with it.
#
# WHY THIS EXECUTES INSTEAD OF GREPPING. Both halves of this bug are PROGRAM, and
# the markup is identical either way. `swap(id, {})` and `swap(id, { dobYear: … })`
# are both a swap to the same id; a factory that seeds its fields and one that
# starts blank both render three empty selects on the server, because the values
# are chosen in a browser after mount. A String assertion on the swap target — the
# obvious test to write here — passes with the defect fully intact. So the
# rendered <script> and the rendered x-data are extracted and RUN under node,
# against the same minimal Alpine stubs test/views/modal_host_store_behavior_test
# uses, and the question is asked by CALLING back() and init().
#
# THE DEFECT THIS EXISTS TO CATCH (fixed 2026-08-26). blocks/_age_gate's back()
# swapped to the birthday card with an EMPTY props object, discarding the
# dobYear/dobMonth/dobDay parts _reject had just handed across the store — and the
# factory initialised month/day/year to "" and never read them anyway. Measured in
# a browser: after "Update your Birthday" the card returned with month="", day="",
# year="" and submit correctly disabled. A mistyped year cost all three picks, on
# a card whose own header comment promised "a correction, not a restart".
#
# Both sides are asserted, and so is the seam between them: the payload back()
# actually produces is fed to the factory as the modal entry it mounts into, so a
# rename on either side of the store fails here rather than in a browser.
#
# AND THE GATE IS NOT WEAKENED. Restoring a date must restore the DATE, never the
# verdict. The last scenarios re-submit the restored under-age date and assert it
# is refused again — because "the card came back filled in" and "the card came
# back filled in and now accepts what it just refused" look identical until asked.
class BirthdayReturnTripTest < Minitest::Test
  # A missing node runtime FAILS; it must never `skip`. This file is the only
  # coverage of the return trip's program, so a skip would read as a pass on
  # exactly the behaviour it exists to observe.
  def test_node_runtime_is_available
    refute_empty node_path,
                 "node runtime NOT FOUND on PATH. The birthday return-trip suite executes " \
                 "the card's own JavaScript and is the only coverage of it — skipping would " \
                 "report green with zero coverage. Install node (mise install node@20)."
  end

  def test_the_return_trip_under_node
    out = run_harness

    assert_includes out, "ALL-RETURN-TRIP-SCENARIOS-PASS", out
  end

  # The factory's <script> and the gate card's x-data are extracted from RENDERED
  # output, not read out of the ERB source: what runs in a browser is the rendered
  # form, and the store name in both is an ERB local.
  def test_the_extracted_sources_are_the_rendered_ones
    assert_includes factory_script, "window.birthdayModal = function (opts)",
                    "the factory script must come out of the rendered partial"
    assert_includes gate_x_data, "$store.labModals.swap('birthday'",
                    "the gate's swap target and store are ERB locals — extract the RENDERED form"
  end

  private

  def node_path
    @node_path ||= `which node 2>/dev/null`.strip
  end

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end

  def factory_script
    @factory_script ||= begin
      html = view.render(partial: "studio/birthday_assets")
      script = html[%r{<script>(.*?)</script>}m, 1]
      refute_nil script, "expected studio/_birthday_assets to emit its factory <script>"
      script
    end
  end

  # The whole x-data attribute, verbatim. It is double-quoted and its body
  # deliberately contains no double quote (the card's own comment says why), so a
  # non-greedy match to the next quote is exact rather than lucky.
  def gate_x_data
    @gate_x_data ||= begin
      html = view.render(partial: "studio/modals/blocks/age_gate",
                         locals: { min_age: 21, state: "CA", watch_url: "/watch",
                                   birthday_modal_id: "birthday", modal_store: "labModals" })
      attr = html[/x-data="(.*?)"/m, 1]
      refute_nil attr, "expected the age-gate card to emit an x-data attribute"
      attr
    end
  end

  def run_harness
    node = node_path
    out = nil

    Tempfile.create(["birthday_return_trip", ".js"]) do |f|
      f.write(HARNESS_PRELUDE, factory_script,
              "\nglobalThis.GATE_X_DATA = #{gate_x_data.to_json};\n",
              HARNESS_SCENARIOS)
      f.flush
      out = `#{node} #{f.path} 2>&1`
    end

    assert $?.success?, "node harness failed:\n#{out}"
    out
  end

  # Minimal browser stubs. The factory reads window.birthdayModal, calls
  # Alpine.store(name) for the modal store and the optional session store, and
  # (outside demo mode, which none of these scenarios use) would reach document
  # for the CSRF meta tag.
  HARNESS_PRELUDE = <<~'JS'
    'use strict';
    const window = globalThis;
    const alpineStores = {};
    const Alpine = {
      store(name, def) {
        if (def === undefined) return alpineStores[name];
        alpineStores[name] = def;
      }
    };
    globalThis.Alpine = Alpine;
    globalThis.alpineStores = alpineStores;
    if (!globalThis.CustomEvent) {
      globalThis.CustomEvent = class CustomEvent { constructor(type) { this.type = type; } };
    }
    globalThis.dispatchEvent = () => {};
    globalThis.document = { querySelector: () => null };

    // ==== studio/_birthday_assets' <script>, verbatim, follows ====
  JS

  HARNESS_SCENARIOS = <<~'JS'
    // ==== scenarios ====
    function assert(cond, msg) {
      if (!cond) { console.error('FAIL: ' + msg); process.exit(1); }
    }
    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    // A modal store with just the surface these two cards touch. swap() RECORDS
    // rather than re-renders — the payload IS the thing under test.
    function fakeStore(props) {
      return {
        entry: { id: 'birthday', props: props || {} },
        swapped: null,
        closed: false,
        current() { return this.entry; },
        swap(id, p) { this.swapped = { id: id, props: p }; },
        close() { this.closed = true; }
      };
    }

    // Mount the birthday factory the way Alpine does: register the store the
    // factory will reach for, build the object, then call init() — which is
    // exactly what the x-data directive does, synchronously, at mount.
    //
    // This harness has no DOM, so it observes the component's STATE and not the
    // three <select>s. That half is the browser lane's (e2e/birthday_gate.spec.js):
    // a card whose state is perfect and whose selects read blank is a real
    // failure mode, and it is invisible from here.
    function mountBirthday(store, opts) {
      alpineStores['labModals'] = store;
      const c = window.birthdayModal(Object.assign(
        { store: 'labModals', minAge: 21, state: 'CA' }, opts || {}));
      if (c.init) c.init();
      return c;
    }

    // The gate card's x-data, evaluated with $store bound the way Alpine binds it.
    function mountGate(store) {
      return new Function('$store', 'return (' + globalThis.GATE_X_DATA + ')')({ labModals: store });
    }

    const UNDERAGE_YEAR = new Date().getFullYear() - 16;

    (async function () {
      // --- 1. back() forwards the three parts -----------------------------
      //
      // THE DEFECT, stated as an assertion. This swapped with {} and the three
      // parts died on the floor of the card that had just been handed them.
      let store = fakeStore({ minAge: 21, state: 'CA', message: 'Too young.',
                              dobYear: UNDERAGE_YEAR, dobMonth: 6, dobDay: 15 });
      let gate = mountGate(store);
      gate.back();

      assert(store.swapped, 'back() must swap');
      assert(store.swapped.id === 'birthday', 'back() swaps to the birthday card, got ' + store.swapped.id);
      assert(store.swapped.props.dobYear === UNDERAGE_YEAR, 'the YEAR rides back, got ' + store.swapped.props.dobYear);
      assert(store.swapped.props.dobMonth === 6, 'the MONTH rides back, got ' + store.swapped.props.dobMonth);
      assert(store.swapped.props.dobDay === 15, 'the DAY rides back, got ' + store.swapped.props.dobDay);

      // --- 2. and NOTHING else --------------------------------------------
      //
      // Not tidiness. `message` would reappear as an error line on a card nobody
      // has submitted yet, and `validates` is load-bearing by its ABSENCE — the
      // style guide specimen reads an absent prop as validating, so a forwarded
      // one would let the refusal pick the next card's mode. That exact hole sent
      // a return trip to the no-bar card once (style/modals/_birthday.html.erb).
      const forwarded = Object.keys(store.swapped.props).sort().join(',');
      assert(forwarded === 'dobDay,dobMonth,dobYear',
             'back() forwards ONLY the three date parts, got: ' + forwarded);
      assert(store.swapped.props.validates === undefined,
             'validates must stay absent on the return trip');
      assert(store.swapped.props.message === undefined,
             'the refusal message must not follow the person back to the ask');

      // --- 3. no date to carry ---------------------------------------------
      //
      // The gate can be opened cold (a host that opens it directly), and then
      // there is nothing to restore. It must still return, with blanks.
      store = fakeStore({ minAge: 21, state: 'CA' });
      gate = mountGate(store);
      gate.back();
      assert(store.swapped && store.swapped.id === 'birthday', 'a cold gate still returns to the ask');
      assert(store.swapped.props.dobYear === null, 'no date => an explicit null');

      // --- 4. the factory seeds its three fields ---------------------------
      //
      // The other half of the seam. back() carrying the parts changes nothing on
      // its own: the factory initialised month/day/year to "" and never read the
      // props of the entry it was mounted in.
      store = fakeStore({ dobYear: UNDERAGE_YEAR, dobMonth: 6, dobDay: 15 });
      let card = mountBirthday(store);
      assert(card.year === String(UNDERAGE_YEAR), 'year restored, got ' + JSON.stringify(card.year));
      assert(card.month === '6', 'month restored, got ' + JSON.stringify(card.month));
      assert(card.day === '15', 'day restored, got ' + JSON.stringify(card.day));

      // STRINGS, the type the person's own pick produces: the options render
      // :value="m.n", the DOM stringifies it, and x-model writes that back. A
      // Number here would be a second type living in the same field.
      assert(typeof card.month === 'string' && typeof card.day === 'string' && typeof card.year === 'string',
             'the restored parts must be strings, as a real pick is');

      // And the card is IMMEDIATELY submittable — the point of the whole fix is
      // that a mistyped year costs one scroll, not a re-entry of all three.
      assert(card.complete === true, 'a restored date is complete, so submit is enabled');
      assert(card.error === '', 'the refusal message must not come back as an error line');

      // --- 5. the SEAM: the real payload, not a hand-built one --------------
      //
      // Feed the factory exactly what back() produced. A rename on either side of
      // the store (dobYear -> dob_year, say) passes scenarios 1 and 4 separately
      // and fails HERE, which is where it should fail.
      store = fakeStore({ minAge: 21, state: 'CA', dobYear: UNDERAGE_YEAR, dobMonth: 11, dobDay: 30 });
      gate = mountGate(store);
      gate.back();
      const handoff = mountBirthday(fakeStore(store.swapped.props));
      assert(handoff.complete === true, 'the payload back() emits must be one the factory can seed from');
      assert(handoff.month === '11' && handoff.day === '30' && handoff.year === String(UNDERAGE_YEAR),
             'the seam carries all three parts intact');

      // --- 6. no date, no seeding ------------------------------------------
      card = mountBirthday(fakeStore({}));
      assert(card.month === '' && card.day === '' && card.year === '', 'a cold card still starts blank');
      assert(card.complete === false, 'and its submit stays disabled');

      // A partial date is not a date. Two parts cannot select a third.
      card = mountBirthday(fakeStore({ dobYear: UNDERAGE_YEAR, dobMonth: 6 }));
      assert(card.month === '' && card.year === '', 'a partial props bag seeds nothing');

      // --- 7. the day is clamped to the restored month ---------------------
      //
      // A real pick can never be out of range, because it came from dayOptions.
      // A hand-built props bag can (Feb 30), and a select left holding a value
      // its own options do not contain reads as complete while showing nothing —
      // it would submit a date nobody picked.
      card = mountBirthday(fakeStore({ dobYear: 2003, dobMonth: 2, dobDay: 30 }));
      assert(card.month === '2', 'the month still restores');
      assert(card.day === '', 'an impossible day lands empty, got ' + JSON.stringify(card.day));
      assert(card.complete === false, 'and the card is NOT submittable on a half-restored date');

      // The clamp is against the restored MONTH, not a fixed 31 — and Feb 29 in a
      // leap year is a real pick, so it must survive.
      card = mountBirthday(fakeStore({ dobYear: 2004, dobMonth: 2, dobDay: 29 }));
      assert(card.day === '29', 'Feb 29 of a leap year is a real pick and must restore');

      // --- 8. THE GATE IS NOT WEAKENED -------------------------------------
      //
      // Restoring the date restores the DATE, never the verdict. A card that came
      // back filled in, and a card that came back filled in and now accepts what
      // it just refused, are indistinguishable until this is asked.
      store = fakeStore({ dobYear: UNDERAGE_YEAR, dobMonth: 6, dobDay: 15 });
      card = mountBirthday(store);
      assert(card.computedAge !== null, 'the restored date still computes an age');
      assert(card.isUnderage === true, 'the restored date is still under the bar');

      // Re-submitted, it is refused AGAIN — the verdict runs on the restored date
      // exactly as it ran on the typed one. (demo resolves locally; the live path
      // posts to the app, which is and stays the authoritative check.)
      card = mountBirthday(store, { demo: true, gateId: 'age-gate' });
      card.submit();
      await sleep(600);
      assert(store.swapped && store.swapped.id === 'age-gate',
             'a restored under-age date must be REFUSED again, not accepted');
      assert(alpineStores.session === undefined || alpineStores.session.ageVerified !== true,
             'a refused restore must never flip ageVerified');

      // The control for scenario 8: the same restored-date path with a date that
      // PASSES must still verify. If restoring had broken submit outright, every
      // assertion above would still be green.
      const passing = fakeStore({ dobYear: 1990, dobMonth: 6, dobDay: 15 });
      const okCard = mountBirthday(passing, { demo: true, gateId: 'age-gate' });
      assert(okCard.isUnderage === false, 'a restored 1990 date is over the bar');
      okCard.submit();
      await sleep(600);
      assert(passing.swapped === null, 'a restored PASSING date must not open the gate');
      assert(passing.closed === true, 'it verifies and closes, like any other accepted date');

      console.log('ALL-RETURN-TRIP-SCENARIOS-PASS');
    })();
  JS
end
