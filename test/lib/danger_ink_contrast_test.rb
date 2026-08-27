# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] The danger INK must clear WCAG AA on every surface, in both themes.
#
# THE DEFECT THIS PINS. Modal error text used text-red-300, measured at 1.92:1 on
# the light card where AA wants 4.5:1. The obvious fixes were measured and all
# fail, because no STATIC red clears AA on BOTH themes:
#
#   text-red-300 (the old value)   1.92 light / 5.81 dark
#   text-red-400 (7 other modals)  2.77 / 4.03
#   --color-danger #EF4444         3.76 / 2.96
#   text-red-600                   4.77 / 2.34
#
# A `dark:` variant is not available either: no @custom-variant dark is
# registered, so `dark:` keys off prefers-color-scheme and would DESYNC from the
# app's own .dark toggle.
#
# So the ink is DERIVED per theme, by the same bounded search that already
# produces --color-text-secondary and --color-text-muted. This test asserts the
# property that matters — the emitted token clears 4.5:1 on every surface the
# resolver itself says that theme can paint — rather than pinning a hex, which
# would freeze one operator's palette into the suite.
class DangerInkContrastTest < ActiveSupport::TestCase
  AA = 4.5

  def resolver(colors = {})
    Studio::ThemeResolver.new(colors)
  end

  def ratios(ink, surfaces)
    surfaces.map { |bg| Studio::ColorScale.contrast_ratio(ink, bg) }
  end

  def dark_check(res, base)
    ratios(res.send(:dark_mode_vars)["--color-danger-ink"], res.send(:dark_surfaces, base))
  end

  def light_check(res, base)
    ratios(res.send(:light_mode_vars)["--color-danger-ink"], res.send(:light_surfaces, base))
  end

  def test_the_default_theme_emits_a_danger_ink_that_clears_aa_in_both_modes
    res = resolver

    dark_check(res, "#1A1535").each { |r| assert_operator r, :>=, AA, "dark danger ink fails AA at #{r.round(2)}:1" }
    light_check(res, "#f8fafc").each { |r| assert_operator r, :>=, AA, "light danger ink fails AA at #{r.round(2)}:1" }
  end

  # THE CONTROL. If the brand red already passed, the derivation would be doing
  # nothing and the test above would prove nothing. #EF4444 as TEXT fails on every
  # light surface — that is the gap the ink exists to close.
  def test_the_raw_brand_danger_colour_does_not_clear_aa_as_text
    surfaces = resolver.send(:light_surfaces, "#f8fafc")

    assert ratios("#EF4444", surfaces).all? { |r| r < AA },
           "the brand danger colour now passes AA as light-surface text — if that is a real " \
           "palette change, this control needs rewriting, not deleting"
  end

  # DERIVED, NOT TUNED. The operator picks these colours in the theme editor, so
  # the search has to hold for reds it has never seen — including a very dark one
  # and a very light one, where a fixed blend amount would fail on one end.
  def test_the_search_holds_for_operator_chosen_danger_colours
    [
      { danger: "#7F1D1D" }, { danger: "#FCA5A5" }, { danger: "#FF0000" },
      { danger: "#B91C1C", dark: "#0B1020", light: "#ffffff" }
    ].each do |palette|
      res = resolver(palette)
      base_dark = palette[:dark] || "#1A1535"
      base_light = palette[:light] || "#f8fafc"

      dark_check(res, base_dark).each do |r|
        assert_operator r, :>=, AA, "#{palette.inspect}: dark ink fails AA at #{r.round(2)}:1"
      end
      light_check(res, base_light).each do |r|
        assert_operator r, :>=, AA, "#{palette.inspect}: light ink fails AA at #{r.round(2)}:1"
      end
    end
  end

  # A theme whose red ALREADY passes must keep its exact brand hex — the search
  # starts at 0.0 blend precisely so it does not repaint a palette that was fine.
  def test_a_passing_colour_is_left_untouched
    res = resolver(danger: "#7F1D1D")
    ink = res.send(:light_mode_vars)["--color-danger-ink"]

    assert_equal "#7F1D1D", ink.upcase,
                 "a danger colour that already clears AA on light surfaces was needlessly darkened"
  end

  # The token is worthless if no utility renders it.
  def test_the_tailwind_config_exposes_a_text_danger_ink_utility
    config = File.read(File.expand_path("../../tailwind/studio.tailwind.config.js", __dir__))

    assert_match(/'danger-ink':\s*'var\(--color-danger-ink\)'/, config,
                 "--color-danger-ink is emitted but no text-danger-ink utility maps to it, so " \
                 "nothing can use it")
  end
end
