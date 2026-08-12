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
#      (studio/modals/blocks/_age_verify) that renders from APP-SUPPLIED policy
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
  AGE_VERIFY_ERB  = File.join(ENGINE_ROOT, "app/views/studio/modals/blocks/_age_verify.html.erb")
  AGE_FACTORY_ERB = File.join(ENGINE_ROOT, "app/views/studio/_age_verify_assets.html.erb")

  # The jurisdictions TM's AgePolicy encodes. Their presence in an engine file (or
  # in the primitive rendered from neutral copy) means legal policy leaked across
  # the seam.
  POLICY_STATE_CODES = %w[AL NE IA MA VA].freeze

  def view
    # The style page's at-format specimens call Studio::AtTimeHelper. A host gets
    # every engine helper for free (no isolate_namespace); a bare test view does not.
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
                    .tap { |v| v.extend(Studio::AtTimeHelper) }
  end

  def render_age_verify(**locals)
    view.render(partial: "studio/modals/blocks/age_verify", locals: locals)
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
    assert_includes html, "Verify your age"
    assert_includes html, "ageVerifyModal("
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
    src     = File.read(AGE_VERIFY_ERB)
    factory = File.read(AGE_FACTORY_ERB)

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

  test "the style page ships the ageVerifyModal factory at page level" do
    html = render_index
    assert_includes html, "window.ageVerifyModal",
      "the age-verify factory must ship at page level so the modal opens live"
    assert_includes html, "$store.dsModals.current().id === 'age-verify'",
      "the overlay registers the age-verify modal"
    assert_includes html, "$store.dsModals.open('age-verify')",
      "the age-gate specimen is wired + openable"
  end

  test "with :age_gate OFF the age-gate specimen is disabled-but-present-yet-openable" do
    with_features([]) do
      html = render_index
      assert_includes html, "$store.dsModals.open('age-verify')",
        "the age-gate specimen stays present + openable when the flag is off"
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
    %w[age-verify entry-tokens].each do |id|
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
    src = File.read(AGE_VERIFY_ERB)
    ["entry-tokens", "age-verified", "advance(", "swap(", "dsModals"].each do |needle|
      refute_includes src, needle,
        "the engine primitive must stay flow-agnostic (no #{needle} in the primitive)"
    end
  end
end
