# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] Guard for engine 0.21's Phase-2 modal convergence:
#
#   A. The age-gate DOB modal is an ENGINE PRIMITIVE
#      (studio/modals/blocks/_birthday) that renders from APP-SUPPLIED policy
#      props and hardcodes NO legal policy — no state->age table, no AgePolicy, no
#      minimum-age default (18 is itself a policy value). This is the load-bearing
#      seam: the engine renders the modal UI + DOB fields + submit; the app owns
#      min_age, the jurisdiction label, the endpoint, and the legal copy.
#   B. The entry-token purchase flow is an APP-SPECIFIC Design System SPECIMEN —
#      documented on /admin/style by composing engine chrome, with the packs and
#      the on-chain mint left app-owned, and copy that is on-chain-accurate (a
#      prepaid on-chain entry credit, NOT a wallet-held SPL token).
#   C. The age-gate specimen is capability-gated (:age_gate) — disabled-but-
#      present-yet-openable when off, like the web3 specimens.
class AgeGateEntryTokenTest < ActiveSupport::TestCase
  ENGINE_ROOT     = File.expand_path("../..", __dir__)
  BIRTHDAY_ERB    = File.join(ENGINE_ROOT, "app/views/studio/modals/blocks/_birthday.html.erb")
  BIRTHDAY_FACTORY_ERB = File.join(ENGINE_ROOT, "app/views/studio/_birthday_assets.html.erb")

  # The jurisdictions TM's AgePolicy encodes. Their presence in an engine file (or
  # in the primitive rendered from neutral copy) means legal policy leaked across
  # the seam.
  POLICY_STATE_CODES = %w[AL NE IA MA VA].freeze

  def view
    # A host renders these views through ApplicationController, which has EVERY
    # engine helper mixed in (no isolate_namespace). A bare test view has none, so
    # give it the whole set rather than the one module today's specimens happen to
    # call — otherwise the next helper-backed specimen breaks all five harnesses.
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
  end

  def render_age_verify(**locals)
    render_partial("studio/modals/blocks/birthday", **locals)
  end

  # Any engine partial, rendered the way a host would. Used by the age-gate
  # tests, which assert against RENDERED markup rather than ERB source — an
  # interpolated quote that closes an attribute early does not exist until
  # render, so source reading cannot see it.
  def render_partial(partial, **locals)
    view.render(partial: partial, locals: locals)
  end

  def render_index
    view.render(template: "style/index")
  end

  def with_features(features)
    original = Studio.features
    Studio.features = features
    yield
  ensure
    Studio.features = original
  end

  # --- A1. the primitive renders from app-supplied policy props --------------

  test "the age-gate primitive renders the DOB modal from app-supplied policy props" do
    html = render_age_verify(min_age: 21, state: "CA", submit_url: "/age/verify",
                             fine_print: "App-supplied legal copy.")
    # Modal chrome + the Alpine factory reference.
    assert_includes html, "Your birthday"
    assert_includes html, "birthdayModal("
    # DOB Month / Day / Year fields.
    assert_includes html, 'x-model="month"'
    assert_includes html, 'x-model="day"'
    assert_includes html, 'x-model="year"'
    assert_includes html, "Confirm &amp; Continue"
    # The APP-SUPPLIED number + jurisdiction label + legal copy ride through.
    assert_includes html, "21+", "the app-supplied minimum age renders"
    assert_includes html, "in CA", "the app-supplied jurisdiction label renders"
    assert_includes html, "App-supplied legal copy.", "the app-supplied fine print renders"
  end

  test "a blank state drops the jurisdiction clause (state is optional)" do
    html = render_age_verify(min_age: 18, submit_url: "/age/verify")
    assert_includes html, "18+"
    refute_includes html, " in .", "no dangling jurisdiction clause when state is blank"
  end

  # --- A2. the primitive hardcodes NO legal policy (the seam) ----------------

  test "the rendered primitive carries no hardcoded policy table" do
    html = render_age_verify(min_age: 21, state: "CA", submit_url: "/age/verify")
    ["AL/NE", "IA/MA/VA", "19+", "AgePolicy"].each do |needle|
      refute_includes html, needle,
        "the engine age-gate must not render the policy table (#{needle})"
    end
  end

  test "the primitive + factory source hardcode no state table, no AgePolicy, no age default" do
    src     = File.read(BIRTHDAY_ERB)
    factory = File.read(BIRTHDAY_FACTORY_ERB)

    POLICY_STATE_CODES.each do |code|
      refute_match(/\b#{code}\b/, src,     "the age-gate primitive must not hardcode jurisdiction #{code}")
      refute_match(/\b#{code}\b/, factory, "the age-gate factory must not hardcode jurisdiction #{code}")
    end
    [src, factory].each do |body|
      refute_includes body, "AgePolicy", "the engine must not reach into the app's AgePolicy"
    end

    # min_age is REQUIRED with NO engine default — 18 is itself a policy value.
    assert_match(/local_assigns\.fetch\(:min_age\)\s*$/, src,
      "min_age must be a bare required fetch (no defaulted value)")
    refute_match(/min_age.*\|\|\s*18/, src,     "the engine primitive must not default the minimum age to 18")
    refute_match(/\|\|\s*18/,          factory, "the engine factory must not default the minimum age to 18")
  end

  # --- B. the entry-token DS specimen (app-specific, engine chrome) ----------

  test "the entry-token specimen renders the documented purchase flow" do
    html = render_index
    assert_includes html, "$store.dsModals.current().id === 'entry-tokens'",
      "the overlay registers the entry-tokens modal"
    assert_includes html, "$store.dsModals.open('entry-tokens'",
      "the entry-tokens specimen is wired + openable"
    assert_includes html, "Get Entry Tokens", "the picker header renders"
    assert_includes html, "1 token = 1 contest entry", "the token mental model is documented"
    # On-chain accuracy (Jasper): a prepaid on-chain credit, NOT a wallet SPL token.
    assert_includes html, "prepaid entry credit recorded on-chain",
      "the doc frames the entry token as a prepaid on-chain credit"
    refute_includes html, "SPL token",
      "the doc must not frame the entry token as a wallet-held SPL token"
    assert_includes html, "app-owned",
      "the specimen states the packs/rails/mint stay app-owned"
  end

  # --- C. the age-gate specimen is capability-gated on :age_gate -------------

  test "the style page ships the birthdayModal factory at page level" do
    html = render_index
    assert_includes html, "window.birthdayModal",
      "the birthday factory must ship at page level so the modal opens live"
    assert_includes html, "$store.dsModals.current().id === 'birthday'",
      "the overlay registers the birthday modal"
    assert_includes html, "$store.dsModals.open('birthday')",
      "the birthday specimen is wired + openable"
    # The refusal card is a SECOND registration. Without it the handoff opens an
    # id nothing renders and the modal goes blank mid-flow.
    assert_includes html, "$store.dsModals.current().id === 'age-gate'",
      "the overlay registers the age-gate refusal card the birthday card hands off to"
  end

  test "with :age_gate OFF the age-gate specimen is disabled-but-present-yet-openable" do
    with_features([]) do
      html = render_index
      assert_includes html, "$store.dsModals.open('birthday')",
        "the birthday specimen stays present + openable when the flag is off"
      assert_includes html, "age gate off", "the specimen is flagged disabled"
      assert_includes html, "opacity-60 grayscale",
        "a disabled-but-openable specimen keeps its click affordance"
    end
  end

  test "with :age_gate ON the age-gate specimen is enabled (not greyed)" do
    with_features(%i[age_gate]) do
      html = render_index
      assert_includes html, "age gate on", "the section badge flips on when the flag is set"
      refute_includes html, "age gate off", "an enabled specimen shows no disabled flag"
    end
  end

  # --- D. the new specimen cards wire the active-card glow --------------------
  # Each new card must light (studio-team-glow) when ITS modal is current, like
  # the Auth / Profile specimens — the age-gate card was the odd one out.

  test "the age-gate + entry-token specimen cards wire the active-card glow" do
    html = render_index
    assert_includes html, "--studio-team-glow-opacity",
      "the specimens carry the active-card glow opacity var"
    %w[birthday age-gate entry-tokens].each do |id|
      assert_includes html, "$store.dsModals.current() && $store.dsModals.current().id === '#{id}'",
        "the #{id} specimen card must glow when its modal is the current one"
    end
    assert_includes html, "studio-team-glow rounded-xl",
      "the glow rides the un-clipped wrapper, as on the other specimens"
  end

  # --- E. the DEMO walks the flow: age-gate confirm -> entry-token purchase ---
  # The wiring lives on the STYLE side: the page listens for the primitive's
  # 'age-verified' handoff hook and opens the purchase modal. The engine
  # primitive stays flow-agnostic — its real submit posts to the app submit_url.

  test "the style page advances the age-gate demo to the entry-token purchase" do
    html = render_index
    assert_match(/@age-verified\.window="[^"]*\$store\.dsModals\.open\('entry-tokens'/, html,
      "confirming the age-gate demo advances to the entry-tokens purchase modal")
  end

  test "the age-gate engine primitive carries no demo flow/advance logic" do
    src = File.read(BIRTHDAY_ERB)
    ["entry-tokens", "age-verified", "advance(", "swap(", "dsModals"].each do |needle|
      refute_includes src, needle,
        "the engine primitive must stay flow-agnostic (no #{needle} in the primitive)"
    end
  end

  # --- E. the refusal is a HANDOFF, not a dead end (2026-08-24) ---------------
  #
  # The birthday card used to own both halves: it asked for the date AND, when
  # the date failed, turned red and disabled its own submit button. That is the
  # one screen state with nothing to press. The refusal now lives on its own
  # card with two ways out. These tests hold that apart.

  test "the birthday card never disables itself over an under-age date" do
    html = render_age_verify(min_age: 21, state: "CA", submit_url: "/age/verify")
    # The disabled binding must gate on completeness and in-flight only. If
    # computedAge creeps back into it, the dead end is back.
    assert_includes html, ':disabled="!complete || submitting"',
      "the submit button gates on completeness and in-flight ONLY"
    refute_includes html, "computedAge < minAge",
      "an under-age date must SUBMIT and route to the age-gate card, not disable the button"
  end

  test "the birthday card carries no inline refusal text" do
    html = render_age_verify(min_age: 21, state: "CA", submit_url: "/age/verify")
    # The error line stays — an invalid date is a real error. What must be gone
    # is the too-young paragraph, which is a verdict wearing an error's clothes.
    assert_includes html, 'x-text="error"', "genuine errors still surface here"
    refute_includes html, "'You must be ' + minAge",
      "the inline too-young line moved to the age-gate card"
  end

  test "the birthday card is told which card to hand off to" do
    html = render_age_verify(min_age: 21, state: "CA", submit_url: "/age/verify")
    assert_includes html, "gateId: 'age-gate'",
      "the default handoff target rides into the factory"
  end

  test "the age-gate card offers BOTH ways out" do
    html = render_partial("studio/modals/blocks/age_gate",
                          min_age: 21, state: "CA",
                          watch_url: "/contests/demo", modal_store: "modals")
    # The thing they CAN do. Too young to enter is not too young to watch.
    assert_includes html, "Watch the Contest", "the primary CTA offers the alternative"
    assert_includes html, "/contests/demo", "the CTA points at the app-supplied target"
    # The thing they might NEED — a mis-picked year is an ordinary typo.
    assert_includes html, "Update your Birthday", "the back link is present"
    assert_includes html, "swap('birthday'", "the back link RETURNS to the birthday card"
  end

  test "the age-gate card drops a CTA it was given no target for" do
    # A dead button is worse than no button: it reads as broken rather than absent.
    html = render_partial("studio/modals/blocks/age_gate", min_age: 21, modal_store: "modals")
    refute_includes html, "Watch the Contest",
      "with no watch_url the CTA must be dropped, not rendered dead"
    assert_includes html, "Update your Birthday",
      "the back link does not depend on the app supplying a watch target"
  end

  test "the age-gate card computes no eligibility of its own" do
    # Same rule the birthday card follows: the engine displays policy, never
    # decides it. A comparison here would be the engine growing a legal opinion.
    source = File.read(File.join(ENGINE_ROOT, "app/views/studio/modals/blocks/_age_gate.html.erb"))
    refute_match(/computedAge|< *minAge|>= *minAge/, source,
      "the refusal card must DISPLAY min_age, never compare against it")
  end

  test "the age-gate x-data survives ERB interpolation" do
    # Rendered, not read from source: the bug this catches is an interpolated
    # value that emits a DOUBLE quote and closes the attribute early. Reading the
    # ERB cannot see it, because the offending quote does not exist until render.
    html = render_partial("studio/modals/blocks/age_gate",
                          min_age: 21, state: "CA", watch_url: "/x",
                          title: "Sorry, not yet", modal_store: "modals")
    x_data = html[/x-data="(\{.*?\})"/m, 1]
    assert x_data.present?, "the x-data attribute did not survive rendering intact"
    refute_includes x_data, %("),
      "an interpolated double quote closes x-data early and mounts a silent no-op"
  end

  test "the style guide walks the handoff, not just the two cards" do
    html = render_index
    assert_includes html, "$store.dsModals.open('birthday', { demoUnderage: true })",
      "a specimen must open the birthday card down its REFUSED branch"
    assert_includes html, "demoUnderage",
      "the factory takes a demo flag so the guide can walk the refusal with no backend"
  end
end
