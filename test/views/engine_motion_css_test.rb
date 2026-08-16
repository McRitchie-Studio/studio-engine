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

  # The declaration block of ONE rule. No rule in this file nests braces, so a
  # non-greedy scan to the first `}` is exact — and anchoring the selector to the
  # start of a line followed by `{` keeps `.conic-surface` from matching
  # `.conic-surface::before`.
  def rule_body(selector)
    match = css.match(/^#{Regexp.escape(selector)}\s*\{([^}]*)\}/)
    refute_nil match, "expected engine-motion.css to define #{selector}"
    match[1]
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

  # THE CONIC WASH IS CONTAINED BY CONSTRUCTION, NOT BY A CLIP.
  #
  # The first cut rotated an OVERSIZED pseudo (`inset: -50%` + a transform
  # keyframe) and leaned on the host's `overflow: hidden` to cut it back to the
  # box. That clip does not hold: the rotating child is composited, and a
  # `backdrop-filter` in its compositing path drops it — the wash then paints
  # outside the box as a rotated slab. Measured, not reasoned about: on
  # admin/style in Chromium it escaped on BOTH conic specimens, with the
  # .surface-glass demo (a backdrop-filter child of the wash itself) the reliable
  # trigger.
  #
  # So this asserts the SHAPE that cannot escape rather than the clip that was
  # supposed to save it — a pseudo pinned to the host's own box, rounded with it,
  # swept by a registered angle inside the gradient. Reintroduce the oversized
  # rotating child and this fails here, not on somebody's screen.
  def test_conic_surface_wash_cannot_paint_outside_its_own_box
    assert_match(/@property\s+--conic-surface-angle\s*\{[^}]*syntax:\s*"<angle>"/m, css,
      "the conic wash must register --conic-surface-angle to sweep the gradient")

    wash = rule_body(".conic-surface::before")

    assert_match(/\binset:\s*0\s*;/, wash,
      ".conic-surface::before must sit at inset: 0 — an oversized pseudo stays inside " \
      "the box only while a clip holds, and that clip is lost next to a backdrop-filter")
    refute_match(/\binset:\s*-/, wash,
      ".conic-surface::before must never be oversized")
    assert_match(/border-radius:\s*inherit/, wash,
      ".conic-surface::before must inherit the host's radius — square corners would be " \
      "rounded only by overflow:hidden, which is the clip this shape stops trusting")
    assert_match(/conic-gradient\(\s*from\s+var\(--conic-surface-angle\)/m, wash,
      "the sweep must rotate the GRADIENT (the registered angle), not the element")

    # Pin the whole keyframe body: it animates the angle, and nothing else. A
    # transform here would move the pseudo again and put the escape back.
    assert_match(
      /@keyframes\s+conic-surface-spin\s*\{\s*to\s*\{\s*--conic-surface-angle:\s*360deg;?\s*\}\s*\}/m,
      css,
      "conic-surface-spin must animate --conic-surface-angle to 360deg and nothing else"
    )
  end

  # The ring's contract, stated where a reader of the CSS will hit it: the host is
  # a bare wrapper. Its own background can never cover the wedges (an element's
  # background paints BEFORE its negative-z descendants), so the recipe in the file
  # must not teach `bg-` on the glow element — that is the exact form that shipped
  # a washed card to admin/style. The rendered proof is in StylePageTest.
  def test_selection_glow_documents_the_opaque_child_contract
    section = css[/9b\. studio-team-glow.*?={10,}\s*\*\//m]
    refute_nil section, "expected the §9b selection-glow doc block"

    assert_match(/opaque CHILD/i, section,
      "§9b must state that an opaque CHILD covers the middle, not the host's background")
    usage = section[/Usage:.*?Tune:/m].to_s
    refute_match(/studio-team-glow[^\n]*\bbg-/, usage,
      "the §9b usage recipe must not put a background on the glow host — that host is " \
      "a bare wrapper, and a background on it is painted over by the wedges")
  end

  def test_gem_packages_the_stylesheet
    spec = Gem::Specification.load(File.expand_path("../../studio-engine.gemspec", __dir__))
    assert_includes spec.files, "app/assets/tailwind/studio_engine/engine-motion.css",
      "gemspec files must package the motion primitive stylesheet"
  end
end
