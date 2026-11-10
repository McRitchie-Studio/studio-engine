# frozen_string_literal: true

require "test_helper"

# [unit] The glass sidebar takes its colours from four tokens on the root
# (engine.css, THE GLASS SIDEBAR), and the tokens' defaults are the hub's violet, so
# an app that sets none looks as it did. Each assertion reads a selector AND its
# declarations. The browser half (computed colours on a live panel, and an app's
# tokens reaching it) is e2e/sidebar_glass_tokens.spec.js.
class GlassSidebarTokensCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)).freeze

  def rule(selector)
    CSS[/^\s*#{Regexp.escape(selector)} \{[^}]*\}/] || flunk("no `#{selector}` rule in engine.css")
  end

  # The root rule that declares the tokens: engine.css has other :root and .dark rules.
  def token_rule(selector)
    CSS.scan(/^\s*#{Regexp.escape(selector)} \{[^}]*\}/).find { |r| r.include?("--glass-sidebar-") } ||
      flunk("no `#{selector}` rule declares a --glass-sidebar-* token")
  end

  def test_the_root_tokens_default_to_the_hubs_violet
    light = token_rule(":root")
    dark = token_rule(".dark")

    assert_includes light, "--glass-sidebar-fill: 250 249 253;"
    assert_includes light, "--glass-sidebar-ink: #1d1832;"
    assert_includes light, "--glass-sidebar-soft-ink: #474260;"
    assert_includes light, "--glass-sidebar-tint: 29 24 50;"
    assert_includes dark, "--glass-sidebar-fill: 36 30 62;"
    assert_includes dark, "--glass-sidebar-ink: #f1effa;"
    assert_includes dark, "--glass-sidebar-soft-ink: #dedaed;"
  end

  def test_the_light_shell_reads_the_tokens
    shell = rule("[data-sidebar-glass-shell]")

    assert_includes shell, "--glass-fill: rgb(var(--glass-sidebar-fill) / 0.97);"
    assert_includes shell, "--glass-ink: var(--glass-sidebar-ink);"
    assert_includes shell, "--glass-soft-ink: var(--glass-sidebar-soft-ink);"
    assert_includes shell, "--glass-hover: rgb(var(--glass-sidebar-tint) / 0.08);"
    assert_includes shell, "--glass-line: rgb(var(--glass-sidebar-tint) / 0.14);"
    assert_includes shell, "--glass-shadow: 0 24px 60px rgb(var(--glass-sidebar-tint) / 0.24);"
  end

  def test_the_dark_shell_reads_the_tokens
    shell = rule(".dark [data-sidebar-glass-shell]")

    assert_includes shell, "--glass-fill: rgb(var(--glass-sidebar-fill) / 0.97);"
    assert_includes shell, "--glass-thin-fill: rgb(var(--glass-sidebar-fill) / 0.72);"
    assert_includes shell, "--glass-ink: var(--glass-sidebar-ink);"
    assert_includes shell, "--glass-soft-ink: var(--glass-sidebar-soft-ink);"
  end

  # The violet lived in the shell's own declarations. None may come back there.
  def test_no_hub_violet_is_left_in_the_shell
    [rule("[data-sidebar-glass-shell]"), rule(".dark [data-sidebar-glass-shell]")].each do |shell|
      refute_match(/29 24 50|36 30 62|#1d1832|#474260|#f1effa|#dedaed/, shell)
    end
  end

  def test_the_lit_tile_classes_take_the_buttons_light
    tile = rule('html[data-surface-style="glass"] .lit-tile')
    soft = rule('html[data-surface-style="glass"] .lit-tile-soft')

    assert_includes tile, "var(--lit-top), var(--lit-bottom), var(--lit-contact)"
    assert_includes soft, "var(--lit-soft-top), var(--lit-soft-bottom), var(--lit-contact)"
  end
end
