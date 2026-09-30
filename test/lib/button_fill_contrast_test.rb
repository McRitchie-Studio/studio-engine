# frozen_string_literal: true

require "test_helper"

# [unit] The filled buttons draw a white label (btn-primary, btn-success,
# btn-secondary's default), so the fills the engine OWNS must clear WCAG AA
# 4.5:1 under white. The label is 14px bold, which is not WCAG "large" text.
#
# THE DEFECT THIS PINS (engine-navbar-phone-polish). The default success green
# #4BAF50 measured 2.78:1 under white, and the resolver emitted the brand
# colour itself as every button fill — the default primary #8E82FE at 3.1:1.
# The text inks were already derived for contrast; the fills were not.
#
# THE LINE IT HOLDS. An app's CONFIGURED colours are not the engine's to
# repaint: a configured primary stays the cta as-is (mcritchie-industries
# pairs a navy label with its orange), and --color-success stays the
# configured green. Only defaults and the DERIVED shades — --color-success-fill,
# --color-cta-hover, and the default primary's cta — are held to AA here.
class ButtonFillContrastTest < ActiveSupport::TestCase
  AA    = 4.5
  WHITE = "#ffffff"

  def ratio(hex) = Studio::ColorScale.contrast_ratio(hex, WHITE)

  def modes(colors = {})
    res = Studio::ThemeResolver.new(colors)
    { dark: res.dark_mode_vars, light: res.light_mode_vars }
  end

  test "the default success green clears AA under white" do
    assert_equal "#367E3A", Studio::ThemeResolver::DEFAULT_SUCCESS
    assert_operator ratio(Studio::ThemeResolver::DEFAULT_SUCCESS), :>=, AA
    assert_operator ratio(Studio.theme_success), :>=, AA, "lib/studio.rb's default must match"
  end

  test "the default theme's button fills clear AA under white in both modes" do
    modes.each do |mode, vars|
      %w[--color-cta --color-cta-hover --color-success --color-success-fill].each do |var|
        assert_operator ratio(vars.fetch(var)), :>=, AA, "#{mode} #{var} #{vars[var]} is #{ratio(vars[var]).round(2)}:1"
      end
    end
  end

  test "the default primary stays the brand violet; only its fill moves" do
    modes.each do |mode, vars|
      refute_equal "#8E82FE", vars.fetch("--color-cta"), "#{mode}: 3.1:1 under white is the bug"
    end
    assert_equal "#8E82FE", Studio::ThemeResolver.new({}).primary_palette_vars["--color-primary"]
  end

  # Every palette the engine's consumers configure today, plus the old default
  # green and pathological light colours. The success fill and the cta hover
  # are derived, so they must pass for ALL of them.
  PALETTES = [
    { primary: "#2E7D32", success: "#2E7D32" },           # turf-monster
    { primary: "#F68048", warning: "#F5C518" },           # mcritchie-industries
    { primary: "#0F766E" },                               # acquisition-studio
    { primary: "#C08A2E", success: "#367E3A" },           # cyvasse
    { primary: "#4BAF50", success: "#4BAF50" },           # the old default green, configured
    { primary: "#FFD700", success: "#A7F3D0" },           # light pathologicals
    { primary: "#FFFFFF", success: "#FFFFFF" }            # clamps at black, never loops
  ].freeze

  test "derived fills clear AA under white for every palette" do
    PALETTES.each do |palette|
      modes(palette).each do |mode, vars|
        %w[--color-success-fill --color-cta-hover].each do |var|
          assert_operator ratio(vars.fetch(var)), :>=, AA, "#{palette.inspect} #{mode} #{var} #{vars[var]}"
        end
      end
    end
  end

  test "a configured colour that already passes keeps its exact hex" do
    vars = Studio::ThemeResolver.new(primary: "#2E7D32", success: "#2E7D32").light_mode_vars

    assert_equal "#2E7D32", vars["--color-success-fill"], "start 0.0: a passing green is not darkened"
    assert_equal "#2E7D32", vars["--color-cta"]
    assert_equal Studio::ColorScale.darken("#2E7D32", 0.30), vars["--color-cta-hover"],
      "hover is unchanged wherever darken(primary, 0.30) already passes"
  end

  test "a configured primary is never repainted, even when it fails under white" do
    # mcritchie-industries draws a navy label on #F68048 (6.02:1). A darkened
    # fill would drop that label to 3.3:1, so the configured primary stays.
    modes(primary: "#F68048").each_value do |vars|
      assert_equal "#F68048", vars["--color-cta"]
      assert_equal "#AC5A32", vars["--color-cta-hover"], "industries' white hover label stays 4.93:1"
    end
  end

  test "a configured success colour is never repainted; its button fill is" do
    modes(success: "#4BAF50").each_value do |vars|
      assert_equal "#4BAF50", vars["--color-success"]
      refute_equal "#4BAF50", vars["--color-success-fill"]
    end
  end

  test "the button utilities paint the derived fills" do
    css = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
    success = css[/@utility btn-success \{.*?\n\}/m]
    secondary = css[/@utility btn-secondary \{.*?\n\}/m]

    assert_includes success, "background-color: var(--color-success-fill, var(--color-success));"
    assert_includes secondary, "var(--btn-secondary-bg, var(--color-success-fill, var(--color-success)))"
    refute_match(/background-color: var\(--color-success\);/, success)
  end
end
