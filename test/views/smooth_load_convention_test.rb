# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] Guard for the smooth-load convention seam (engine 0.24):
#
#   A. layouts/studio/_smooth_load renders the view-transition + no-preview
#      metas ONLY when the app opts in (Studio.smooth_load) — default OFF, so a
#      plain gem bump changes no app's navigation behavior.
#   B. _head defers the nav spinner minimum to Studio.nav_spinner_min_ms
#      (default 2500 — turf-monster wraps multi-second Solana RPC in the
#      spinner) instead of hardcoding it.
#   C. engine.css ships the transition choreography: root old/new keyframes,
#      the .vt-pinned-header opt-in pin (unique-per-page by contract — a
#      duplicate view-transition-name silently disables the transition), the
#      themed .turbo-progress-bar, and the reduced-motion kill switch the
#      apps' e2e suites lean on (reducedMotion: "reduce").
class SmoothLoadConventionTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)
  CSS_PATH    = File.join(ENGINE_ROOT, "app/assets/tailwind/studio_engine/engine.css")
  HEAD_ERB    = File.join(ENGINE_ROOT, "app/views/layouts/studio/_head.html.erb")

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
  end

  def render_smooth_load
    view.render(partial: "layouts/studio/smooth_load")
  end

  def with_smooth_load(value)
    original = Studio.smooth_load
    Studio.smooth_load = value
    yield
  ensure
    Studio.smooth_load = original
  end

  test "smooth_load defaults OFF and the spinner minimum to 2500" do
    assert_equal false, Studio.smooth_load
    assert_equal 2500, Studio.nav_spinner_min_ms
  end

  test "opted-in apps render both convention metas exactly once" do
    html = with_smooth_load(true) { render_smooth_load }

    assert_equal 1, html.scan('<meta name="view-transition" content="same-origin">').size
    assert_equal 1, html.scan('<meta name="turbo-cache-control" content="no-preview">').size
  end

  test "opted-out apps render no metas at all" do
    html = with_smooth_load(false) { render_smooth_load }

    refute_includes html, "<meta"
  end

  test "head renders the convention partial and the configurable spinner minimum" do
    head = File.read(HEAD_ERB)

    assert_includes head, 'render "layouts/studio/smooth_load"'
    assert_includes head, "Studio.nav_spinner_min_ms"
    refute_includes head, "_navSpinnerMinMs = 2500"
  end

  test "engine.css ships the full transition choreography" do
    css = File.read(CSS_PATH)

    assert_includes css, "::view-transition-old(root)"
    assert_includes css, "::view-transition-new(root)"
    assert_includes css, "@keyframes vt-page-out"
    assert_includes css, "@keyframes vt-page-in"
    assert_includes css, "@utility vt-pinned-header"
    assert_includes css, "view-transition-name: studio-header"
    assert_includes css, ".turbo-progress-bar"
    assert_includes css, "prefers-reduced-motion"
  end
end
