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

  # Renders the engine navbar logged-out with just the helpers it touches.
  # logged_in? must exist even with show_logged_in passed: the partial reads it
  # via fetch's eager default argument, not a lazy block.
  def render_navbar(preview: false)
    v = view
    v.define_singleton_method(:logged_in?) { false }
    v.define_singleton_method(:root_path)  { "/" }
    v.define_singleton_method(:login_path) { "/login" }
    v.render(partial: "layouts/navbar", locals: { show_logged_in: false, preview: preview })
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

  # --- the page transition direction is the one switch -----------------------

  def with_direction(value)
    original = Studio.page_transition_direction
    Studio.page_transition_direction = value
    yield
  ensure
    Studio.page_transition_direction = original
  end

  test "the direction defaults to nil" do
    assert_nil Studio.page_transition_direction
  end

  test "with no direction, smooth_load on renders exactly the two metas it always did" do
    html = with_smooth_load(true) { render_smooth_load }

    assert_equal %(  <meta name="view-transition" content="same-origin">\n  <meta name="turbo-cache-control" content="no-preview">\n),
                 html.sub(/\A.*?(?=  <meta)/m, "")
    refute_includes html, "page-transition"
  end

  test "with no direction and smooth_load off, the partial renders nothing but whitespace" do
    assert_empty with_smooth_load(false) { render_smooth_load }.strip
  end

  test "a direction alone turns the metas on, with smooth_load off" do
    html = with_smooth_load(false) { with_direction(:top) { render_smooth_load } }

    assert_equal 1, html.scan('<meta name="view-transition" content="same-origin">').size
    assert_equal 1, html.scan('<meta name="turbo-cache-control" content="no-preview">').size
    assert_equal 1, html.scan('<meta name="page-transition-direction" content="top">').size
  end

  test "a direction with smooth_load on renders each meta once" do
    html = with_smooth_load(true) { with_direction(:left) { render_smooth_load } }

    assert_equal 1, html.scan('name="view-transition"').size
    assert_equal 1, html.scan('name="page-transition-direction"').size
  end

  test "a direction alone pins the navbar once, and a preview navbar never" do
    assert_equal 1, with_smooth_load(false) { with_direction(:left) { render_navbar } }.scan("vt-pinned-header").size
    assert_equal 0, with_smooth_load(false) { with_direction(:left) { render_navbar(preview: true) } }.scan("vt-pinned-header").size
  end

  test "the head loads the module only with a direction, below the import map" do
    head = File.read(HEAD_ERB)
    gate = head.rindex('<% if @studio_page_transition_direction || Studio.page_transition_direction %>')

    assert gate, "the module tag must sit behind the setting"
    assert_operator head.index("<%= javascript_importmap_tags %>"), :<, gate
    assert_match(/\A<% if [^\n]+%>\n  <%= javascript_import_module_tag "studio\/page_transitions" %>\n<% end %>/, head[gate..])
  end

  test "the head links the full-load sheet and its script only with a direction, ahead of the modules" do
    head = File.read(HEAD_ERB)
    gate = head.index('<% if @studio_page_transition_direction || Studio.page_transition_direction %>')

    assert_match(%r{\A<% if [^\n]+%>\n  <%= stylesheet_link_tag "studio/page_transition_full_load" %>\n  <%= javascript_include_tag "studio/page_transition_reveal", nonce: studio_script_nonce %>\n<% end %>}, head[gate..])
    assert_operator gate, :<, head.index("<%= javascript_importmap_tags %>")
  end

  test "every view-transition name an engine view sets inline carries the morph marker" do
    named = Dir[File.join(ENGINE_ROOT, "app/views/**/*.erb")].flat_map do |path|
      source = File.read(path)
      source.scan(/view-transition-name: ([\w-]+);/).flatten.map do |name|
        assert_match(/data-vt-morph="#{name}"|vt_morph: \(?"#{name}"/, source, "#{path}: #{name}")
        name
      end
    end
    assert_includes named, "agent-portrait", "the scan found nothing, so it proved nothing"
    assert_includes named, "agent-composer"
  end

  test "head renders the convention partial and the configurable spinner minimum" do
    head = File.read(HEAD_ERB)

    assert_includes head, 'render "layouts/studio/smooth_load"'
    assert_includes head, "Studio.nav_spinner_min_ms"
    refute_includes head, "_navSpinnerMinMs = 2500"
  end

  test "engine.css paints the backdrop with the page color, and a slide keeps its opacity" do
    css = File.read(CSS_PATH)

    assert_match(/\[data-page-transition="still"\]\)::view-transition \{\s*background: var\(--color-page, Canvas\);/, css)
    refute_match(/::view-transition \{\s*background: #000/, css)
    slides = css.scan(/^@keyframes pt-(?:out|in-from)-[^\n]+$/)
    assert_equal 8, slides.size
    slides.each { |rule| refute_includes rule, "opacity", rule }
  end

  test "engine.css draws all eight page transition styles, each behind its attribute" do
    css = File.read(CSS_PATH)

    %w[slide-left unfold-right slide-right unfold-left slide-top unfold-bottom slide-bottom unfold-top].each do |style|
      assert_includes css, %(html[data-page-transition="#{style}"]::view-transition-old(root))
      assert_includes css, %(html[data-page-transition="#{style}"]::view-transition-new(root))
    end
    assert_match(/animation-duration: 700ms;\s*\n\s*animation-timing-function: ease;/, css)
    assert_equal 4, css.scan("perspective(1200px)").size
    assert_match(/^html\[data-page-transition-direction\]\[data-page-transition-visit\] \[data-vt-held\] \{/, css, "the stack's name lasts for the visit, behind the setting")
    refute_match(/^\.studio-bar-stack \{[^}]*view-transition-name/, css)
    refute_includes css, '[style*="view-transition-name'
  end

  # A host with Studio.smooth_load and no direction runs the engine's fade with this navbar, and
  # no browser spec plays that fade, so only this test stops the rule losing its attribute.
  test "engine.css hides the old navbar's picture only on a visit that plays a style" do
    hiding = File.read(CSS_PATH).scan(/^([^\n{}]*::view-transition-old\(studio-header\)[^\n{}]*)\{[^}]*opacity/).flatten.map(&:strip)

    assert_equal [%(html[data-page-transition]:not([data-page-transition="still"])::view-transition-old(studio-header))], hiding
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

  # --- engine navbar self-pin (engine 0.26) -------------------------------
  #
  # The engine's own layouts/_navbar carries vt-pinned-header when the app
  # opts into smooth_load, so hosts stop shadowing the partial just to add
  # the class. Non-preview only: preview renders can repeat per page, and a
  # duplicate view-transition-name silently disables every transition.

  test "navbar self-pins exactly once when smooth_load is on" do
    html = with_smooth_load(true) { render_navbar }

    assert_equal 1, html.scan("vt-pinned-header").size
  end

  test "navbar emits no pin when smooth_load is off" do
    html = with_smooth_load(false) { render_navbar }

    assert_equal 0, html.scan("vt-pinned-header").size
  end

  test "preview navbar never pins even with smooth_load on" do
    html = with_smooth_load(true) { render_navbar(preview: true) }

    assert_equal 0, html.scan("vt-pinned-header").size
  end

  test "engine.css suppresses the header cross-fade and falls back the bar color" do
    css = File.read(CSS_PATH)

    # The studio-header group's UA cross-fade suppression (formerly the
    # app-side bridge rule in mcritchie-studio and turf-monster) — bind
    # animation: none to the studio-header selectors specifically, not just
    # anywhere in the file.
    assert_match(
      /::view-transition-old\(studio-header\),\s*\n::view-transition-new\(studio-header\)\s*\{\s*\n\s*animation:\s*none;\s*\n\}/,
      css
    )
    # Turbo's own default blue keeps the bar visible without the runtime
    # theme block.
    assert_includes css, "background: var(--color-cta, #0076ff)"
  end
end
