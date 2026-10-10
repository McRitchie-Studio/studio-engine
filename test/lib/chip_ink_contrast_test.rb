# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"
require_relative "../support/consumer_palettes"

# [unit] A chip's ink clears WCAG AA on its own tint, in both themes, for the
# engine's defaults, for each consuming app's configured colours, and across a
# spread of colours an operator could pick. A primary chip's ink is a shade of
# the primary colour.
#
# The chip is `bg-<role>/10 text-<role>-ink`. The tint is graded at both
# strengths a browser paints it (ThemeResolver::TINT_ALPHAS): e2e/chip_contrast.spec.js
# reads the painted pixels, and this is the same claim over every palette.
#
# CONTROLS, each run against this file:
#   - status_ink searching STATUS_TINT alone: the consumer and default cases
#     fail (default light success 4.49:1, mcritchie-industries dark danger 4.49:1).
#   - status_ink searching the bare surfaces: every case fails.
#   - --color-primary-ink set to --color-text: the hue test fails.
class ChipInkContrastTest < ActiveSupport::TestCase
  AA    = 4.5
  ROLES = { "success" => "--color-success", "warning" => "--color-warning",
            "danger" => "--color-danger", "primary" => "--color-primary" }.freeze

  # Operator-chosen role colours: the mid-grey and the saturated yellows an ink
  # search fails on first, both extremes, and the primaries.
  AWKWARD = %w[#808080 #FFFF00 #FFD700 #FAFAFA #050505 #0000FF #00FF00 #FF0000 #FF00FF].freeze
  BASES   = [{}, { dark: "#000000", light: "#FFFFFF" }, { dark: "#0B1020", light: "#FFF4E0" },
             { dark: "#2A1010", light: "#E8EEF5" }].freeze

  def modes(palette)
    res = Studio::ThemeResolver.new(palette)
    { dark: [res.dark_mode_vars.merge(res.primary_palette_vars), res.dark_surfaces(palette[:dark] || "#1A1535")],
      light: [res.light_mode_vars.merge(res.primary_palette_vars), res.light_surfaces(palette[:light] || "#f8fafc")] }
  end

  # The lowest contrast of each role's ink on its tint, over every surface and
  # both painted tint strengths: { [mode, role] => ratio }.
  def worst_on_tint(palette)
    modes(palette).each_with_object({}) do |(mode, (vars, surfaces)), worst|
      ROLES.each do |role, colour_var|
        ink = vars.fetch("--color-#{role}-ink") { flunk "#{mode} emits no --color-#{role}-ink" }
        tints = Studio::ThemeResolver::TINT_ALPHAS.flat_map do |alpha|
          surfaces.map { |bg| Studio::ColorScale.blend(vars.fetch(colour_var), bg, alpha) }
        end
        worst[[mode, role]] = tints.map { |bg| Studio::ColorScale.contrast_ratio(ink, bg) }.min
      end
    end
  end

  def assert_chips_clear_aa(name, palette)
    worst_on_tint(palette).each do |(mode, role), ratio|
      assert_operator ratio, :>=, AA, "#{name} #{mode}: #{role} ink on its tint is #{ratio.round(2)}:1"
    end
  end

  def hue(hex)
    r, g, b = Studio::ColorScale.hex_to_rgb(hex).map { |c| c / 255.0 }
    max = [r, g, b].max
    delta = max - [r, g, b].min
    return nil if delta.zero?

    sector = if max == r then ((g - b) / delta) % 6
             elsif max == g then ((b - r) / delta) + 2
             else ((r - g) / delta) + 4
             end
    (sector * 60) % 360
  end

  ConsumerPalettes::ALL.each do |name, palette|
    test "#{name}: every role's ink clears AA on its tint in both themes" do
      assert_chips_clear_aa(name, palette)
    end

    test "#{name}: the primary ink is a shade of the primary colour in both themes" do
      modes(palette).each do |mode, (vars, _surfaces)|
        ink = vars.fetch("--color-primary-ink")
        primary = vars.fetch("--color-primary")
        refute_equal vars.fetch("--color-text").downcase, ink.downcase, "#{name} #{mode}: the primary ink is the heading colour"
        assert hue(ink), "#{name} #{mode}: the primary ink #{ink} is a grey"
        apart = (hue(ink) - hue(primary)).abs

        assert_operator [apart, 360 - apart].min, :<=, 8, "#{name} #{mode}: ink #{ink} has left the hue of #{primary}"
      end
    end
  end

  test "an awkward colour in every role clears AA on its tint on every base" do
    BASES.each do |base|
      AWKWARD.each do |colour|
        palette = base.merge(primary: colour, success: colour, warning: colour, danger: colour)
        assert_chips_clear_aa(palette.inspect, palette)
      end
    end
  end

  # THE CONTROL for the palettes above: the role colours themselves fail as chip
  # text, so the derivation is doing the work.
  test "the raw primary colour fails AA on its own tint in every consumer palette" do
    ConsumerPalettes::ALL.each do |name, palette|
      modes(palette).each do |mode, (vars, surfaces)|
        primary = vars.fetch("--color-primary")
        worst = surfaces.map { |bg| Studio::ColorScale.contrast_ratio(primary, Studio::ColorScale.blend(primary, bg, 0.10)) }.min

        assert_operator worst, :<, AA, "#{name} #{mode}: the raw primary now clears its tint; rewrite this control"
      end
    end
  end

  # THE LIMIT, named. A mid-grey dark BASE spreads its four surfaces so far
  # apart that no colour clears AA on all of them: white fails on the lightest
  # and black on the darkest. The search clamps and returns its best effort.
  test "a mid-grey dark base has no ink that clears every surface" do
    surfaces = Studio::ThemeResolver.new(dark: "#808080").dark_surfaces("#808080")
    lightest, darkest = surfaces.minmax_by { |bg| Studio::ColorScale.relative_luminance(bg) }.reverse

    assert_operator Studio::ColorScale.contrast_ratio("#FFFFFF", lightest), :<, AA
    assert_operator Studio::ColorScale.contrast_ratio("#000000", darkest), :<, AA
  end

  test "the tint is graded at the alpha an 8-bit channel paints" do
    assert_equal [0.10, 26 / 255.0], Studio::ThemeResolver::TINT_ALPHAS
  end

  test "the preset mints text-primary-ink and the theme stylesheet declares it in both blocks" do
    compiled = EngineTailwindBuild.classes_in_css(EngineTailwindBuild.compile(%w[text-primary-ink bg-primary/10], motion: false))
    assert_includes compiled, "text-primary-ink"

    css = Studio::ThemeResolver.new.to_css
    assert_equal 2, css.scan(/--color-primary-ink:\s*#[0-9A-Fa-f]{6};/).size, "one primary ink per theme block"
  end
end
