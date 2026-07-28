# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] Guard for the admin/style living style guide (renamed from
# admin/design_system). Load-bearing properties, each exercised (not just
# declared):
#
#   1. Studio.routes draws admin_style_path -> style#index, AND keeps the legacy
#      admin_design_system_path helper resolving as a redirect to /admin/style
#      (a shipped host sidebar still links the old helper).
#   2. The require_admin gate the controller relies on (from the already-included
#      Studio::ErrorHandling concern) redirects a logged-out visitor AND a
#      logged-in non-admin to root, and lets an admin through.
#   3. StyleController wires that gate as a before_action.
#   4. The view is a bare content wrapper that REFERENCES every primitive family
#      (buttons, surfaces/text/form, motion, effect), wires the four-section nav
#      in order (Theme landing / Modals / Tricks / Tasks) with matching anchor
#      targets, and keeps the color role tokens in the Theme section (Theme owns
#      "the colors"). The dummy app does not compile the engine CSS, so specimens
#      are unstyled here by design — this asserts the classes/contract.
#   5. Studio.feature?(name) gates capability specimens. Off by default, so the
#      Leveling (Tricks) and web3 + leveling (Modals) groups render
#      "disabled-but-present" — present + flagged, never hidden.
#   6. Modals wires a page-scoped store (dsModals) whose Open affordances push the
#      real engine card blocks (processing/success/error/countdown) full-size.
#   7. Theme folds the /admin/theme role-color editor into the page AND persists
#      Save + Regenerate IN PLACE (fetch, no navigation).
#   8. Tasks renders the shared board-primitive demonstrator on the stage-* spine.
#   9. The Tricks Leveling group renders the REAL .level-badge tiers, and
#      engine-motion.css ships the ported ladder (modern slash-rgb form).
class StylePageTest < ActiveSupport::TestCase
  def routes
    Rails.application.routes.url_helpers
  end

  # --- 1. route drawn into every host (+ legacy redirect) --------------------

  test "Studio.routes draws /admin/style -> style#index" do
    assert_equal "/admin/style", routes.admin_style_path

    route = Rails.application.routes.routes.find { |r| r.name == "admin_style" }
    refute_nil route, "expected a named admin_style route"
    assert_equal "style", route.defaults[:controller]
    assert_equal "index", route.defaults[:action]
  end

  test "the legacy admin_design_system helper survives as a redirect to /admin/style" do
    # The helper must still resolve — MS's shipped sidebar links admin_design_system_path.
    assert_equal "/admin/design_system", routes.admin_design_system_path

    route = Rails.application.routes.routes.find { |r| r.name == "admin_design_system" }
    refute_nil route, "the admin_design_system helper must survive the rename"

    # It is now a redirect (no controller#action dispatch).
    endpoint = route.app
    endpoint = endpoint.app while endpoint.respond_to?(:app) &&
                                 !endpoint.is_a?(ActionDispatch::Routing::Redirect)
    assert endpoint.is_a?(ActionDispatch::Routing::Redirect),
      "admin_design_system must be a redirect to /admin/style, not a controller action"
  end

  # --- 2. the require_admin gate actually gates ------------------------------

  # A bare controller including the SAME concern the real controller inherits
  # its gate from, so require_admin is exercised, not merely named.
  class AdminGateProbeController < ActionController::Base
    include Studio::ErrorHandling
  end

  # Invoke require_admin with a stubbed viewer; return the captured redirect
  # ({} when the gate lets the request through).
  def gate_result_for(user)
    controller = AdminGateProbeController.new
    captured = {}
    controller.define_singleton_method(:current_user) { user }
    controller.define_singleton_method(:root_path) { "/" }
    controller.define_singleton_method(:redirect_to) do |target, response_options = {}|
      captured[:target] = target
      captured[:options] = response_options
      nil
    end
    controller.send(:require_admin)
    captured
  end

  def admin_user
    Object.new.tap { |u| u.define_singleton_method(:admin?) { true } }
  end

  def non_admin_user
    Object.new.tap { |u| u.define_singleton_method(:admin?) { false } }
  end

  test "require_admin lets an admin through" do
    assert_empty gate_result_for(admin_user), "an admin must not be redirected"
  end

  test "require_admin redirects a logged-in non-admin to root" do
    result = gate_result_for(non_admin_user)
    refute_empty result, "a non-admin must be redirected"
    assert_equal "/", result[:target]
  end

  test "require_admin redirects a logged-out visitor to root" do
    result = gate_result_for(nil)
    refute_empty result, "a logged-out visitor must be redirected"
    assert_equal "/", result[:target]
  end

  # --- 3. the real controller wires the gate ---------------------------------

  test "StyleController wires require_admin as a before_action" do
    # The controller inherits the host ApplicationController; the dummy app ships
    # none, so stand one in (mirroring the host contract: < ActionController::Base
    # + the shared error-handling concern) and let Zeitwerk autoload the real
    # controller onto it.
    Object.const_set(:ApplicationController, Class.new(ActionController::Base) {
      include Studio::ErrorHandling
    }) unless Object.const_defined?(:ApplicationController)

    filters = StyleController._process_action_callbacks.map(&:filter)
    assert_includes filters, :require_admin,
      "StyleController must gate index with before_action :require_admin"
    assert StyleController.method_defined?(:index) ||
           StyleController.private_method_defined?(:index),
      "StyleController must define the index action"
  end

  # --- 4. the view references every primitive family -------------------------

  REQUIRED_CLASSES = %w[
    btn btn-primary btn-secondary btn-success btn-danger btn-warning
    btn-neutral btn-outline btn-google btn-sm btn-lg
    card card-hover badge input-field empty-state label-upper
    studio-border-glow spinner loading-dots sheen ping fade-edge progress-meter
  ].freeze

  REQUIRED_THEME_TOKENS = %w[
    --color-cta --color-surface --color-success --color-danger
    --color-warning --color-text --color-border-strong
  ].freeze

  # The four EFFECT primitives added to engine-motion.css — real engine classes
  # the Effects group specimens, so they belong in the referenced-class contract.
  REQUIRED_EFFECT_CLASSES = %w[
    text-gradient studio-glow surface-glass conic-surface
  ].freeze

  # Theme is the landing section; the section order the nav pills follow.
  SECTION_ANCHORS = %w[theme modals tricks tasks].freeze

  def render_index
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.render(template: "style/index")
  end

  test "the view is a bare content wrapper (no host layout of its own)" do
    html = render_index
    assert_includes html, "Style", "expected the page heading"
    refute_includes html, "<html", "a bare content wrapper must not emit its own <html> shell"
    refute_includes html, "<body", "a bare content wrapper must not emit its own <body> shell"
  end

  test "the view references every primitive family's class" do
    html = render_index
    REQUIRED_CLASSES.each do |klass|
      assert_includes html, klass,
        "the Tricks gallery must render a specimen using .#{klass}"
    end
  end

  test "the Tricks section references the four effect primitives" do
    html = render_index
    REQUIRED_EFFECT_CLASSES.each do |klass|
      assert_includes html, klass,
        "the Effects group must render a specimen using .#{klass}"
    end
  end

  test "the section nav links all four sections to matching anchor targets" do
    html = render_index
    SECTION_ANCHORS.each do |anchor|
      assert_includes html, %(href="##{anchor}"),
        "the section nav must link to ##{anchor}"
      assert_includes html, %(id="#{anchor}"),
        "section ##{anchor} must exist as an anchor target"
    end
  end

  test "the sections render in order: Theme (landing), Modals, Tricks, Tasks" do
    html = render_index
    positions = SECTION_ANCHORS.map { |id| html.index(%(id="#{id}")) }
    refute_includes positions, nil, "every section anchor must be present"
    assert_equal positions, positions.sort,
      "sections must appear in order Theme, Modals, Tricks, Tasks"
  end

  test "the color role tokens live in the Theme section, not Tricks" do
    html = render_index
    theme_start  = html.index('id="theme"')
    modals_start = html.index('id="modals"')
    refute_nil theme_start
    refute_nil modals_start
    theme_slice = html[theme_start...modals_start] # Theme first, Modals second
    REQUIRED_THEME_TOKENS.each do |token|
      assert_includes theme_slice, token,
        "Theme owns the color role token #{token} (moved out of Tricks)"
    end
    assert_includes theme_slice, "The colors",
      "Theme leads with the colors block"
    refute_includes html, "Theme tokens",
      "the Tricks section no longer carries a 'Theme tokens' sub-section"
  end

  # --- 6. Modals: page-scoped store opens the real engine card blocks --------

  test "the Modals section wires live engine-block modals via the dsModals store" do
    html = render_index
    assert_includes html, 'id="modals"'
    assert_includes html, "Alpine.store('dsModals'",
      "the Modals section registers its own page-scoped modal store"
    %w[ds-processing ds-success ds-error ds-countdown].each do |id|
      assert_includes html, "$store.dsModals.open('#{id}')",
        "the gallery must wire an Open for the #{id} specimen"
    end
    assert_includes html, "Entry confirmed", "ds-success renders the real success card block"
    assert_includes html, "Something went wrong. Give it another try.",
      "ds-error renders the real error card block"
  end

  # --- 6b. the ported Turf Monster modals register + open ---------------------

  # The page-scoped host (dsModals) mirrors the shared host's full API — the
  # in-modal step machine relies on advance() and the directional swap().
  test "the dsModals store exposes the full host API (open/swap/advance/close)" do
    html = render_index
    %w[open: swap: advance: close: cardClasses: current:].each do |method|
      assert_includes html, method,
        "the page-scoped modal store must define #{method}"
    end
    assert_includes html, "modal-card-mount",
      "cardClasses drives the ported enter animation classes"
    assert_includes html, "dsSolanaModal",
      "the on-chain-tx modal reads through the dsSolanaModal proxy"
  end

  # Every ported modal registers a single-root <template x-if> on its id in the
  # page overlay.
  test "the overlay registers the ported modal ids" do
    html = render_index
    %w[auth crop-photo saving wallet-connect onchain-tx wallet-deposit
       template-wizard template-form template-action template-status
       template-success].each do |id|
      assert_includes html, "$store.dsModals.current().id === '#{id}'",
        "the overlay must register the #{id} modal"
    end
  end

  # The AUTH suite — the #1 gap. Its bespoke step machine + blocks are present,
  # and the specimens open the real modal at a step.
  test "the Auth modal ports the credentials step machine + its blocks" do
    html = render_index
    # Opened at the credentials step with picksRequired AND the method config the
    # specimen toggles feed (methods { magicLink, google, wallet } + terms).
    assert_includes html, "$store.dsModals.open('auth', { step: 'credentials', picksRequired: 6, methods:",
      "the Sign in specimen opens the auth modal at the credentials step with method config"
    assert_includes html, "$store.dsModals.open('auth', { step: 'magic-link-sent'",
      "a 'magic link sent' variant specimen is wired"
    # The step machine itself.
    assert_includes html, "isCredentialsStep",
      "the auth partial carries the credentials-step guard"
    %w[magic-link-sent magic-link-resent].each do |step|
      assert_includes html, "props.step === '#{step}'",
        "the auth step machine handles the #{step} step"
    end
    # The magic-link CTA runs behind the stub, and the age gate is exercised.
    assert_includes html, "window.postMagicLink",
      "the magic-link CTA no-ops behind the postMagicLink stub"
    assert_includes html, "data-age-attestation",
      "the auth modal renders the legal-age attestation"
  end

  # --- 6c. Modals QoL: conversational copy, toggles, whole-card click, glow ----

  # Item 1 — the specimen header carries an agent-ready CONVERSATIONAL reference
  # (a sentence naming the modal + how to open it), not a raw JS blob copy.
  test "modal specimens copy a conversational reference from the header" do
    html = render_index
    assert_includes html, "Copy an agent-ready reference to this modal",
      "the header Copy affordance is present"
    assert_includes html, %(the Auth "Sign in" modal (studio-engine style/modals/_auth, step 'credentials')),
      "the reference names the modal + partial + step as a sentence"
    assert_includes html, "$refs.ref.textContent",
      "Copy reads the reference text, not a raw snippet"
    # The TITLE itself is the copy control (centered) — the standalone "Copy"
    # text button is gone, and the copy click/keys don't bubble to card-open.
    refute_includes html, %(x-text="copiedRef ? 'Copied' : 'Copy'"),
      "the standalone Copy text button was removed (title is the control)"
    assert_includes html, "@keydown.stop",
      "the title-copy control stops keydown from bubbling to the card open"
  end

  # Item 2b — equal-height cards: each specimen card stretches to its grid row
  # (h-full over a flex column), so a tall card no longer leaves siblings short.
  test "specimen cards stretch to equal height per row (h-full flex column)" do
    html = render_index
    assert_includes html, "flex flex-col h-full",
      "specimen cards use a full-height flex column so a grid row equalizes height"
  end

  # Items 2 + 3 — whole card is the trigger (role=button + keyboard), and the Auth
  # specimen carries the method toggles that gate the modal.
  test "modal specimens are whole-card clickable and carry option toggles" do
    html = render_index
    assert_includes html, 'role="button"',
      "the whole specimen card is a button"
    assert_includes html, "@keydown.enter.prevent",
      "Enter opens the modal (keyboard accessible)"
    assert_includes html, "@keydown.space.prevent",
      "Space opens the modal (keyboard accessible)"
    %w[opts.magicLink opts.google opts.wallet opts.terms].each do |model|
      assert_includes html, %(x-model="#{model}"),
        "the Auth specimen has the #{model} option toggle"
    end
    %w[Magic\ Link Google Solana\ Wallet Terms].each do |lbl|
      assert_includes html, lbl, "the toggle row labels #{lbl}"
    end
  end

  # Item 2 (gating) — the ported auth modal actually GATES each method + terms on
  # props, so the toggles configure a live open.
  test "the auth modal gates each credential method + terms via props" do
    html = render_index
    assert_includes html, "methodOn('google')", "Google is gated"
    assert_includes html, "methodOn('wallet')", "Solana wallet is gated"
    assert_includes html, "methodOn('magicLink')", "magic link is gated"
    assert_includes html, "termsOn()", "the age-attestation terms block is gated"
    assert_includes html, "_methodDefaults", "method defaults come from Studio.auth_method?"
  end

  # Item 4 — the magic-link-resent step has its own specimen.
  test "the Magic link resent step has its own specimen" do
    html = render_index
    assert_includes html, "$store.dsModals.open('auth', { step: 'magic-link-resent'",
      "a magic-link-resent specimen opens that step"
  end

  # Items 5 + 6 — the active-card glow follows the step machine off the store, and
  # Profile lists Image upload BEFORE Crop photo.
  test "the active-card glow is wired off the store, and Profile orders upload before crop" do
    html = render_index
    assert_includes html, "--studio-team-glow-opacity",
      "cards fade the ported glow via the opacity var"
    assert_includes html, "$store.dsModals.current().props.step || 'credentials'",
      "the glow matches the current modal + step reactively"
    upload_at = html.index("Image upload")
    crop_at   = html.index("Crop photo")
    refute_nil upload_at
    refute_nil crop_at
    assert upload_at < crop_at, "Profile must list Image upload before Crop photo"
  end

  # Item 7 — the single-color team glow ships in engine-motion.css and renders as
  # its own Tricks specimen, alongside the rainbow border glow (both in the bag).
  test "the studio-team-glow primitive ships in engine-motion.css and Tricks" do
    css = File.read("app/assets/tailwind/studio_engine/engine-motion.css")
    assert_includes css, ".studio-team-glow", "the team glow class is ported"
    assert_includes css, "--studio-team-glow-color", "the glow color is a CSS var (default CTA)"
    assert_includes css, "@keyframes studio-team-glow-spin", "the single-color ring rotation ships"
    refute_match(/rgba\(var\(--color-[^)]+-rgb\)/, css,
      "the port keeps the modern slash-rgb form, never legacy rgba(var(--*-rgb))")

    html = render_index
    assert_includes html, "studio-team-glow rounded-xl",
      "Tricks renders a studio-team-glow specimen"
    assert_includes html, "studio-border-glow",
      "the rainbow border glow specimen is still in the bag"
  end

  # PROFILE — crop / upload ACTUALLY open: cropper_assets is rendered on the
  # page (loading cropper.js + the factory) and the specimens open crop-photo.
  test "the Profile crop/upload modals are wired to open live" do
    html = render_index
    assert_includes html, "cropPhotoModal",
      "studio/cropper_assets is rendered so the crop factory is defined"
    assert_includes html, "cropperjs",
      "cropper.js is loaded on the page"
    assert_includes html, "$store.dsModals.open('crop-photo', { imageUrl:",
      "the Crop photo specimen opens the crop state"
    assert_includes html, "$store.dsModals.open('crop-photo', { cropReady: false })",
      "the Image upload specimen opens the empty picker (picker sub-state)"
    # The crop modal + saving card mount on the page-scoped store, not the
    # app-level shared host.
    assert_includes html, "cropPhotoModal({ store: 'dsModals' })",
      "the crop modal is mounted on the page-scoped dsModals host"
  end

  # The two Profile specimens open the SAME modal id (crop-photo) but must glow
  # the RIGHT card: the glow discriminates on the crop sub-state (props.cropReady),
  # which the crop factory sets true when the cropper mounts — so the glow moves
  # from Image upload (picker) to Crop photo (cropping) as an image is loaded.
  test "the Profile glow distinguishes crop-photo picker vs crop sub-state" do
    html = render_index
    # Image upload glows only in the picker sub-state; Crop photo only in crop.
    assert_includes html, "$store.dsModals.current().id === 'crop-photo' && !$store.dsModals.current().props.cropReady",
      "Image upload glows only when crop-photo is the empty picker"
    assert_includes html, "$store.dsModals.current().id === 'crop-photo' && !!$store.dsModals.current().props.cropReady",
      "Crop photo glows only when crop-photo has an image loaded"
    # The crop factory reflects the sub-state onto the store so the glow can react.
    factory = File.read("app/views/studio/modals/_image_upload.html.erb")
    assert_includes factory, "cur.props.cropReady = true",
      "mountCropper sets cropReady on the store entry (picker -> cropper transition)"
  end

  # web3 (wallet-connect, on-chain-tx, wallet-deposit) and leveling (level-up)
  # render disabled-but-present-yet-openable when the host has the capability
  # off: greyed + badged, but the trigger keeps its click affordance (a preview
  # you can still open), never inert.
  test "with :web3 and :leveling OFF the capability modal specimens are disabled-but-present-yet-openable" do
    original = Studio.features
    begin
      Studio.features = [] # MS default: web3 + leveling off
      html = render_index

      # The ported modal ids stay present with a working Open affordance.
      %w[wallet-connect onchain-tx wallet-deposit levelup].each do |id|
        assert_includes html, "$store.dsModals.open('#{id}'",
          "the #{id} specimen stays present + openable, not hidden"
      end
      assert_includes html, "disabled on this app",
        "the capability specimens are flagged disabled"
      assert_includes html, 'aria-disabled="true"',
        "the disabled specimens are marked for assistive tech"
      # Openable treatment: the greyed content keeps pointer events (opacity-60
      # grayscale), NOT the inert opacity-40 + pointer-events-none variant.
      assert_includes html, "opacity-60 grayscale",
        "a disabled-but-openable specimen keeps its click affordance"
    ensure
      Studio.features = original
    end
  end

  # --- 7. Theme: the /admin/theme editor folded in + save-in-place -----------

  test "the Theme section folds in the admin/theme role-color editor" do
    html = render_index
    assert_includes html, 'id="theme"'
    assert_includes html, 'action="/admin/theme"',
      "the editor posts to the admin_theme route"
    assert_includes html, 'action="/admin/theme/regenerate"',
      "the regenerate control posts to the admin_theme_regenerate route"
    assert_includes html, 'name="theme_setting[primary]"',
      "the editor renders the role-color inputs"
    assert_includes html, "dsThemeEditor(",
      "the live-preview editor factory is wired"
  end

  test "the Theme section persists Save + Regenerate IN PLACE (no navigation)" do
    html = render_index
    assert_includes html, "@submit.prevent",
      "the Theme forms are intercepted so the page does not navigate away"
    assert_includes html, "saveTheme($event)",
      "Save is intercepted in place"
    assert_includes html, "regenerate($event)",
      "Regenerate is intercepted in place"
    assert_includes html, "fetch(form.action",
      "the section submits via fetch and stays put"
  end

  # --- 8. Tasks: the shared board-primitive demonstrator ---------------------

  test "the Tasks section renders the board demonstrator on the stage-* spine" do
    html = render_index
    assert_includes html, 'id="tasks"'
    %w[stage-fresh stage-shipped stage-closed].each do |stage|
      assert_includes html, stage,
        "the Tasks demo must render the #{stage} palette role"
    end
    assert_includes html, "cursor-grab",
      "the demo cards show the drag / rank affordance"
    assert_includes html, "What every board inherits",
      "the standard-vs-custom sketch is present"
  end

  # --- 5. the capability-feature flag + disabled-but-present gating -----------

  test "Studio.feature? is false by default and true once opted in" do
    original = Studio.features
    begin
      Studio.features = []
      refute Studio.feature?(:leveling), "features default to [] (all off)"

      Studio.features = %i[leveling web3]
      assert Studio.feature?(:leveling), "an opted-in feature reads true"
      assert Studio.feature?("web3"), "feature? accepts a String too"
      refute Studio.feature?(:missing), "a feature not opted in reads false"
    ensure
      Studio.features = original
    end
  end

  test "with :leveling OFF the Tricks leveling specimens render disabled-but-present" do
    original = Studio.features
    begin
      Studio.features = [] # MS default: leveling off
      html = render_index

      assert_includes html, "Leveling",
        "the leveling sub-section heading is present"
      assert_includes html, "level-badge-10",
        "the leveling specimen stays present, not hidden"
      assert_includes html, "disabled on this app",
        "the disabled-but-present specimen is flagged"
      assert_includes html, 'aria-disabled="true"',
        "the disabled specimen is marked for assistive tech"
    ensure
      Studio.features = original
    end
  end

  # --- 9. the REAL level-badge tiers render + the engine ships the ladder -----

  test "the Tricks Leveling group renders the real level-badge tiers" do
    html = render_index
    (1..10).each do |lvl|
      assert_includes html, "level-badge-#{lvl}",
        "the Leveling group must render tier .level-badge-#{lvl}"
    end
    assert_includes html, "level-up-pop",
      "the Leveling group must render the .level-up-pop burst demo"
  end

  test "engine-motion.css ships the ported level-badge ladder in the modern rgb form" do
    css = File.read("app/assets/tailwind/studio_engine/engine-motion.css")
    assert_includes css, ".level-badge {", "the .level-badge base is ported"
    (1..10).each do |lvl|
      assert_includes css, ".level-badge-#{lvl}", "tier .level-badge-#{lvl} is ported"
    end
    assert_includes css, "@keyframes level-holographic", "the L10 holographic keyframe is ported"
    assert_includes css, "@keyframes level-shimmer",     "the L9 shimmer keyframe is ported"
    assert_includes css, ".level-up-pop",  "the level-up burst is ported"
    assert_includes css, ".badge-with-sheen", "the sheen wrapper is ported as a plain class"
    # The port must NOT reintroduce TM's broken legacy rgba(var(--*-rgb), a) form —
    # a space-separated rgb var is invalid inside legacy rgba() and silently drops.
    refute_match(/rgba\(var\(--color-[^)]+-rgb\)/, css,
      "space-separated rgb vars must use the modern slash form rgb(var(...) / a)")
  end

  # --- 10. the Confetti & pulse Tricks group renders all three specimens -------

  test "the Tricks Confetti & pulse group renders both confetti effects + the pulse" do
    html = render_index
    assert_includes html, "Confetti &amp; pulse",
      "the Tricks section carries a Confetti & pulse group heading"

    # Confetti card-burst — the callable is named prominently AND wired to a live
    # 'fire it' demo that aims at the specimen card.
    assert_includes html, "window.studioConfetti.burst(el)",
      "the burst specimen surfaces the window.studioConfetti.burst call name"
    assert_includes html, "window.studioConfetti.burst($refs.burstCard)",
      "the burst specimen has a live 'Fire burst' demo aimed at the card"

    # Confetti side-cannons — named + a live 'fire it' demo.
    assert_includes html, "window.studioConfetti.cannons()",
      "the cannons specimen surfaces the window.studioConfetti.cannons call name"
    assert_includes html, "Fire cannons",
      "the cannons specimen has a live 'Fire cannons' demo button"

    # Pulsing button — the .pulse-cta class specimen rides a real .btn.
    assert_includes html, "btn btn-primary pulse-cta",
      "the pulse specimen renders a real .btn with .pulse-cta"
    assert_includes html, ".pulse-cta",
      "the pulse specimen surfaces the .pulse-cta class name"
  end
end
