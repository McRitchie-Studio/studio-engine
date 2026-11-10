# frozen_string_literal: true

require "test_helper"

# [unit] The glass surfaces take their light-theme tint from two tokens on the root
# (engine.css, THE GLASS SURFACES), and the tokens' defaults are the hub's violet, so
# an app that sets none looks as it did. Each assertion reads a selector AND its
# declarations. The browser half (computed values, an app's tokens reaching each one,
# and a token in @layer components losing) is e2e/glass_surface_tokens.spec.js.
class GlassSurfaceTokensCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)).freeze
  LIGHT = 'html[data-surface-style="glass"]'
  DARK = 'html.dark[data-surface-style="glass"]'

  # engine.css has more than one rule on each of these selectors: find the one that
  # declares the property.
  def rule_declaring(selector, property)
    CSS.scan(/^\s*#{Regexp.escape(selector)} \{[^}]*\}/).find { |r| r.include?("#{property}:") } ||
      flunk("no `#{selector}` rule declares #{property}")
  end

  def test_the_root_tokens_default_to_the_hubs_violet
    root = rule_declaring(":root", "--glass-surface-tint")

    assert_includes root, "--glass-surface-tint: 29 24 50;"
    assert_includes root, "--glass-surface-shadow-tint: 60 50 120;"
  end

  def test_the_light_surfaces_read_the_tokens
    surfaces = rule_declaring(LIGHT, "--surface-glass-line")
    lights = rule_declaring(LIGHT, "--lit-soft-bottom")

    assert_includes surfaces, "--surface-glass-line: rgb(var(--glass-surface-tint) / 0.1);"
    assert_includes surfaces, "--surface-glass-shadow: 0 6px 20px rgb(var(--glass-surface-shadow-tint) / 0.08);"
    assert_includes lights, "--lit-soft-bottom: inset 0 -1px 0 rgb(var(--glass-surface-tint) / 0.08);"
    assert_includes lights, "--lit-soft-pressed: inset 0 2px 3px rgb(var(--glass-surface-tint) / 0.16);"
    assert_includes lights, "--lit-badge: inset 0 1px 0 rgb(255 255 255 / 0.5), 0 1px 1px rgb(var(--glass-surface-tint) / 0.12);"
    assert_includes lights, "--lit-input: inset 0 1px 2px rgb(var(--glass-surface-tint) / 0.14), inset 0 -1px 0 rgb(255 255 255 / 0.6);"
  end

  # The violet lived in these rules' own declarations. None may come back there.
  def test_no_hub_violet_is_left_in_the_surface_rules
    [
      rule_declaring(LIGHT, "--surface-glass-line"), rule_declaring(LIGHT, "--lit-soft-bottom"),
      rule_declaring(DARK, "--surface-glass-line"), rule_declaring(DARK, "--lit-soft-bottom")
    ].each { |r| refute_match(/29 24 50|60 50 120/, r) }
  end
end
