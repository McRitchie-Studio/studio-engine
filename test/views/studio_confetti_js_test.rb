# frozen_string_literal: true

require "test_helper"

# [component] Guard for the vendored, no-CDN confetti effect: canvas-confetti is
# shipped as an engine asset (studio/canvas_confetti.js, pinned "canvas-confetti")
# and the studio/studio_confetti ES module imports it and exports burst, cannons
# and confetti, honoring reduced motion, with window.studioConfetti kept as the
# deprecated compatibility global.
#
# Load-bearing invariants:
#   * canvas-confetti is VENDORED (not a CDN link) and defines the global confetti;
#   * window.studioConfetti exposes BOTH callable effects (burst + cannons);
#   * both effects guard prefers-reduced-motion (early return + the canvas-confetti
#     disableForReducedMotion belt);
#   * the engine head loads studio/studio_confetti as a module (which imports the
#     pinned library) and NO LONGER links the jsDelivr confetti CDN (CSP-safe,
#     same-origin);
#   * the assets are precompiled (prod) and packaged in the gem.
class StudioConfettiJsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def vendored_lib
    @vendored_lib ||= File.read(File.join(ROOT, "app/assets/javascripts/studio/canvas_confetti.js"))
  end

  def effect_js
    @effect_js ||= File.read(File.join(ROOT, "app/javascript/studio/studio_confetti.js"))
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
    assert_match(/^import "canvas-confetti"$/, effect_js,
      "the module imports the vendored library by its pin")
    assert_match(/^export function burst\(target, opts\)/, effect_js, "burst(target) is exported")
    assert_match(/^export function cannons\(opts\)/, effect_js, "cannons() is exported")
    assert_match(/^export function confetti\(opts\)/, effect_js, "the library call is exported")
    assert_match(/^export default studioConfetti$/, effect_js)
    assert_includes effect_js, "const studioConfetti = { burst, cannons }"
    assert_includes effect_js, "window.studioConfetti = studioConfetti",
      "the deprecated compatibility global window.studioConfetti stays for classic callers"
    # burst aims from an element's center; cannons fires the L/R side-cannons.
    assert_includes effect_js, "getBoundingClientRect",
      "burst resolves an origin from the target element's box"
    assert_includes effect_js, "angle: 60", "cannons fires a left side-cannon"
    assert_includes effect_js, "angle: 120", "cannons fires a right side-cannon"
  end

  def test_both_effects_honor_reduced_motion
    assert_includes effect_js, "prefers-reduced-motion: reduce",
      "the effect must query prefers-reduced-motion"
    # Every public effect early-returns under reduced motion, or without the library...
    assert_includes effect_js, %(return typeof window.confetti === "function" && !reducedMotion())
    assert_equal 2, effect_js.scan(/^  if \(!available\(\)\) return$/).length,
      "both burst and cannons must early-return under reduced motion"
    # ...and passes the canvas-confetti belt so any stray call is also disabled.
    assert_includes effect_js, "disableForReducedMotion: true",
      "confetti calls pass disableForReducedMotion as a second belt"
  end

  def test_head_loads_bundled_confetti_not_the_cdn
    assert_includes head_erb, %(javascript_include_tag "studio/studio_confetti", type: "module"),
      "the head must load the confetti module via the asset pipeline"
    refute_includes head_erb, %(javascript_include_tag "studio/canvas_confetti"),
      "the library arrives by the module's import, not a classic tag of its own"
    assert_operator head_erb.index("javascript_importmap_tags %>"), :<, head_erb.index(%(javascript_include_tag "studio/studio_confetti")),
      "a module tag above the import map makes older browsers ignore the map"
    refute_includes head_erb, "cdn.jsdelivr.net/npm/canvas-confetti",
      "the head must NOT link the jsDelivr confetti CDN (bundled, CSP-safe)"
  end

  def test_assets_are_precompiled_and_packaged
    assert_includes engine_rb, "studio/canvas_confetti.js",
      "engine.rb must precompile the vendored canvas-confetti asset"
    # The module is precompiled with every engine module: engine.rb enumerates
    # app/javascript from disk (javascript_module_logical_paths).
    assert_includes engine_rb, "app.config.assets.precompile += Studio::Engine.javascript_module_logical_paths"
    assert File.file?(File.join(ROOT, "app/javascript/studio/studio_confetti.js"))

    spec = Gem::Specification.load(File.join(ROOT, "studio-engine.gemspec"))
    %w[
      app/assets/javascripts/studio/canvas_confetti.js
      app/javascript/studio/studio_confetti.js
    ].each do |path|
      assert_includes spec.files, path, "the gem must package #{path}"
    end
  end
end
