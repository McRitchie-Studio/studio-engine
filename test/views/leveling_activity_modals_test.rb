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
#   A. ONE primitive, ONE modal id, THREE runtime-gated views. Both
#      studio/modals/blocks/_leveling_activity and its _change_username
#      specialization ALWAYS render the form (!celebrate), the seeds celebration
#      (celebrate && leveling, TM) and the plain confirmation (celebrate &&
#      !leveling, MS), gated by the reactive `leveling` getter which reads
#      props.leveling off the modal store. So one modal id flips TM <-> MS live as
#      a toggle moves — the `-plain` duplicate ids are gone, and there is NO "Quest
#      N of N" counter. The render-time `leveling` local is only the fallback.
#   B. The CRITICAL BOUNDARY — the primitive is UI ONLY. The on-chain save is an
#      APP-SUPPLIED callback: the rendered modal + its factory carry NO wallet /
#      signing / on-chain vocabulary, and the factory exposes a domain-neutral
#      contract (submit_url + an opaque finalize_hook). Asserted against the
#      RENDERED output (ERB doc-comments are stripped), plus a source-level check
#      that no chain *code* token leaked.
#   C. The living style guide ships the "Profile Leveling" section: FOUR walked
#      cards (Change Username -> Great Username -> Join Newsletter -> Subscribed!),
#      each carrying its OWN per-card leveling toggle (like the Auth card's method
#      checkboxes) — the two "updated" cards open the same id straight at the
#      celebrate state (props.celebrate), each openable and glowing.
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

  # --- A1. three RUNTIME-GATED views: form / seeds celebration / plain confirm ---
  # The celebration and the MS confirmation are ALWAYS rendered and gated by the
  # reactive leveling (so a toggle flips them live), never dropped at ERB time.
  # There is NO "Quest N of N" counter.

  test "change-username renders form + seeds celebration + plain confirm, runtime-gated, no quest counter" do
    html = render_change_username(current_username: "picker", submit_url: "/u",
                                  leveling: true,
                                  confirm_subtitle: "Your username has been updated.")

    # The action itself (the form view).
    assert_includes html, "Change Username", "the modal title renders"
    assert_includes html, "levelingActionModal(", "the shared factory backs the modal"
    assert_includes html, 'x-model="value"', "the username input renders"
    assert_includes html, "changed ? 'Save'", "the Save/Saved button renders"

    # No quest counter anywhere — the profile modals do not carry one.
    refute_match(/Quest\s+\d+\s+(of|\/)\s*\d+/i, html, "there must be no 'Quest N of N' counter")

    # The seeds celebration — gated on BOTH celebrate AND the reactive leveling (TM).
    assert_includes html, 'x-if="celebrate && leveling"',
      "the seeds celebration is gated on celebrate AND the reactive leveling"
    assert_includes html, "seeds-bar-continuous", "the seeds celebration markup is present"
    assert_includes html, "Great Username", "the celebration headline renders"
    # The "Level N" pill was dropped from the celebrate view; the seeds bar stays.
    refute_includes html, "Level 1", "the celebration carries no 'Level N' chip (dropped)"
    refute_match(/local_assigns\.fetch\(:level_label/, File.read(LEVELING_ACTIVITY_ERB),
      "the primitive no longer accepts a level_label local")

    # The plain confirmation — the MS shape, gated celebrate && !leveling.
    assert_includes html, 'x-if="celebrate && !leveling"',
      "the plain confirmation is gated celebrate && !leveling (MS shape)"
    assert_includes html, "Your username has been updated.", "the plain confirmation subtext renders"

    # The factory is TOLD the render-time default, but resolves leveling at runtime.
    assert_includes html, "leveling: true", "the factory receives the render-time default"
  end

  # --- A2. ONE template, three views — the fork is gone, no quest counter --------
  # The views no longer depend on the Ruby leveling flag at ERB time: rendering
  # with leveling:false STILL emits the SAME gated celebration + plain-confirm
  # markup, only the factory's fallback default differs. The live TM<->MS flip is
  # driven by the reactive getter (asserted below), verified live in the preview.

  test "the three views render regardless of the Ruby leveling default (fork removed)" do
    on  = render_change_username(current_username: "picker", submit_url: "/u", leveling: true)
    off = render_change_username(current_username: "picker", submit_url: "/u", leveling: false)

    [on, off].each do |html|
      assert_includes html, 'x-if="celebrate && leveling"',  "seeds celebration is runtime-gated in both defaults"
      assert_includes html, 'x-if="celebrate && !leveling"', "plain confirmation is runtime-gated in both defaults"
      assert_includes html, "seeds-bar-continuous", "seeds markup is present in both defaults (one template)"
      refute_match(/Quest\s+\d+\s+(of|\/)\s*\d+/i, html, "no quest counter in either default")
    end

    assert_includes on,  "leveling: true",  "leveling:true sets the on default"
    assert_includes off, "leveling: false", "leveling:false sets the off default"
  end

  test "the factory resolves leveling at RUNTIME + opens at the celebrate state via props" do
    js = render_factory
    assert_includes js, "get leveling()",
      "leveling is a runtime getter, not a fixed value — one id flips live"
    assert_includes js, "props.leveling",
      "the getter reads props.leveling off the modal store (the toggle's source of truth)"
    assert_includes js, "_levelingDefault",
      "the getter falls back to the render-time default (TM's live path is unaffected)"
    # Opening AT the updated state — the 'updated' cards open the same id pre-advanced.
    assert_includes js, "init: function", "the factory has an init hook"
    assert_includes js, "p.celebrate", "init reads props.celebrate to open directly at the updated state"
  end

  # A save must (a) TRANSFER the specimen glow from the input card to the updated
  # card — like the Auth glow follows props.step — and (b) NOT open a second modal.
  test "a save advances props.celebrate (glow follows) and a demo save fires no app event (no double modal)" do
    js = render_factory
    # (a) glow follows: _finishSaved mirrors celebrate onto the LIVE store props,
    # which is exactly the reactive source the specimen glow_when reads.
    assert_includes js, "cur.props.celebrate",
      "_finishSaved mirrors celebrate onto the store props so the glow transfers input -> updated"
    # (b) no double modal: in demo mode the app-facing saved event is suppressed, so
    # a host follow-on (e.g. Turf Monster's quest-success on studio:username-saved)
    # cannot stack a SECOND modal over the demo's own celebrate view.
    assert_includes js, "if (this.demo) return",
      "the demo save suppresses the app-facing saved event (no host follow-on stacks a modal)"
  end

  # --- REGRESSION GUARD (0.25.1): app-driven save CLOSES; no double-render --------
  # 0.25.0 made _finishSaved ALWAYS advance to the engine's own confirm/celebrate.
  # But a consuming app that drives its OWN post-save follow-on (Turf Monster's
  # change-username: non-demo + a custom saved_event) then rendered its next step
  # TWICE — once in this dialog, once in its own inline card — which TM's Playwright
  # e2e caught as a strict-mode double-render. The engine must instead CLOSE on save
  # (fire the event, then STOP — the 0.24 contract) for the app-driven case, while
  # demo and standalone (default-event) callers still advance to celebrate.

  test "an app-driven save (non-demo + custom saved_event) closes instead of celebrating; demo/standalone still advance" do
    js = render_factory

    # The discriminator getter reads BOTH signals: demo short-circuits to false
    # (demo always celebrates), and a NON-default saved_event marks the caller
    # app-driven (it owns its own follow-on).
    assert_includes js, "get appDrivenFollowOn()",
      "the factory exposes the app-driven-follow-on discriminator"
    assert_includes js, %(var DEFAULT_SAVED_EVENT = "studio:activity-saved"),
      "the default saved event is the single source of truth the discriminator compares against"
    assert_match(/get appDrivenFollowOn\(\)\s*\{[^}]*if \(this\.demo\) return false;[^}]*this\.savedEvent !== DEFAULT_SAVED_EVENT/m, js,
      "appDrivenFollowOn is false for demo and true only for a non-default saved_event")

    # _finishSaved CLOSES on the app-driven path: the celebrate advance is GUARDED by
    # an early return on appDrivenFollowOn, so an app-driven save never sets celebrate.
    finish = js[/_finishSaved: function[^{]*\{(.+?)\n        \},/m, 1]
    assert finish, "the factory defines _finishSaved"
    guard_at   = finish.index("if (this.appDrivenFollowOn) return")
    advance_at = finish.index("this.celebrate = true")
    assert guard_at,   "_finishSaved returns early when the app drives its own follow-on"
    assert advance_at, "_finishSaved still has a celebrate advance for the non-app-driven path"
    assert_operator guard_at, :<, advance_at,
      "the app-driven early-return GUARDS the celebrate advance (app-driven closes; demo/standalone celebrate)"
  end

  # The two real sides of the discriminator are pinned by actual callers: the engine
  # change-username ships a custom saved_event, so a real (non-demo) TM-shape caller
  # is app-driven and closes on save; the /admin/style specimen stays demo, so it
  # still advances to the celebrate state.
  test "change_username wires a custom saved_event (app-driven) while the style specimen stays demo" do
    cu = render_change_username(current_username: "picker", submit_url: "/u", leveling: false)
    assert_includes cu, "savedEvent: 'studio:username-saved'",
      "change_username wires a custom saved_event — the signal that the app drives its own follow-on"
    refute_includes cu, "demo: true",
      "a plain change_username render is non-demo, so it is app-driven and closes on save"

    html = render_index
    assert_includes html, "$store.dsModals.open('change-username', { demo: true",
      "the /admin/style Change Username specimen opens in demo mode, so it still advances to celebrate"
  end

  # --- A3. the generic activity: consent checkbox + runtime-gated views --------

  test "the generic leveling_activity gates its chrome at runtime + supports a consent checkbox" do
    html = render_leveling_activity(submit_url: "/q", leveling: true, input: false,
                                    title: "Join the Newsletter",
                                    consent_label: "Email me sports news and contest updates.",
                                    cta_label: "Subscribe", saved_label: "Subscribed",
                                    celebrate_title: "Subscribed!")
    assert_includes html, "Join the Newsletter"
    assert_includes html, 'x-if="celebrate && leveling"',  "the seeds celebration is runtime-gated"
    assert_includes html, 'x-if="celebrate && !leveling"', "the plain confirmation is runtime-gated"
    assert_includes html, "changed ? 'Subscribe'", "the configurable CTA renders"
    refute_match(/Quest\s+\d+\s+(of|\/)\s*\d+/i, html, "no quest counter")
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

  test "the Profile Leveling section walks FOUR cards with PER-CARD toggles (no -plain twins, no quest counter)" do
    html = render_index

    # The section renamed. Leveling is now PER-CARD (like the Auth card's method
    # checkboxes), not one section-wide toggle: the old section x-model/$watch are
    # gone and each card ships its own opts.leveling checkbox.
    assert_includes html, "Profile Leveling", "the section is renamed to Profile Leveling"
    refute_includes html, "Leveling activities", "the old section title is gone"
    refute_includes html, 'x-model="leveling"', "the single section-wide leveling toggle is removed"
    refute_includes html, "$watch('leveling'", "no section-level $watch patches an open modal anymore"
    assert_operator html.scan('x-model="opts.leveling"').size, :>=, 4,
      "each of the four cards ships its OWN opts.leveling checkbox"

    # FOUR walked cards — each opens with ITS OWN card toggle (opts.leveling); the
    # two "updated" cards open the SAME id straight at the celebrate state
    # (props.celebrate), like Auth steps.
    assert_includes html, "$store.dsModals.open('change-username', { demo: true, leveling: opts.leveling })",
      "the Change Username card opens the form with its own card toggle"
    assert_includes html, "$store.dsModals.open('change-username', { demo: true, leveling: opts.leveling, celebrate: true, seedsEarned: 25, seedsTotal: 25 })",
      "the Great Username card opens change-username straight at the celebrate state"
    assert_includes html, "$store.dsModals.open('join-newsletter', { demo: true, leveling: opts.leveling })",
      "the Join Newsletter card opens the form with its own card toggle"
    assert_includes html, "$store.dsModals.open('join-newsletter', { demo: true, leveling: opts.leveling, celebrate: true, seedsEarned: 25, seedsTotal: 100 })",
      "the Subscribed! card opens join-newsletter straight at the celebrate state"

    # The card labels for the walked flow.
    %w[Change\ Username Great\ Username Join\ Newsletter Subscribed!].each do |label|
      assert_includes html, ">#{label}<", "the '#{label}' card renders in the walk"
    end

    # No quest counter anywhere on the page (mocks + modals).
    refute_match(/Quest\s+\d+\s*(of|\/)\s*\d+/i, html, "there must be no 'Quest N of N' counter")

    # The retired `-plain` twins are gone.
    %w[change-username-plain quest-activity quest-activity-plain].each do |id|
      refute_includes html, "id === '#{id}'", "the retired #{id} modal must not register"
    end
  end

  test "the Profile Leveling cards wire the glow, discriminating input vs updated of the same id" do
    html = render_index
    # Each id has TWO cards (form + celebrate); the glow discriminates on
    # props.celebrate so the right card lights.
    %w[change-username join-newsletter].each do |id|
      assert_includes html, "$store.dsModals.current().id === '#{id}' && !$store.dsModals.current().props.celebrate",
        "the #{id} INPUT card glows only when its modal is at the form"
      assert_includes html, "$store.dsModals.current().id === '#{id}' && !!$store.dsModals.current().props.celebrate",
        "the #{id} UPDATED card glows only when its modal is at the celebrate state"
    end
  end
end
