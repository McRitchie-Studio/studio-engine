# frozen_string_literal: true

require "test_helper"

# [component] Guard for the OPT-IN motion / effect primitive layer shipped at
# app/assets/tailwind/studio_engine/engine-motion.css. Mirrors ComponentCssTest
# but for the seven consolidated animation primitives.
#
# The load-bearing invariants:
#   * every primitive ships BOTH its class AND its @keyframes (except the static
#     fade-edge, which is a pure mask with no animation);
#   * every theme CSS var the layer references is emitted in BOTH dark and light
#     mode (a var live only in one mode renders invisible in the other) — the
#     visual-regression guard;
#   * the file is authored as plain classes, NOT @utility (a v4 @utility
#     redeclaration is additive — the wrong shape for net-new primitives);
#   * it stays OPT-IN: it is NOT the engines-contract engine.css, and engine.css
#     does not @import it, so `tailwindcss:engines` never auto-bundles it;
#   * the gem packages the file.
class EngineMotionCssTest < Minitest::Test
  CSS_PATH = File.expand_path(
    "../../app/assets/tailwind/studio_engine/engine-motion.css", __dir__
  )
  ENGINE_CSS_PATH = File.expand_path(
    "../../app/assets/tailwind/studio_engine/engine.css", __dir__
  )

  # primitive class => its @keyframes (nil for the static, animation-free one).
  # A representative selector token for families (fade-edge-*, progress-meter-*).
  PRIMITIVES = {
    "studio-border-glow" => "studioBorderGlowSteam",
    "spinner"            => "spin",
    "loading-dots"       => "loading-dots-bounce",
    "sheen"              => "sheen-sweep",
    "ping"               => "ping-pulse",
    "fade-edge"          => nil,
    "progress-meter"     => "progress-indeterminate"
  }.freeze

  def css
    @css ||= File.read(CSS_PATH)
  end

  def test_stylesheet_exists_at_the_engine_tailwind_namespace_path
    assert File.exist?(CSS_PATH),
      "expected app/assets/tailwind/studio_engine/engine-motion.css"
  end

  def test_every_primitive_defines_its_class
    PRIMITIVES.each_key do |name|
      assert_match(/\.#{Regexp.escape(name)}\b/, css,
        "engine-motion.css must define the .#{name} primitive class")
    end
  end

  def test_every_animated_primitive_defines_its_keyframes
    PRIMITIVES.each do |name, keyframe|
      next if keyframe.nil?

      assert_match(/@keyframes\s+#{Regexp.escape(keyframe)}\b/, css,
        "primitive .#{name} must ship its @keyframes #{keyframe}")
      # The class must actually reference the keyframe it ships.
      assert_includes css, keyframe,
        "primitive .#{name} must reference its keyframe #{keyframe}"
    end
  end

  def test_authored_as_plain_classes_not_utilities
    # Match a real `@utility <name>` directive, not the word where the header
    # comment merely names the trap it is avoiding.
    refute_match(/@utility\s+[\w-]/, css,
      "engine-motion.css must use plain .class rules, not @utility " \
      "(v4 @utility redeclaration is additive — the wrong shape for these primitives)")
  end

  def test_every_theme_var_referenced_is_emitted_in_both_modes
    resolver = Studio::ThemeResolver.new
    palette  = resolver.primary_palette_vars.keys

    referenced = css.scan(/var\((--color-[\w-]+)\)/).flatten.to_set
    refute_empty referenced.to_a,
      "expected engine-motion.css to theme its primitives through --color-* vars"

    # Per mode, not the union: a var emitted only in dark mode would satisfy a
    # union check while rendering invisible in light mode.
    { "dark"  => resolver.dark_mode_vars.keys,
      "light" => resolver.light_mode_vars.keys }.each do |mode, keys|
      unknown = referenced - (keys + palette).to_set
      assert_empty unknown.to_a,
        "engine-motion.css references theme vars not emitted in #{mode} mode: " \
        "#{unknown.to_a.sort.join(', ')}"
    end
  end

  def test_layer_stays_opt_in_not_auto_bundled
    # `Tailwindcss::Engines.bundle` auto-generates a consumer entry ONLY for the
    # file literally named engine.css. This file is a sibling, and engine.css
    # must not pull it in — otherwise it would ride the auto-bundle.
    refute_equal File.basename(ENGINE_CSS_PATH), File.basename(CSS_PATH),
      "the motion layer must not be named engine.css or it would auto-bundle"

    engine_css = File.read(ENGINE_CSS_PATH)
    refute_match(/@import[^;]*engine-motion/, engine_css,
      "engine.css must NOT @import engine-motion.css — the motion layer is opt-in")
  end

  def test_pulse_cta_ships_class_keyframe_role_token_and_reduced_motion
    # The class + its namespaced keyframe both ship.
    assert_match(/\.pulse-cta\b/, css,
      "engine-motion.css must define the .pulse-cta attention primitive")
    assert_match(/@keyframes\s+pulse-cta\b/, css,
      "the .pulse-cta primitive must ship its @keyframes pulse-cta")
    assert_includes css, "animation: pulse-cta var(--pulse-cta-speed",
      ".pulse-cta must reference its own keyframe via a tunable speed knob"
    # Themed off a ROLE token by default (CTA), not TM's hardcoded green — so it
    # restyles per app.
    assert_includes css, "--pulse-cta-color: var(--color-cta)",
      ".pulse-cta defaults its color to the CTA role token (themeable per app)"
    # Reduced-motion safety: the pulse no-ops under prefers-reduced-motion.
    assert_includes css, ".pulse-cta { animation: none; }",
      ".pulse-cta must be disabled under prefers-reduced-motion"
    # It must NOT be named btn-* — that collides with the engine.css .btn component
    # contract (ComponentCssTest), and this is a plain motion-layer effect.
    refute_match(/\.btn-pulse\b/, css,
      "the pulse must stay .pulse-cta, not a .btn-* component variant")
  end

  def test_gem_packages_the_stylesheet
    spec = Gem::Specification.load(File.expand_path("../../studio-engine.gemspec", __dir__))
    assert_includes spec.files, "app/assets/tailwind/studio_engine/engine-motion.css",
      "gemspec files must package the motion primitive stylesheet"
  end
end
