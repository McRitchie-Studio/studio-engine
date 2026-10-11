# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"
require_relative "../support/consumer_palettes"

# [unit] A chip's ink clears WCAG AA on its own tint, in both themes, for the
# engine's defaults, for each consuming app's configured colours, and across a
# spread of colours an operator could pick. A primary chip's ink is a shade of
# the primary colour.
#
# The chip is `bg-<role>/10 text-<role>-ink`, and the apps also put an ink on
# its role's 15% and 20% tints (turf's "Entered" badge is `bg-primary/15`, the
# hub's workflow chips `bg-success/20 text-success-ink`). The tint is graded at
# PAINTED_TINTS, a list this file owns: the 10% chip as written and as Chromium
# composites it (26/255), and the 15% and 20% tints. It is not read from
# ThemeResolver::TINT_ALPHAS, so a resolver that stops counting a strength goes
# red here instead of grading itself. e2e/chip_contrast.spec.js reads the painted
# pixels; this is the same claim over every palette.
#
# CONTROLS, each run against this file:
#   - TINT_ALPHAS back to the 10% chip alone ([0.10, 26/255]): every consumer
#     palette fails on a 15% or 20% tint (turf dark primary 4.25:1 and light
#     4.02:1 on 20%, default dark warning 3.89:1 on 20%).
#   - status_ink searching STATUS_TINT alone: the same, and the 26/255 cases.
#   - status_ink without the one-unit rounding neighbours: the consumer
#     palettes fail by a hair on a painted neighbour (default dark warning
#     4.46:1; e2e/chip_contrast.spec.js read default dark danger at 4.47:1 on
#     the 20% chip on screen).
#   - status_ink searching the bare surfaces: every case fails.
#   - --color-primary-ink set to --color-text: the hue test fails.
class ChipInkContrastTest < ActiveSupport::TestCase
  AA    = 4.5
  # Every tint strength a chip's ink is read on, as the browser paints it.
  PAINTED_TINTS = [0.10, 26 / 255.0, 0.15, 0.20].freeze
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
  # every painted tint strength: { [mode, role] => ratio }.
  def worst_on_tint(palette)
    modes(palette).each_with_object({}) do |(mode, (vars, surfaces)), worst|
      ROLES.each do |role, colour_var|
        ink = vars.fetch("--color-#{role}-ink") { flunk "#{mode} emits no --color-#{role}-ink" }
        tints = PAINTED_TINTS.flat_map do |alpha|
          surfaces.flat_map { |bg| painted(Studio::ColorScale.blend(vars.fetch(colour_var), bg, alpha)) }
        end
        worst[[mode, role]] = tints.map { |bg| Studio::ColorScale.contrast_ratio(ink, bg) }.min
      end
    end
  end

  # A tint as a browser may paint it: the exact blend, or one unit off in every
  # channel (8-bit compositing rounds the fill's share and the surface's share
  # separately; Chromium paints the default danger at 20% over #3C3853 as
  # #603B50, not the #5F3A50 blend).
  def painted(tint)
    rgb = Studio::ColorScale.hex_to_rgb(tint)
    [tint, *[1, -1].map { |d| Studio::ColorScale.rgb_to_hex(*rgb.map { |c| c + d }) }]
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

  test "the resolver counts every tint strength a chip is painted at" do
    assert_equal PAINTED_TINTS, Studio::ThemeResolver::TINT_ALPHAS
  end

  # The 15% and 20% tints are not redundant with the 10% chip: an ink tuned to
  # the 10% chip alone fails on them, in turf's palette and the default.
  test "an ink tuned to the 10 percent chip alone fails on the 20 percent tint" do
    { "turf-monster" => ConsumerPalettes::ALL.fetch("turf-monster"), "engine-default" => {} }.each do |name, palette|
      resolver = Studio::ThemeResolver.new(palette)
      surfaces = resolver.dark_surfaces(palette[:dark] || "#1A1535")
      primary = resolver.primary_palette_vars.fetch("--color-primary")
      chip_only = surfaces + PAINTED_TINTS.first(2).flat_map { |a| surfaces.map { |bg| Studio::ColorScale.blend(primary, bg, a) } }
      ink = resolver.send(:contrast_ink, primary, direction: :lighten, start: 0.0, target: AA, against: chip_only)
      worst = surfaces.map { |bg| Studio::ColorScale.contrast_ratio(ink, Studio::ColorScale.blend(primary, bg, 0.20)) }.min

      assert_operator worst, :<, AA, "#{name} dark: an ink tuned to 10% now clears 20% too; this control proves nothing"
    end
  end

  test "the preset mints text-primary-ink and the theme stylesheet declares it in both blocks" do
    compiled = EngineTailwindBuild.classes_in_css(EngineTailwindBuild.compile(%w[text-primary-ink bg-primary/10], motion: false))
    assert_includes compiled, "text-primary-ink"

    css = Studio::ThemeResolver.new.to_css
    assert_equal 2, css.scan(/--color-primary-ink:\s*#[0-9A-Fa-f]{6};/).size, "one primary ink per theme block"
  end
end
