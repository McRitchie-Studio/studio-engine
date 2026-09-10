# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"

# [unit] Every status ink (danger, warning, success) must clear WCAG AA on every
# surface AND on its own role's tint, in both themes.
#
# THE DEFECT THIS PINS. Engine views wrote text-warning, text-danger and
# text-success, and the shared preset registered none of them, so each compiled
# to nothing and painted the inherited colour. Registering them as-is would have
# swapped one defect for another: measured on the default theme, the role
# colours as light-surface text are warning #FF7C47 at 2.04:1, success #4BAF50
# at 2.22:1 and danger #EF4444 at 3.01:1, all under AA's 4.5:1. So the text form
# of each role is an INK, derived per theme by ThemeResolver#status_ink, the
# contract danger-ink already set (test/lib/danger_ink_contrast_test.rb).
#
# THE TINT. These inks are mostly read INSIDE their own tint: the badge
# `bg-warning/10 text-warning-ink border-warning/30` and the flash panel
# `bg-danger/10 text-danger-ink`. An ink tuned to the bare surfaces alone
# measured 3.91:1 (warning, dark) and 4.10:1 (danger, light) there. So the
# search counts the 10% tint over each surface as a surface too.
#
# Like its danger sibling, this asserts the PROPERTY on the resolver's own
# surfaces rather than pinning hexes, which would freeze one palette.
class StatusInkContrastTest < ActiveSupport::TestCase
  AA    = 4.5
  ROLES = %w[danger warning success].freeze

  def resolver(colors = {}) = Studio::ThemeResolver.new(colors)

  # Every background the ink can sit on in one mode: the surfaces, and the
  # role's own 10% tint composited over each of them.
  def backgrounds(role_colour, surfaces)
    surfaces + surfaces.map { |bg| Studio::ColorScale.blend(role_colour, bg, Studio::ThemeResolver::STATUS_TINT) }
  end

  def modes(res, palette)
    { dark: [res.dark_mode_vars, res.send(:dark_surfaces, palette[:dark] || "#1A1535")],
      light: [res.light_mode_vars, res.send(:light_surfaces, palette[:light] || "#f8fafc")] }
  end

  def assert_inks_clear_aa(palette)
    res = resolver(palette)
    modes(res, palette).each do |mode, (vars, surfaces)|
      ROLES.each do |role|
        ink = vars["--color-#{role}-ink"]

        assert ink, "#{mode} emits no --color-#{role}-ink"
        backgrounds(vars["--color-#{role}"], surfaces).each do |bg|
          ratio = Studio::ColorScale.contrast_ratio(ink, bg)

          assert_operator ratio, :>=, AA, "#{palette.inspect} #{mode} #{role} ink #{ink} on #{bg} is #{ratio.round(2)}:1"
        end
      end
    end
  end

  def test_the_default_theme_emits_inks_that_clear_aa_on_surfaces_and_tints_in_both_modes
    assert_inks_clear_aa({})
  end

  # DERIVED, NOT TUNED: the operator picks these colours in the theme editor.
  # A near-white and a near-black role colour, on both default and unusual bases.
  def test_the_search_holds_for_operator_chosen_status_colours
    [
      { warning: "#FFD166", success: "#06D6A0", danger: "#FCA5A5" },
      { warning: "#7A2C1C", success: "#025E40", danger: "#7F1D1D", dark: "#0B1020", light: "#ffffff" },
      { warning: "#FFFF00", success: "#00FF00", danger: "#FF0000" }
    ].each { |palette| assert_inks_clear_aa(palette) }
  end

  # THE CONTROL for the inks: the raw role colours fail as light-surface text,
  # so the derivation is doing work and the assertions above are not vacuous.
  def test_the_raw_default_role_colours_fail_aa_as_light_surface_text
    surfaces = resolver.send(:light_surfaces, "#f8fafc")

    { "warning" => "#FF7C47", "success" => "#4BAF50", "danger" => "#EF4444" }.each do |role, hex|
      assert surfaces.all? { |bg| Studio::ColorScale.contrast_ratio(hex, bg) < AA },
             "the default #{role} colour now passes AA as text; rewrite this control, do not delete it"
    end
  end

  # THE CONTROL for the tint: an ink searched against the bare surfaces alone
  # falls under AA inside its own tint, so counting the tint is load-bearing.
  def test_an_ink_tuned_to_bare_surfaces_fails_inside_its_own_tint
    res = resolver
    vars = res.dark_mode_vars
    surfaces = res.send(:dark_surfaces, "#1A1535")
    bare = res.send(:contrast_ink, vars["--color-warning"], direction: :lighten, start: 0.0, target: AA,
                                                            against: surfaces)
    worst = backgrounds(vars["--color-warning"], surfaces).map { |bg| Studio::ColorScale.contrast_ratio(bare, bg) }.min

    assert_operator worst, :<, AA, "a bare-surface warning ink now clears its own tint; the tint term proves nothing"
  end

  # A theme whose colour ALREADY passes keeps its exact brand hex.
  def test_a_passing_colour_is_left_untouched
    vars = resolver(warning: "#7A2C1C", success: "#025E40").light_mode_vars

    assert_equal "#7A2C1C", vars["--color-warning-ink"].upcase
    assert_equal "#025E40", vars["--color-success-ink"].upcase
  end

  def test_blend_composites_like_a_translucent_fill
    assert_equal "#FFFFFF", Studio::ColorScale.blend("#000000", "#ffffff", 0.0)
    assert_equal "#000000", Studio::ColorScale.blend("#000000", "#ffffff", 1.0)
    assert_equal "#E6E6E6", Studio::ColorScale.blend("#000000", "#ffffff", 0.10)
  end

  # The inks and fills are worthless unless the preset turns them into
  # utilities, and the bare text form must stay uncompilable: that is the
  # structural half of the contract, so it is checked by compiling.
  def test_the_preset_mints_inks_and_fills_but_never_a_bare_text_role
    wanted = ROLES.flat_map { |r| ["text-#{r}-ink", "bg-#{r}/10", "border-#{r}/30"] }
    bare   = ROLES.map { |r| "text-#{r}" }
    compiled = EngineTailwindBuild.classes_in_css(EngineTailwindBuild.compile(wanted + bare, motion: false))

    assert_empty wanted.reject { |t| compiled.include?(t) }, "the preset does not mint these status utilities"
    assert_empty bare.select { |t| compiled.include?(t) },
                 "a bare text-<role> now compiles: role colours fail AA as text, so the preset must not mint it"
  end
end
