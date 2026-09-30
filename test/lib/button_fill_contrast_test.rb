# frozen_string_literal: true

require "test_helper"

# [unit] The filled buttons draw a white label (btn-primary, btn-success,
# btn-secondary's default, btn-outline's hover), so the fills the engine OWNS
# must clear WCAG AA 4.5:1 under white. The label is 14px bold, which is not
# WCAG "large" text.
#
# THE DEFECT THIS PINS (engine-navbar-phone-polish). The default success green
# #4BAF50 measured 2.78:1 under white, and the resolver emitted the brand
# colour itself as every button fill — the default primary #8E82FE at 3.1:1.
# The text inks were already derived for contrast; the fills were not.
#
# THE LINE IT HOLDS. Only DEFAULTS and the fills the engine derives move; an
# app's configured colours are its own. The default success green is itself
# AA. The default primary keeps its violet as --color-cta (apps also paint it
# as text on dark surfaces) and buttons paint a separate --color-cta-fill. A
# CONFIGURED primary gets no cta fill: btn-primary falls back to the app's own
# --color-cta (mcritchie-industries pairs a navy label with its orange; cyvasse
# sets --color-cta itself). A configured success colour paints as-is
# (turf-monster's suite pins that for #4BAF50).
class ButtonFillContrastTest < ActiveSupport::TestCase
  AA    = 4.5
  WHITE = "#ffffff"
  ROOT  = File.expand_path("../..", __dir__)

  def ratio(hex) = Studio::ColorScale.contrast_ratio(hex, WHITE)

  def modes(colors = {})
    res = Studio::ThemeResolver.new(colors)
    { dark: res.dark_mode_vars, light: res.light_mode_vars }
  end

  test "the default success green clears AA under white" do
    assert_equal "#367E3A", Studio::ThemeResolver::DEFAULT_SUCCESS
    assert_operator ratio(Studio::ThemeResolver::DEFAULT_SUCCESS), :>=, AA
    assert_equal Studio::ThemeResolver::DEFAULT_SUCCESS, Studio.theme_success, "lib/studio.rb's default must match"
  end

  test "the default theme's button fills clear AA under white in both modes" do
    modes.each do |mode, vars|
      %w[--color-cta-fill --color-cta-hover --color-success].each do |var|
        assert_operator ratio(vars.fetch(var)), :>=, AA, "#{mode} #{var} #{vars[var]} is #{ratio(vars[var]).round(2)}:1"
      end
    end
  end

  test "the default brand colours stay themselves; only the fills move" do
    modes.each do |mode, vars|
      assert_equal "#8E82FE", vars["--color-cta"], "#{mode}: the cta is still painted as text on dark surfaces"
      assert_equal "#7268CB", vars["--color-cta-fill"], "#{mode}: #8E82FE is 3.1:1 under white"
      assert_equal "#367E3A", vars["--color-success"]
    end
  end

  # Every palette the engine's consumers configure today, plus the old default
  # green and pathological light colours. The cta hover is derived for every
  # palette, so it must pass for ALL of them.
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
        %w[--color-cta-hover].each do |var|
          assert_operator ratio(vars.fetch(var)), :>=, AA, "#{palette.inspect} #{mode} #{var} #{vars[var]}"
        end
      end
    end
  end

  test "a configured colour that already passes keeps its exact hex" do
    vars = Studio::ThemeResolver.new(primary: "#2E7D32", success: "#2E7D32").light_mode_vars

    assert_equal "#2E7D32", vars["--color-cta"]
    assert_equal Studio::ColorScale.darken("#2E7D32", 0.30), vars["--color-cta-hover"],
      "hover is unchanged wherever darken(primary, 0.30) already passes"
  end

  test "a configured primary emits no cta fill, so buttons keep the app's own --color-cta" do
    # mcritchie-industries draws a navy label on #F68048 (6.02:1). A darkened
    # fill would drop that label to 3.3:1, so the configured primary stays.
    modes(primary: "#F68048").each_value do |vars|
      assert_equal "#F68048", vars["--color-cta"]
      refute vars.key?("--color-cta-fill"), "btn-primary must fall back to var(--color-cta)"
      assert_equal "#AC5A32", vars["--color-cta-hover"], "industries' white hover label stays 4.93:1"
    end
  end

  test "a configured success colour paints as-is, even the old failing green" do
    modes(success: "#4BAF50").each_value do |vars|
      assert_equal "#4BAF50", vars["--color-success"]
      refute vars.keys.any? { |k| k.start_with?("--color-success-fill") }, "no derived success fill"
    end
  end

  test "the button utilities paint the derived fills" do
    css = File.read(File.join(ROOT, "app/assets/tailwind/studio_engine/engine.css"))
    utility = ->(name) { css[/@utility #{name} \{.*?\n\}/m] }

    assert_includes utility.("btn-primary"), "background-color: var(--color-cta-fill, var(--color-cta));"
    assert_includes utility.("btn-outline"), "background-color: var(--color-cta-fill, var(--color-cta));",
      "btn-outline's hover draws a white label on the cta too"
    refute_match(/background-color: var\(--color-cta\);/, utility.("btn-primary"))
  end

  # --color-success is the brand green, and the default is now a DARKER green:
  # 3.49:1 as text on the default dark page, 2.23:1 on its surface. Text and
  # icons read --color-success-ink, derived to AA on every surface in both
  # modes (status_ink_contrast_test.rb).
  test "no engine view paints text or an icon with the raw success colour" do
    offenders = Dir.glob("#{ROOT}/app/views/**/*.erb").flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, i|
        "#{file.delete_prefix("#{ROOT}/")}:#{i + 1}" if line.match?(/(?<![-\w])color: var\(--color-success\)/)
      end
    end

    assert_empty offenders, "use var(--color-success-ink) for text: #{offenders.inspect}"
  end
end
