# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] Guard for the admin/design_system living style guide — all four
# sections built (Style / Modals / Theme / Tasks). Load-bearing properties, each
# exercised (not just declared):
#
#   1. Studio.routes draws admin_design_system_path -> design_system#index into
#      every consuming host (this is what makes the page reachable in MS + TM).
#   2. The require_admin gate the controller relies on (from the already-included
#      Studio::ErrorHandling concern) redirects a logged-out visitor AND a
#      logged-in non-admin to root, and lets an admin through.
#   3. DesignSystemController wires that gate as a before_action.
#   4. The view is a bare content wrapper that REFERENCES every primitive family
#      (buttons, surfaces/text/form, the seven motion primitives, the four effect
#      primitives, the theme tokens) and wires the four-section nav (Style /
#      Modals / Theme / Tasks) with matching anchor targets. The dummy app does
#      not compile the engine CSS, so specimens are unstyled here by design —
#      this asserts the classes/contract a consumer's Tailwind build styles.
#   5. Studio.feature?(name) gates capability specimens. Off by default, so the
#      Leveling (Style) and web3 + leveling (Modals) groups render
#      "disabled-but-present" — present + flagged, never hidden — on a host
#      (like MS) that has those capabilities off.
#   6. Modals wires a page-scoped store (dsModals) whose Open affordances push the
#      real engine card blocks (processing/success/error/countdown) full-size.
#   7. Theme folds the /admin/theme role-color editor into the page.
#   8. Tasks renders the shared board-primitive demonstrator on the stage-* spine.
class DesignSystemPageTest < ActiveSupport::TestCase
  def routes
    Rails.application.routes.url_helpers
  end

  # --- 1. route drawn into every host ----------------------------------------

  test "Studio.routes draws /admin/design_system -> design_system#index" do
    assert_equal "/admin/design_system", routes.admin_design_system_path

    route = Rails.application.routes.routes.find { |r| r.name == "admin_design_system" }
    refute_nil route, "expected a named admin_design_system route"
    assert_equal "design_system", route.defaults[:controller]
    assert_equal "index",         route.defaults[:action]
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

  test "DesignSystemController wires require_admin as a before_action" do
    # The controller inherits the host ApplicationController; the dummy app ships
    # none, so stand one in (mirroring the host contract: < ActionController::Base
    # + the shared error-handling concern) and let Zeitwerk autoload the real
    # controller onto it.
    Object.const_set(:ApplicationController, Class.new(ActionController::Base) {
      include Studio::ErrorHandling
    }) unless Object.const_defined?(:ApplicationController)

    filters = DesignSystemController._process_action_callbacks.map(&:filter)
    assert_includes filters, :require_admin,
      "DesignSystemController must gate index with before_action :require_admin"
    assert DesignSystemController.method_defined?(:index) ||
           DesignSystemController.private_method_defined?(:index),
      "DesignSystemController must define the index action"
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

  SECTION_ANCHORS = %w[style modals theme tasks].freeze

  def render_index
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.render(template: "design_system/index")
  end

  test "the view is a bare content wrapper (no host layout of its own)" do
    html = render_index
    assert_includes html, "Design System", "expected the page heading"
    refute_includes html, "<html", "a bare content wrapper must not emit its own <html> shell"
    refute_includes html, "<body", "a bare content wrapper must not emit its own <body> shell"
  end

  test "the view references every primitive family's class" do
    html = render_index
    REQUIRED_CLASSES.each do |klass|
      assert_includes html, klass,
        "the Style gallery must render a specimen using .#{klass}"
    end
  end

  test "the view reads the 7 theme role tokens live" do
    html = render_index
    REQUIRED_THEME_TOKENS.each do |token|
      assert_includes html, token,
        "the theme-tokens section must read var(#{token}) so the swatch restyles per app"
    end
  end

  test "the Style section references the four effect primitives" do
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

  test "Modals / Theme / Tasks are built (no leftover stub cards)" do
    html = render_index
    assert_equal 0, html.scan('data-stub="true"').size,
      "the wave-2 sections replace the stub cards"
    refute_includes html, "This section lands in the next build."
  end

  # --- 6. Modals: page-scoped store opens the real engine card blocks --------

  # The status archetypes each wire an Open onto the self-contained dsModals
  # store, and the real engine block partials render as that modal's content.
  test "the Modals section wires live engine-block modals via the dsModals store" do
    html = render_index
    assert_includes html, 'id="modals"'
    assert_includes html, "Alpine.store('dsModals'",
      "the Modals section registers its own page-scoped modal store"
    %w[ds-processing ds-success ds-error ds-countdown].each do |id|
      assert_includes html, "$store.dsModals.open('#{id}')",
        "the gallery must wire an Open for the #{id} specimen"
    end
    # The genuine engine card blocks are reused as the modal content, not mocked.
    assert_includes html, "Entry confirmed", "ds-success renders the real success card block"
    assert_includes html, "Something went wrong. Give it another try.",
      "ds-error renders the real error card block"
  end

  # web3 (wallet-connect, on-chain-tx) and leveling (level-up) are standardized as
  # engine modal specimens but render disabled-but-present when the host has the
  # capability off — present + flagged, never hidden.
  test "with :web3 and :leveling OFF the capability modal specimens are disabled-but-present" do
    original = Studio.features
    begin
      Studio.features = [] # MS default: web3 + leveling off
      html = render_index

      %w[ds-wallet-connect ds-onchain-tx ds-levelup].each do |id|
        assert_includes html, "$store.dsModals.open('#{id}')",
          "the #{id} specimen stays present, not hidden"
      end
      assert_includes html, "disabled on this app",
        "the capability specimens are flagged disabled"
      assert_includes html, 'aria-disabled="true"',
        "the disabled specimens are marked for assistive tech"
    ensure
      Studio.features = original
    end
  end

  # --- 7. Theme: the /admin/theme editor folded into the page ----------------

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

  # --- 8. Tasks: the shared board-primitive demonstrator ---------------------

  test "the Tasks section renders the board demonstrator on the stage-* spine" do
    html = render_index
    assert_includes html, 'id="tasks"'
    # The stage-* palette is the board spine — the demo names the stage roles.
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

  test "with :leveling OFF the leveling specimens render disabled-but-present" do
    original = Studio.features
    begin
      Studio.features = [] # MS default: leveling off
      html = render_index

      assert_includes html, "Leveling",
        "the leveling sub-section heading is present"
      assert_includes html, "level-badge-10",
        "the representative leveling specimen stays present, not hidden"
      assert_includes html, "disabled on this app",
        "the disabled-but-present specimen is flagged"
      assert_includes html, 'aria-disabled="true"',
        "the disabled specimen is marked for assistive tech"
    ensure
      Studio.features = original
    end
  end
end
