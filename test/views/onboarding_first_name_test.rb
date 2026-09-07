# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [component] The shared first-name onboarding step, ported from turf-monster so
# McRitchie Studio can ask the same question.
#
# What this primitive is, and is NOT:
#   * It owns ONE step. The host owns the SEQUENCE — turf walks welcome → first
#     name → age → wallet; a hub app may ask nothing else. So the partial never
#     opens another modal: it dispatches its done_event with the steps the SERVER
#     said remain and closes.
#   * Every endpoint and label is a LOCAL with a default, so a host that mounts
#     it under different routes does not fork the partial.
class OnboardingFirstNameTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  # The DEFAULT card exactly as gem 0.70.0 emitted it, captured from that
  # release. It is what McRitchie Studio renders today, so it is the pin: every
  # later mode has to leave it alone.
  GOLDEN_0_70_0 = File.read(
    File.join(ENGINE_ROOT, "test/views/fixtures/onboarding_first_name/default_0_70_0.html")
  )

  # Every byte 0.71 moves in that default card — and there may be no others.
  # Written as (what it says NOW) => (what 0.70.0 said) so the test can rewind
  # the render and compare the rest. A change that moves the default further has
  # to be ADDED here deliberately, which is the point: the consumer's listener
  # lives on the other side of these four lines.
  OUTCOME_DELTAS = {
    "finish(next, saved) {" => "finish(next) {",
    "{ detail: { next: next, saved: !!saved } }" => "{ detail: { next: next } }",
    "this.finish(data.next || [], true);" => "this.finish(data.next || []);",
    "this.finish((data && data.next) || [], false);" => "this.finish((data && data.next) || []);"
  }.freeze

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
  end

  def render_first_name(**locals)
    view.render(partial: "studio/modals/onboarding/first_name", locals: locals)
  end

  def doc(**locals)
    Nokogiri::HTML::DocumentFragment.parse(render_first_name(**locals))
  end

  # --- The single-root + quoting contract -------------------------------------

  test "renders exactly ONE root element" do
    # The modal host clones this from a <template x-if>; Alpine silently mounts
    # NOTHING when the template's content has multiple roots.
    frag = doc
    roots = frag.children.reject { |n| n.text? && n.text.strip.empty? }
    assert_equal 1, roots.size, "expected a single root, got: #{roots.map(&:name).inspect}"
  end

  test "the x-data attribute contains no double quotes" do
    # A double quote inside the double-quoted x-data closes it early and the
    # component mounts as a SILENT no-op — the markup still renders, so every
    # string assertion below would still pass while the modal is dead in a
    # browser. This exact bug has bitten twice in turf (PR #30, then the wallet
    # modal), which is why the port carries the guard with it.
    #
    # Read the RAW markup, NEVER Nokogiri's parsed attribute. An HTML parser
    # TERMINATES a double-quoted value at the first unescaped `"`, so the parsed
    # string can never contain one — `at_css("[x-data]")["x-data"]` passes on the
    # exact input this test exists to catch (mutation-checked in review, 2026-08-13:
    # a literal quote inside x-data left all 11 tests green). The closing `"` is
    # pinned to the newline + `class=` that really ends the attribute, which is
    # what makes a stray quote land INSIDE the captured span. Same shape as turf's
    # test/controllers/onboarding_gallery_test.rb, the guard this port came from.
    x_data = render_first_name[/<div x-data="(.*?)"\s*\n\s*class=/m, 1]
    assert x_data.present?, "could not locate the x-data attribute — did the root element change?"
    assert_not_includes x_data, '"',
                        "a double quote inside x-data kills the component in the browser"
  end

  # --- Host configurability ---------------------------------------------------

  test "defaults to the conventional onboarding endpoints" do
    html = render_first_name
    assert_includes html, "/onboarding/first_name"
    assert_includes html, "/onboarding/skip_first_name"
  end

  test "a host can mount it under its own routes without forking the partial" do
    html = render_first_name(submit_path: "/profile/name", skip_path: "/profile/name/skip")
    assert_includes html, "/profile/name"
    assert_includes html, "/profile/name/skip"
    assert_not_includes html, "/onboarding/first_name"
  end

  test "a host can retarget the modal store and the done event" do
    # The living style guide mounts a page-scoped host (dsModals) rather than the
    # app-level one, so a hard-coded store name would make it unpreviewable.
    html = render_first_name(modal_store: "dsModals", done_event: "ds-step-done")
    assert_includes html, "$store.dsModals"
    assert_includes html, "ds-step-done"
    assert_not_includes html, "$store.modals."
  end

  # THE BROWSER BOUND MUST BE THE SERVER BOUND. This default was a LITERAL 40 —
  # a third copy of the PER-FIELD cap, sitting on the one input that receives a
  # whole name. It is why "Bartholomew Fitzwilliam Montgomery-Smythe" could not
  # be typed here in the first place, and why nothing went red when the endpoint
  # measured the same answer with the same wrong number.
  test "the input's maxlength defaults to the whole-answer cap, not the per-field one" do
    assert_equal Studio::FULL_NAME_MAX_LENGTH.to_s, doc.at_css("input")["maxlength"]

    # THE CONTROL. The assertion above is only meaningful while the two caps are
    # different numbers; if they were ever collapsed it would pass on either.
    refute_equal Studio::FIRST_NAME_MAX_LENGTH, Studio::FULL_NAME_MAX_LENGTH,
                 "a whole answer and one field are two questions and two constants"
  end

  test "copy and field bounds are host-overridable" do
    html = render_first_name(heading: "Your name?", subtext: "For your receipts.",
                             placeholder: "Sam", max_length: 12)
    assert_includes html, "Your name?"
    assert_includes html, "For your receipts."
    assert_equal "Sam", doc(placeholder: "Sam").at_css("input")["placeholder"]
    assert_equal "12", doc(max_length: 12).at_css("input")["maxlength"]
  end

  test "the progress pill renders only when a host asks for it" do
    assert_nil doc.at_css(".progress-pill, [data-progress-pill]"),
               "no pill unless the host passes one" if doc.at_css("[data-progress-pill]")
    with_pill = render_first_name(progress: [2, 3])
    # The shared block renders segments; assert it appeared at all.
    assert_operator with_pill.length, :>, render_first_name.length,
                    "passing progress: should render additional markup"
  end

  # --- The behaviours the step must always have -------------------------------

  test "BOTH skip affordances are present and both call skip()" do
    # The × must SKIP, not merely close: a close that abandons the chain silently
    # is how a host ends up with a step nobody can answer again.
    html = render_first_name
    # Asserted against the RAW markup, not parsed attributes: Nokogiri's HTML
    # parser drops Alpine's `@click` (not a legal HTML attribute-name start), so
    # a node["@click"] read returns nil and the assertion would fail on the
    # parser rather than on the component.
    assert_includes html, "Skip for now"
    assert_includes html, %(aria-label="Skip")
    assert_equal 2, html.scan(%(@click="skip()")).size,
                 "both the link and the × must call skip(), not close"
  end

  test "the field is focused on open" do
    # The HTML autofocus attribute does nothing for a modal mounted from a
    # <template x-if> after the document parsed — the focus has to come from
    # Alpine.
    input = doc.at_css("input#onboarding-first-name")
    assert input, "expected the first-name input"
    assert_includes input["x-init"].to_s, "focus"
  end

  test "it reports upward and closes rather than opening anything itself" do
    html = render_first_name
    assert_includes html, "onboarding-step-done", "must announce what remains"
    assert_includes html, "$store.modals.close()", "must close itself"
    assert_not_includes html, ".open(", "the host owns the sequence; this step opens nothing"
  end

  test "the save posts JSON with a CSRF token" do
    html = render_first_name
    assert_includes html, "X-CSRF-Token"
    assert_includes html, "application/json"
  end

  # --- required: the gated mode -----------------------------------------------
  #
  # A host that GATES something on the name (turf's entry gate opens this card as
  # the first validation of hold-to-confirm) needs the skip affordances GONE: the
  # gate reads the stored column, so a recorded skip buys the user nothing and the
  # button is a door painted on a wall.
  #
  # What it must NOT become is a trap. Closing stays reachable — that abandons the
  # flow, which is a different thing from slipping past the gate. The two tests
  # below are a pair on purpose; a `required` that also removed the × would pass
  # the first one and be a worse card.

  test "required hides BOTH skip affordances" do
    html = render_first_name(required: true)
    assert_not_includes html, "Skip for now", "the skip button must not render at all"
    # Scanned for `@click="skip()"`, never bare "skip()": the x-data still DEFINES
    # async skip(), so a substring assertion would fail on the definition and pass
    # on nothing.
    assert_equal 0, html.scan(%(@click="skip()")).size,
                 "neither the × nor a button may call skip() at a gate"
    assert_not_includes html, %(aria-label="Skip")

    # THE CONTROL. Every assertion above also passes on a partial that lost the
    # skip path entirely, so pin what the UNGATED card still has.
    default = render_first_name
    assert_includes default, "Skip for now"
    assert_equal 2, default.scan(%(@click="skip()")).size
  end

  test "required leaves closing reachable, and relabels the × to match" do
    html = render_first_name(required: true)
    assert_includes html, %(@click="$store.modals.close()"),
                    "required hides the skip, it does not trap the user"
    assert_includes html, %(aria-label="Close"),
                    "the label must follow what the button now does"
  end

  test "the required × closes the HOST's store, not a hard-coded one" do
    html = render_first_name(required: true, modal_store: "dsModals")
    assert_includes html, %(@click="$store.dsModals.close()")
    assert_not_includes html, "$store.modals."
  end

  test "the default render is byte-for-byte the skippable card" do
    # McRitchie Studio renders this card today. Adding a second mode must not move
    # the first one, so the default is pinned to the skippable branch rather than
    # merely asserted to contain a Skip link.
    assert_equal render_first_name(required: false), render_first_name
  end

  test "the sub-copy follows required, and a host still outranks both" do
    assert_includes render_first_name, "we use it to address you in emails"

    gated = render_first_name(required: true)
    assert_includes gated, "One last thing"
    assert_not_includes gated, "we use it to address you in emails",
                        "the chain and the gate are reading to different audiences"

    assert_includes render_first_name(required: true, subtext: "For your receipts."),
                    "For your receipts."
  end

  # --- the OUTCOME: which path finished the step ------------------------------
  #
  # THE BLOCKER this partial had for turf-monster. `finish` is called by BOTH the
  # save and the skip, and it used to dispatch the same detail either way — so a
  # host could hear that the step was done and could not hear WHICH. turf's entry
  # gate resumes an interrupted contest entry on that signal; fired after a skip
  # it resumes an entry that still has no name.
  #
  # The three tests below are a set: one pins the save, one pins the skip, and
  # one pins the key that was already there. A flag that reported the same value
  # on both paths would satisfy exactly one of them.

  test "a SAVE reports that the name was saved" do
    assert_includes render_first_name, "this.finish(data.next || [], true);",
                    "the save path must report saved"
  end

  test "a SKIP reports the skip, honestly" do
    html = render_first_name
    assert_includes html, "this.finish((data && data.next) || [], false);",
                    "the skip path must report that nothing was saved"

    # THE CONTROL for the pair above. Both call sites live in the same x-data, so
    # a flag wired to one constant would still read `saved: <something>` on both
    # lines. Assert the two DISAGREE, not merely that each exists.
    assert_equal 1, html.scan(", true);").size, "exactly one call site may report true"
    assert_equal 1, html.scan(", false);").size, "exactly one call site may report false"
  end

  test "the flag is coerced, so an unreported path reports FALSE" do
    # The safe direction. A host acts on `saved: true` (turf resumes a contest
    # entry); a card that claimed true for a path it did not measure would be
    # worse than the ambiguity this replaced.
    assert_includes render_first_name, "saved: !!saved"
  end

  test "the existing `next` key and event name do not move" do
    # McRitchie Studio's layout listens for onboarding-step-done and retires its
    # ask marker on BOTH paths. The outcome rides ALONGSIDE next; it does not
    # replace it, rename it, or move it to a second event.
    html = render_first_name
    assert_includes html, "new CustomEvent('onboarding-step-done', { detail: { next: next, saved: !!saved } })"
    assert_equal 1, html.scan("dispatchEvent").size,
                 "one event carries the outcome; a second one would leave this one ambiguous"
  end

  test "the default card is 0.70.0's, moved ONLY by the outcome key" do
    # Byte-for-byte against the released card, with the four intended lines
    # rewound. Anything else that moved shows up as a diff here rather than in a
    # consumer.
    restored = OUTCOME_DELTAS.reduce(render_first_name) do |html, (now, before)|
      assert_includes html, now, "the outcome signal changed shape — update OUTCOME_DELTAS"
      html.sub(now, before)
    end
    assert_equal GOLDEN_0_70_0, restored
  end

  # --- placeholder_names: the opt-in typed placeholder ------------------------
  #
  # OFF unless asked for. It exists so turf-monster's adoption of this card does
  # not silently delete a flourish it has today; the operator may still choose to
  # drop it, so it has to come out in one piece.

  test "placeholder_names is INERT when the host does not pass it" do
    html = render_first_name
    assert_includes html, %(placeholder="Alex"), "the static placeholder stands"
    assert_not_includes html, "placeholderText", "no bound placeholder"
    assert_not_includes html, "startPlaceholder", "no typing machine"
    assert_not_includes html, "data-placeholder-names", "no payload"
    assert_not_includes html, "stopPlaceholder",
                         "finish() must not call a method the default card never defines"
  end

  test "an EMPTY pool behaves exactly like an absent local" do
    # A host computing the list from a table can hand over []. Emitting the whole
    # typing machine for a pool it can never sample from would leave the field
    # with no placeholder at all.
    assert_equal render_first_name, render_first_name(placeholder_names: [])
    assert_equal render_first_name, render_first_name(placeholder_names: nil)
  end

  test "a pool binds the placeholder and hands the names over as data" do
    html = render_first_name(placeholder_names: %w[Patrick Bo])
    assert_includes html, %(:placeholder="placeholderText"), "the placeholder is typed, not static"
    assert_not_includes html, %(placeholder="Alex"),
                         "a static value Alpine blanks after paint reads as a flicker"
    assert_includes html, "data-placeholder-names="
    assert_includes html, "startPlaceholder(JSON.parse($el.dataset.placeholderNames || '[]'))"
  end

  test "the pool travels as escaped JSON, so a name with an apostrophe survives" do
    # Handed over as a DATA ATTRIBUTE rather than interpolated into the x-data,
    # which is what makes this safe: the x-data is a double-quoted attribute and
    # a JSON array of names is full of double quotes.
    html = render_first_name(placeholder_names: ["Ja'Marr"])
    node = Nokogiri::HTML::DocumentFragment.parse(html).at_css("[data-placeholder-names]")
    assert node, "expected the payload on the root element"
    assert_equal ["Ja'Marr"], JSON.parse(node["data-placeholder-names"])
  end

  test "the typed mode keeps the x-data free of double quotes too" do
    # Same guard as the default card, run against the mode that adds ~55 lines of
    # Alpine and a block of comments to the inside of that attribute. Read from
    # the RAW markup for the reason spelled out above; the closing `"` is pinned
    # to the data attribute that follows it in this mode.
    html = render_first_name(placeholder_names: %w[Patrick])
    x_data = html[/<div x-data="(.*?)"\s*\n\s*data-placeholder-names=/m, 1]
    assert x_data.present?, "could not locate the x-data attribute in the typed mode"
    assert_not_includes x_data, '"',
                        "a double quote inside x-data kills the component in the browser"
  end

  test "typing stops when the user types, and never restarts" do
    # The part that makes it bearable rather than a nuisance. Three handlers:
    # real input dismisses it; a blur is RECORDED; and only a focus that follows
    # that blur dismisses it. A bare focus must not, because the input's own
    # x-init fires one on mount — treating that as engagement would kill the
    # animation before it drew a character.
    html = render_first_name(placeholder_names: %w[Patrick])
    assert_includes html, %(@input="dismissPlaceholder()")
    assert_includes html, %(@blur="markPlaceholderBlurred()")
    assert_includes html, %(@focus="refocusPlaceholder()")
    assert_includes html, "refocusPlaceholder() { if (this._phBlurred) this.dismissPlaceholder(); }",
                    "an UNGUARDED refocus dismisses on the mount focus, before a character is drawn"

    # And nothing puts it back: the pre-roll and the interval are started from
    # exactly one place, the root's x-init.
    assert_equal 1, html.scan("startPlaceholder(JSON.parse").size,
                 "the typing is kicked off once, from the root x-init, and never re-armed"
  end

  test "dismissing kills the PRE-ROLL as well as the timer" do
    # There is a 420ms wait before the first character, so the card can finish
    # its mount spring. Clearing only the interval would let the animation start
    # AFTER the user had already begun typing.
    html = render_first_name(placeholder_names: %w[Patrick])
    assert_includes html, "if (this._phTimer) { clearInterval(this._phTimer); this._phTimer = null; }"
    assert_includes html, "if (this._phDelay) { clearTimeout(this._phDelay); this._phDelay = null; }"
  end

  test "reduced motion gets the example without the animation" do
    html = render_first_name(placeholder_names: %w[Patrick])
    assert_includes html, "window.matchMedia('(prefers-reduced-motion: reduce)').matches"
    assert_includes html, "this.placeholderText = this._phPhrase;"
  end

  test "closing the card stops the timer it started" do
    # finish() closes the modal, which unmounts the component — an interval left
    # running would keep writing to a dead Alpine proxy.
    assert_includes render_first_name(placeholder_names: %w[Patrick]),
                    "this.stopPlaceholder();"
  end

  test "the pool does not disturb the modes around it" do
    # It has to be removable in one piece. Passing it must not move `required`,
    # the endpoints, or the outcome signal.
    typed = render_first_name(placeholder_names: %w[Patrick])
    assert_includes typed, "Skip for now"
    assert_includes typed, "{ detail: { next: next, saved: !!saved } }"
    gated = render_first_name(placeholder_names: %w[Patrick], required: true)
    assert_not_includes gated, "Skip for now"
    assert_includes gated, %(:placeholder="placeholderText")
  end
end
