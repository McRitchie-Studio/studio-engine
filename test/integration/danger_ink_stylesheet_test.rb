# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [integration] The danger ink must reach the STYLESHEET, in both theme blocks.
#
# Its sibling, test/lib/danger_ink_contrast_test.rb, inspects the resolver's var
# HASHES and proves the derived colour clears AA. That says nothing about whether
# the value survives into the CSS document the browser actually receives — a var
# emitted into only one of the two blocks would pass every contrast assertion and
# still leave one theme with no ink at all, falling back to inherited colour.
#
# ThemeResolver#to_css is what ThemeSettingsController serves as @preview_css, so
# this is the same text a consumer's <style> block gets.
class DangerInkStylesheetTest < ActiveSupport::TestCase
  def css(colors = {})
    Studio::ThemeResolver.new(colors).to_css
  end

  # The document has exactly two blocks: `:root, .dark { … }` for dark and
  # `html:not(.dark) { … }` for light. The var must be declared in BOTH.
  def blocks(document)
    dark = document[/:root, \.dark \{(.*?)\n\}/m, 1].to_s
    light = document[/html:not\(\.dark\) \{(.*?)\n\}/m, 1].to_s
    [dark, light]
  end

  def test_both_theme_blocks_declare_a_danger_ink
    dark, light = blocks(css)

    refute_empty dark, "the dark block was not found — this test must be re-pointed, not deleted"
    refute_empty light, "the light block was not found — this test must be re-pointed, not deleted"
    assert_match(/--color-danger-ink:\s*#[0-9A-Fa-f]{6};/, dark,
                 "the dark theme ships no danger ink, so error text falls back to inherited colour")
    assert_match(/--color-danger-ink:\s*#[0-9A-Fa-f]{6};/, light,
                 "the light theme ships no danger ink — the surface the defect was MEASURED on")
  end

  # The two themes must not ship the SAME ink. If they did, the derivation had no
  # effect and one surface is failing AA — which is the whole defect.
  def test_the_two_themes_ship_different_inks
    dark, light = blocks(css)
    dark_ink = dark[/--color-danger-ink:\s*(#[0-9A-Fa-f]{6});/, 1]
    light_ink = light[/--color-danger-ink:\s*(#[0-9A-Fa-f]{6});/, 1]

    refute_equal dark_ink, light_ink,
                 "both themes ship #{dark_ink} — a single static red cannot clear AA on both " \
                 "surfaces, which is why this token is derived per theme"
  end

  # An operator's own palette must reach the stylesheet too, not just the default.
  def test_an_operator_palette_reaches_the_stylesheet
    dark, light = blocks(css(danger: "#B91C1C", dark: "#0B1020", light: "#ffffff"))

    assert_match(/--color-danger-ink:\s*#[0-9A-Fa-f]{6};/, dark)
    assert_match(/--color-danger-ink:\s*#[0-9A-Fa-f]{6};/, light)
  end
end
