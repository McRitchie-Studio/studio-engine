# frozen_string_literal: true

require "test_helper"

# [component] Guard for the vendored, no-CDN confetti effect: canvas-confetti is
# shipped as an engine asset (studio/canvas_confetti.js) and studio_confetti.js
# builds window.studioConfetti (burst + cannons) on top, honoring reduced motion.
#
# Load-bearing invariants:
#   * canvas-confetti is VENDORED (not a CDN link) and defines the global confetti;
#   * window.studioConfetti exposes BOTH callable effects (burst + cannons);
#   * both effects guard prefers-reduced-motion (early return + the canvas-confetti
#     disableForReducedMotion belt);
#   * the engine head loads the two bundled assets via javascript_include_tag and
#     NO LONGER links the jsDelivr confetti CDN (CSP-safe, same-origin);
#   * the assets are precompiled (prod) and packaged in the gem.
class StudioConfettiJsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def vendored_lib
    @vendored_lib ||= File.read(File.join(ROOT, "app/assets/javascripts/studio/canvas_confetti.js"))
  end

  def effect_js
    @effect_js ||= File.read(File.join(ROOT, "app/assets/javascripts/studio/studio_confetti.js"))
  end

  def head_erb
    @head_erb ||= File.read(File.join(ROOT, "app/views/layouts/studio/_head.html.erb"))
  end

  def engine_rb
    @engine_rb ||= File.read(File.join(ROOT, "lib/studio/engine.rb"))
  end

  def test_canvas_confetti_is_vendored_and_defines_the_global
    assert File.exist?(File.join(ROOT, "app/assets/javascripts/studio/canvas_confetti.js")),
      "canvas-confetti must be vendored at app/assets/javascripts/studio/canvas_confetti.js"
    # Provenance header names the pinned source, and the minified UMD body is present.
    assert_includes vendored_lib, "canvas-confetti v1.9.3",
      "the vendored file records its pinned version in the header"
    assert_match(/module\.exports|function confetti|\.create\b/, vendored_lib,
      "the vendored file carries the canvas-confetti implementation")
  end

  def test_studio_confetti_exposes_both_callable_effects
    assert_includes effect_js, "window.studioConfetti = studioConfetti",
      "the effect must publish window.studioConfetti"
    assert_match(/\bburst:\s*function/, effect_js,
      "window.studioConfetti.burst(target) must be defined")
    assert_match(/\bcannons:\s*function/, effect_js,
      "window.studioConfetti.cannons() must be defined")
    # burst aims from an element's center; cannons fires the L/R side-cannons.
    assert_includes effect_js, "getBoundingClientRect",
      "burst resolves an origin from the target element's box"
    assert_includes effect_js, "angle: 60", "cannons fires a left side-cannon"
    assert_includes effect_js, "angle: 120", "cannons fires a right side-cannon"
  end

  def test_both_effects_honor_reduced_motion
    assert_includes effect_js, "prefers-reduced-motion: reduce",
      "the effect must query prefers-reduced-motion"
    # Every public effect early-returns under reduced motion...
    assert_equal 2, effect_js.scan(/if \(typeof confetti === "undefined" \|\| reducedMotion\(\)\) return;/).length,
      "both burst and cannons must early-return under reduced motion"
    # ...and passes the canvas-confetti belt so any stray call is also disabled.
    assert_includes effect_js, "disableForReducedMotion: true",
      "confetti calls pass disableForReducedMotion as a second belt"
  end

  def test_head_loads_bundled_confetti_not_the_cdn
    assert_includes head_erb, %(javascript_include_tag "studio/canvas_confetti"),
      "the head must load the vendored canvas-confetti via the asset pipeline"
    assert_includes head_erb, %(javascript_include_tag "studio/studio_confetti"),
      "the head must load the studioConfetti effect via the asset pipeline"
    refute_includes head_erb, "cdn.jsdelivr.net/npm/canvas-confetti",
      "the head must NOT link the jsDelivr confetti CDN (bundled, CSP-safe)"
  end

  def test_assets_are_precompiled_and_packaged
    assert_includes engine_rb, "studio/canvas_confetti.js",
      "engine.rb must precompile the vendored canvas-confetti asset"
    assert_includes engine_rb, "studio/studio_confetti.js",
      "engine.rb must precompile the studioConfetti effect asset"

    spec = Gem::Specification.load(File.join(ROOT, "studio-engine.gemspec"))
    %w[
      app/assets/javascripts/studio/canvas_confetti.js
      app/assets/javascripts/studio/studio_confetti.js
    ].each do |path|
      assert_includes spec.files, path, "the gem must package #{path}"
    end
  end
end
