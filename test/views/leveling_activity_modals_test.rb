# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [component] Guard for the Profile Leveling flow — the quest/leveling activity
# modals migrated from Turf Monster, now a SINGLE toggle-driven flow (no more
# with-leveling / without-leveling fork):
#
#   A. ONE primitive, ONE modal id, TWO modes decided at RUNTIME.
#      studio/modals/blocks/_leveling_activity (and its _change_username
#      specialization) ALWAYS renders the leveling chrome (quest pill + seeds
#      celebration), gated by the reactive `leveling` getter which reads
#      props.leveling off the modal store. So one modal id flips TM (quest/seeds)
#      <-> MS (plain input + Save) live as a toggle moves — the `-plain` duplicate
#      ids are gone. The render-time `leveling` local is only the fallback default.
#   B. The CRITICAL BOUNDARY — the primitive is UI ONLY. The on-chain save is an
#      APP-SUPPLIED callback: the rendered modal + its factory carry NO wallet /
#      signing / on-chain vocabulary, and the factory exposes a domain-neutral
#      contract (submit_url + an opaque finalize_hook). Asserted against the
#      RENDERED output (ERB doc-comments are stripped), plus a source-level check
#      that no chain *code* token leaked.
#   C. The living style guide ships the "Profile Leveling" section: ONE live
#      leveling toggle, two activities (Change Username -> Join Newsletter), each
#      openable and glowing, opened with props.leveling.
class LevelingActivityModalsTest < ActiveSupport::TestCase
  ENGINE_ROOT           = File.expand_path("../..", __dir__)
  CHANGE_USERNAME_ERB   = File.join(ENGINE_ROOT, "app/views/studio/modals/blocks/_change_username.html.erb")
  LEVELING_ACTIVITY_ERB = File.join(ENGINE_ROOT, "app/views/studio/modals/blocks/_leveling_activity.html.erb")
  FACTORY_ERB           = File.join(ENGINE_ROOT, "app/views/studio/_leveling_activity_assets.html.erb")

  # Chain *code* tokens — if any of these appear in the primitive SOURCE (comments
  # included), real on-chain logic leaked across the seam. Descriptive prose about
  # the boundary ("no wallet lives here") is fine; these unambiguous code symbols
  # are not.
  ONCHAIN_CODE_TOKENS = %w[
    serialized_tx tx_signature needs_signature signTransaction sendRawTransaction
    solanaWeb3 solanaRpcUrl pollConfirmation skipPreflight Keypair phantom_wallet
    self_custodied managed_wallet Solana:: publicKey Squads
  ].freeze

  # Chain *vocabulary* — must not reach the RENDERED UI or the factory JS at all.
  ONCHAIN_RENDERED_NEEDLES = %w[
    solana wallet phantom custodial serialized_tx tx_signature needs_signature
    signtransaction sendrawtransaction keypair managed_wallet on-chain onchain
    cosign co-sign broadcast squads usdc pollconfirmation
  ].freeze

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
  end

  def render_change_username(**locals)
    view.render(partial: "studio/modals/blocks/change_username", locals: locals)
  end

  def render_leveling_activity(**locals)
    view.render(partial: "studio/modals/blocks/leveling_activity", locals: locals)
  end

  def render_factory
    view.render(partial: "studio/leveling_activity_assets")
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

  # --- A1. the leveling chrome is RUNTIME-GATED, not ERB-gated ------------------
  # The quest pill and seeds celebration are ALWAYS rendered and gated by the
  # reactive `leveling` (so a toggle can flip them live), never dropped at ERB time.

  test "change-username renders the quest pill + seeds celebration gated on the reactive leveling" do
    html = render_change_username(current_username: "picker", submit_url: "/u",
                                  leveling: true, quest_label: "Quest 1 of 2",
                                  level_label: "Level 1")
    frag = Nokogiri::HTML.fragment(html)

    # The action itself.
    assert_includes html, "Change Username", "the modal title renders"
    assert_includes html, "levelingActionModal(", "the shared factory backs the modal"
    assert_includes html, 'x-model="value"', "the username input renders"
    assert_includes html, "changed ? 'Save'", "the Save/Saved button renders"

    # The quest pill is present AND gated by the reactive leveling (x-show), so it
    # HIDES when leveling flips off — it is not dropped from the markup.
    pill = frag.css('[x-show="leveling"]').find { |n| n.text.include?("Quest 1 of 2") }
    refute_nil pill, "the quest pill must render, gated x-show=\"leveling\" (runtime, not ERB-dropped)"

    # The seeds celebration is present AND gated on BOTH celebrate and leveling.
    assert_includes html, 'x-if="celebrate && leveling"',
      "the celebration is gated on celebrate AND the reactive leveling"
    assert_includes html, "seeds-bar-continuous", "the seeds celebration markup is present"
    assert_includes html, "Great Username", "the celebration headline renders"
    assert_includes html, "Level 1", "the level chip renders"

    # The factory is TOLD the render-time default, but resolves leveling at runtime.
    assert_includes html, "leveling: true", "the factory receives the render-time default"
  end

  # --- A2. ONE template, BOTH modes — the fork is gone --------------------------
  # The KEY effect: the leveling chrome no longer depends on the Ruby `leveling`
  # flag at ERB time. Rendering with leveling:false STILL emits the SAME gated
  # quest pill + celebration markup — only the factory's fallback default differs.
  # The live TM<->MS flip is driven by the reactive getter (asserted in the
  # factory below) reading props.leveling, verified live in the browser preview.

  test "the leveling chrome renders identically regardless of the Ruby leveling default (fork removed)" do
    on  = render_change_username(current_username: "picker", submit_url: "/u", leveling: true,
                                 quest_label: "Quest 1 of 2", level_label: "Level 1")
    off = render_change_username(current_username: "picker", submit_url: "/u", leveling: false,
                                 quest_label: "Quest 1 of 2", level_label: "Level 1")

    # Both renders carry the runtime-gated chrome — leveling:false no longer drops it.
    [on, off].each do |html|
      assert_includes html, 'x-show="leveling"', "quest pill stays gated on leveling in both defaults"
      assert_includes html, 'x-if="celebrate && leveling"', "celebration stays runtime-gated in both defaults"
      assert_includes html, "seeds-bar-continuous", "seeds markup is present in both defaults (one template)"
      assert_includes html, "Quest 1 of 2", "quest label is present in both defaults"
    end

    # The ONLY mode-relevant difference is the factory's fallback default.
    assert_includes on,  "leveling: true",  "leveling:true sets the on default"
    assert_includes off, "leveling: false", "leveling:false sets the off default"
  end

  test "the factory resolves leveling at RUNTIME from the store props (the live flip source)" do
    js = render_factory
    assert_includes js, "get leveling()",
      "leveling is a runtime getter, not a fixed value — one id flips live"
    assert_includes js, "props.leveling",
      "the getter reads props.leveling off the modal store (the toggle's source of truth)"
    assert_includes js, "_levelingDefault",
      "the getter falls back to the render-time default (TM's live path is unaffected)"
  end

  # --- A3. the generic activity: consent checkbox + no-input action ------------

  test "the generic leveling_activity gates its chrome at runtime + supports a consent checkbox" do
    html = render_leveling_activity(submit_url: "/q", leveling: true, input: false,
                                    title: "Join the Newsletter", quest_label: "Quest 2 of 2",
                                    consent_label: "Email me sports news and contest updates.",
                                    cta_label: "Subscribe", celebrate_title: "Subscribed!")
    assert_includes html, "Join the Newsletter"
    assert_includes html, 'x-show="leveling"', "the quest pill is runtime-gated"
    assert_includes html, 'x-if="celebrate && leveling"', "the celebration is runtime-gated"
    assert_includes html, "changed ? 'Subscribe'", "the configurable CTA renders"
    # The consent checkbox renders and binds consent, which the factory gates on.
    assert_includes html, 'x-model="consent"', "the consent checkbox renders + binds consent"
    assert_includes html, "Email me sports news and contest updates.", "the consent label renders"
    assert_includes render_factory, "this.hasConsent && !this.consent",
      "the factory gates the action until consent is ticked"
  end

  test "a no-input activity omits the text field (a plain action button)" do
    html = render_leveling_activity(submit_url: "/q", leveling: false, input: false,
                                    title: "Send a message", cta_label: "Send")
    refute_includes html, 'x-model="value"', "a no-input activity renders no text field"
    assert_includes html, "changed ? 'Send'", "the action button still renders"
  end

  # --- B1..B4. the on-chain save is an APP-SUPPLIED callback (the seam) --------

  test "the primitive is UI-only — no on-chain vocabulary reaches the rendered modal" do
    html = render_change_username(current_username: "picker", submit_url: "/u", leveling: true).downcase
    ONCHAIN_RENDERED_NEEDLES.each do |needle|
      refute_includes html, needle, "the rendered modal must carry no on-chain vocabulary (#{needle})"
    end
    refute_match(/\bsign(ed|ing|ature)?\b/, html, "the rendered modal must not mention signing")
    refute_match(/\b(rpc|pda|idl|mint|vault)\b/, html, "the rendered modal must carry no chain jargon")
  end

  test "the factory is UI-only + exposes the neutral app-callback contract" do
    js = render_factory
    down = js.downcase
    ONCHAIN_RENDERED_NEEDLES.each do |needle|
      refute_includes down, needle, "the factory JS must carry no on-chain vocabulary (#{needle})"
    end
    refute_match(/\bsign(ed|ing|ature)?\b/, down, "the factory JS must not sign anything")
    assert_includes js, "submitUrl", "the factory POSTs to an app-supplied submit_url"
    assert_includes js, "needs_step", "the factory reacts to the neutral needs_step status"
    assert_includes js, "finalizeHook", "the second step is delegated to an app-supplied hook"
    assert_includes js, "challenge", "the app's step blob is forwarded opaquely as a challenge"
    assert_includes js, "proof", "the app's step result is forwarded opaquely as a proof"
    assert_includes js, "savedEvent", "success dispatches an app-facing event so the app runs its follow-on"
  end

  test "no chain CODE token leaked into the primitive or factory source" do
    [CHANGE_USERNAME_ERB, LEVELING_ACTIVITY_ERB, FACTORY_ERB].each do |path|
      src = File.read(path)
      ONCHAIN_CODE_TOKENS.each do |tok|
        refute_includes src, tok, "#{File.basename(path)} must not contain the chain code token #{tok}"
      end
    end
  end

  test "submit_url is REQUIRED (the app owns the save)" do
    assert_match(/local_assigns\.fetch\(:submit_url\)\s*$/, File.read(LEVELING_ACTIVITY_ERB),
      "submit_url must be a bare required fetch — the engine never invents the save endpoint")
    error = assert_raises(ActionView::Template::Error) { render_leveling_activity(leveling: false) }
    assert_match(/submit_url/, error.message)
  end

  # --- C. the living style guide ships the Profile Leveling section ------------

  test "the style page ships the levelingActionModal factory at page level" do
    html = render_index
    assert_includes html, "window.levelingActionModal",
      "the factory must ship at page level so the modals open live"
  end

  test "the Profile Leveling section renders ONE toggle + both activities (no -plain twins)" do
    html = render_index

    # The section renamed + the single live toggle that drives leveling.
    assert_includes html, "Profile Leveling", "the section is renamed to Profile Leveling"
    refute_includes html, "Leveling activities", "the old section title is gone"
    assert_includes html, 'x-model="leveling"', "the section ships ONE live leveling toggle"
    assert_includes html, "$watch('leveling'", "toggling patches an open modal so the flip is live"

    # ONE id per activity, opened WITH props.leveling from the toggle.
    %w[change-username join-newsletter].each do |id|
      assert_includes html, "$store.dsModals.current().id === '#{id}'",
        "the overlay registers the #{id} modal"
      assert_includes html, "$store.dsModals.open('#{id}', { demo: true, leveling: leveling })",
        "the #{id} card opens with the section's live leveling"
    end

    # The retired `-plain` twins are gone.
    %w[change-username-plain quest-activity quest-activity-plain].each do |id|
      refute_includes html, "id === '#{id}'", "the retired #{id} modal must not register"
    end
  end

  test "the Profile Leveling specimen cards wire the active-card glow" do
    html = render_index
    %w[change-username join-newsletter].each do |id|
      assert_includes html, "$store.dsModals.current() && $store.dsModals.current().id === '#{id}'",
        "the #{id} specimen card must glow when its modal is current"
    end
  end
end
