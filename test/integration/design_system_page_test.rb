# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] Guard for the admin/design_system living style guide (slice A:
# shell + Style section). Four load-bearing properties, each exercised (not just
# declared):
#
#   1. Studio.routes draws admin_design_system_path -> design_system#index into
#      every consuming host (this is what makes the page reachable in MS + TM).
#   2. The require_admin gate the controller relies on (from the already-included
#      Studio::ErrorHandling concern) redirects a logged-out visitor AND a
#      logged-in non-admin to root, and lets an admin through.
#   3. DesignSystemController wires that gate as a before_action.
#   4. The view is a bare content wrapper that REFERENCES every primitive family
#      (buttons, surfaces/text/form, the seven motion primitives, the theme
#      tokens). The dummy app does not compile the engine CSS, so the specimens
#      are unstyled here by design — this asserts the classes are referenced, the
#      contract a consumer's Tailwind build then styles for real.
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
end
