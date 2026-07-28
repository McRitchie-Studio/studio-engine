# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] Guard for engine 0.22's Phase-3 modal convergence — the
# quest/leveling activity modals migrated from Turf Monster:
#
#   A. ONE primitive, TWO modes. studio/modals/blocks/_leveling_activity (and its
#      _change_username specialization) renders BOTH the full quest framing (quest
#      pill + seeds level-up celebration) when leveling is ON, and the plain action
#      modal (input + Save + Saved, no quest/seeds) when leveling is OFF. The mode
#      is decided by a `leveling` local (defaulting to Studio.feature?(:leveling)).
#   B. The CRITICAL BOUNDARY — the primitive is UI ONLY. The on-chain save is an
#      APP-SUPPLIED callback: the rendered modal + its factory carry NO wallet /
#      signing / on-chain vocabulary, and the factory exposes a domain-neutral
#      contract (submit_url + an opaque finalize_hook). Asserted against the
#      RENDERED output (ERB doc-comments are stripped, so this catches only
#      vocabulary that actually reaches the UI/JS), plus a source-level check that
#      no chain *code* token leaked.
#   C. The living style guide ships both modals, each shown BOTH ways, wired +
#      openable with the active-card glow.
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

  # --- A1. change-username WITH leveling — quest pill + seeds chrome present ----

  test "change-username renders the quest pill + seeds celebration when leveling is ON" do
    html = render_change_username(current_username: "picker", submit_url: "/u",
                                  leveling: true, quest_label: "Quest 1 of 4")
    # The action itself.
    assert_includes html, "Change Username", "the modal title renders"
    assert_includes html, "levelingActionModal(", "the shared factory backs the modal"
    assert_includes html, 'x-model="value"', "the username input renders"
    assert_includes html, "changed ? 'Save'", "the Save/Saved button renders"
    # The leveling framing.
    assert_includes html, "Quest 1 of 4", "the quest pill renders when leveling is on"
    assert_includes html, "seeds-bar-continuous", "the seeds celebration mounts when leveling is on"
    assert_includes html, "Great Username", "the celebration headline renders"
    assert_includes html, "leveling: true", "the factory is told leveling is on"
  end

  # --- A2. change-username WITHOUT leveling — plain action, no quest/seeds ------

  test "change-username renders the plain action modal when leveling is OFF" do
    html = render_change_username(current_username: "picker", submit_url: "/u",
                                  leveling: false, quest_label: "Quest 1 of 4")
    # The action still renders.
    assert_includes html, "Change Username"
    assert_includes html, 'x-model="value"', "the input still renders in plain mode"
    assert_includes html, "changed ? 'Save'", "the Save/Saved button still renders"
    # The leveling framing is ABSENT — not merely unmounted.
    refute_includes html, "seeds-bar-continuous", "no seeds celebration when leveling is off"
    refute_includes html, "Quest 1 of 4", "no quest pill when leveling is off"
    refute_includes html, "Great Username", "no celebration headline when leveling is off"
    assert_includes html, "leveling: false", "the factory is told leveling is off"
  end

  # --- A3. the generic quest activity renders both ways too --------------------

  test "the generic leveling_activity renders quest chrome on, and plain off" do
    on = render_leveling_activity(submit_url: "/q", leveling: true, input: true,
                                  title: "Join the Newsletter", quest_label: "Quest 2 of 4",
                                  cta_label: "Subscribe")
    assert_includes on, "Join the Newsletter"
    assert_includes on, "Quest 2 of 4", "the quest pill renders when leveling is on"
    assert_includes on, "seeds-bar-continuous", "the seeds celebration mounts when leveling is on"
    assert_includes on, "changed ? 'Subscribe'", "the configurable CTA renders"

    off = render_leveling_activity(submit_url: "/q", leveling: false, input: true,
                                   title: "Join the Newsletter", quest_label: "Quest 2 of 4",
                                   cta_label: "Subscribe")
    assert_includes off, "Join the Newsletter"
    refute_includes off, "Quest 2 of 4", "no quest pill when leveling is off"
    refute_includes off, "seeds-bar-continuous", "no seeds celebration when leveling is off"
  end

  test "a no-input activity omits the text field (a plain action button)" do
    html = render_leveling_activity(submit_url: "/q", leveling: false, input: false,
                                    title: "Send a message", cta_label: "Send")
    refute_includes html, 'x-model="value"', "a no-input activity renders no text field"
    assert_includes html, "changed ? 'Send'", "the action button still renders"
  end

  # --- B1. the on-chain save is an APP-SUPPLIED callback (the seam) ------------

  test "the primitive is UI-only — no on-chain vocabulary reaches the rendered modal" do
    # Rendered with the engine's own neutral defaults (no app-authored on-chain
    # description). ERB doc-comments are stripped on render, so anything caught
    # here is vocabulary that actually reached the UI.
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
    # The app-supplied-callback seam IS present, and domain-neutral.
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

  # --- C. the living style guide ships both modals, each BOTH ways ------------

  test "the style page ships the levelingActionModal factory at page level" do
    html = render_index
    assert_includes html, "window.levelingActionModal",
      "the factory must ship at page level so the modals open live"
  end

  test "both modals register + stay openable, each in both modes" do
    html = render_index
    %w[change-username change-username-plain quest-activity quest-activity-plain].each do |id|
      assert_includes html, "$store.dsModals.current().id === '#{id}'",
        "the overlay registers the #{id} modal"
      assert_includes html, "$store.dsModals.open('#{id}')",
        "the #{id} specimen is wired + openable"
    end
    # The leveling section renders, and the leveling-on specimen carries the quest
    # chrome (the plain twin does not).
    assert_includes html, "Leveling activities", "the new style-guide section renders"
    assert_includes html, "Quest 1 of 4", "the leveling-on change-username demo shows the quest pill"
  end

  test "the leveling-activity specimen cards wire the active-card glow" do
    html = render_index
    %w[change-username change-username-plain quest-activity quest-activity-plain].each do |id|
      assert_includes html, "$store.dsModals.current() && $store.dsModals.current().id === '#{id}'",
        "the #{id} specimen card must glow when its modal is current"
    end
  end
end
