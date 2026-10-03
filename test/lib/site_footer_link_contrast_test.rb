# frozen_string_literal: true

require "test_helper"

# [unit] The site footer's links clear WCAG AA 4.5:1 on the footer band, on the
# engine's default theme tokens, in both themes.
#
# THE DEFECT THIS PINS. `.ftr-link` was `color: inherit; opacity: .78`: the
# band's body ink, faded. Whether that cleared AA depended on how dark the body
# ink happened to be, and for a consumer whose body ink is light (rantly maps it
# to its secondary ink) it failed in light mode. The link now paints
# --ftr-link-ink at full opacity, defaulting to --color-text-secondary, which
# ThemeResolver derives to clear AA on every surface it emits.
#
# READ OFF THE SHIPPED CSS, NOT RESTATED. The ink token, the band's background
# token and any opacity on the link rules are parsed out of
# app/views/studio/site_footer/_assets.html.erb, then resolved through
# Studio::ThemeResolver. So reintroducing the fade, pointing the ink at another
# token or moving the band onto another surface is measured, not assumed.
class SiteFooterLinkContrastTest < ActiveSupport::TestCase
  AA = 4.5
  ASSETS = File.expand_path("../../app/views/studio/site_footer/_assets.html.erb", __dir__)
  # The rules that paint readable link text. .ftr-link-disabled is faded on
  # purpose: WCAG exempts an inactive control from the minimum.
  LINK_RULES = %w[.ftr-link .ftr-link-plain].freeze

  def css = File.read(ASSETS)

  # The declarations of the first rule whose selector is exactly `selector`.
  def declarations(selector)
    body = css[/^\s*#{Regexp.escape(selector)}\s*\{([^}]*)\}/m, 1]
    assert body, "no `#{selector} { ... }` rule in #{File.basename(ASSETS)}"
    body.scan(/([\w-]+)\s*:\s*([^;]+);/).to_h { |name, value| [name.strip, value.strip] }
  end

  # `var(--color-x, fallback)` -> "--color-x"
  def token(value) = value[/\Avar\((--[\w-]+)/, 1]

  def link_ink_token
    ink = declarations(".ftr")["--ftr-link-ink"]
    assert ink, ".ftr must declare --ftr-link-ink"
    token(ink)
  end

  def band_token
    token(declarations(".ftr")["background"].to_s)
  end

  def modes
    resolver = Studio::ThemeResolver.new({})
    { light: resolver.light_mode_vars, dark: resolver.dark_mode_vars }
  end

  # The colour the browser composites for one link rule in one mode.
  def painted(rule, vars, background)
    decls = declarations(rule)
    assert_equal "var(--ftr-link-ink)", decls["color"], "#{rule} must paint the link ink"
    ink = vars.fetch(link_ink_token)
    opacity = decls.fetch("opacity", "1").to_f
    Studio::ColorScale.blend(ink, background, opacity)
  end

  def test_the_footer_links_clear_aa_on_the_band_in_both_themes
    assert_equal "--color-surface-alt", band_token, "the measurement assumes the band's background token"
    assert_equal "--color-text-secondary", link_ink_token, "the documented default link ink"

    modes.each do |mode, vars|
      background = vars.fetch(band_token)
      LINK_RULES.each do |rule|
        colour = painted(rule, vars, background)
        ratio = Studio::ColorScale.contrast_ratio(colour, background)

        assert_operator ratio, :>=, AA, "#{mode}: #{rule} #{colour} on #{background} is #{ratio.round(2)}:1"
      end
    end
  end

  # THE CONTROL: the measurement bites. The default link ink, faded the way the
  # link used to be, falls under AA in light mode, so a fade put back on
  # .ftr-link would turn the test above red rather than pass by construction.
  def test_the_old_fade_on_the_default_ink_fails_aa_in_light_mode
    vars = modes.fetch(:light)
    background = vars.fetch("--color-surface-alt")
    faded = Studio::ColorScale.blend(vars.fetch("--color-text-secondary"), background, 0.78)

    assert_operator Studio::ColorScale.contrast_ratio(faded, background), :<, AA
  end

  # The hover ink is the brand colour and is not held to AA here: it is a state
  # the pointer is already on. The rule must not bring the fade back, though.
  def test_hover_does_not_reintroduce_opacity
    hover = css[/\.ftr-link:hover, \.ftr-link:focus-visible \{([^}]*)\}/, 1]

    assert hover, "no hover rule found"
    refute_match(/opacity/, hover)
  end
end
