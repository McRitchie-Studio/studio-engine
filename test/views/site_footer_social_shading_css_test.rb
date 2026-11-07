# frozen_string_literal: true

require "test_helper"

# [unit] The footer's social discs wear the lit button's shading
# (studio/site_footer/_assets). Each assertion reads a selector AND its
# declarations, so a light moved onto the wrong selector fails here. The browser
# half (a computed box-shadow in a live page) is e2e/site_footer.spec.js.
class SiteFooterSocialShadingCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/views/studio/site_footer/_assets.html.erb", __dir__)).freeze

  def rule(selector)
    CSS[/^\s*#{Regexp.escape(selector)} \{[^}]*\}/]
  end

  # Every app, not only a glass page: each light reads the button's --lit-* token
  # with the button's own light value as the fallback.
  def test_the_lights_fall_back_to_the_buttons_values_on_any_surface
    lights = CSS[/^\s*\.ftr \{ --ftr-lit-top:[^}]*\}/]

    refute_nil lights, "no .ftr rule declaring the footer's lit tokens"
    assert_includes lights, "var(--lit-top, inset 0 1px 0 rgb(255 255 255 / .35))"
    assert_includes lights, "var(--lit-bottom, inset 0 -2px 0 rgb(0 0 0 / .2))"
    assert_includes lights, "var(--lit-contact, 0 1px 2px rgb(0 0 0 / .4))"
    assert_includes lights, "var(--lit-glow-alpha, .6)"
    rules = CSS.gsub(%r{/\*.*?\*/}m, "")
    refute_includes rules, "data-surface-style", "the shading must not be gated on the glass surface"
  end

  def test_dark_mode_takes_the_buttons_dark_values
    dark = CSS[/^\s*\.dark \.ftr \{[^}]*\}/]

    refute_nil dark, "no .dark .ftr rule"
    assert_includes dark, "var(--lit-bottom, inset 0 -2px 0 rgb(0 0 0 / .3))"
    assert_includes dark, "var(--lit-contact, 0 1px 2px rgb(0 0 0 / .65))"
    assert_includes dark, "var(--lit-glow-alpha, .8)"
  end

  def test_a_linked_disc_carries_the_highlight_edge_and_shadow
    lit = rule("a.ftr-social")

    refute_nil lit, "no a.ftr-social rule"
    assert_match(/box-shadow: var\(--ftr-lit-top\), var\(--ftr-lit-bottom\), var\(--ftr-lit-contact\),\s+0 4px 12px -4px rgb\(var\(--ftr-primary-rgb\)/, lit)
    # Down from the fill only: never lighter than --ftr-primary under the white glyph.
    assert_includes lit, "linear-gradient(var(--ftr-primary), oklch(from var(--ftr-primary) calc(l - .08) c h))"
  end

  def test_hover_lifts_and_deepens_never_brightens
    hover = rule("a.ftr-social:hover")

    refute_nil hover
    assert_includes hover, "transform: translateY(-2px)"
    assert_includes hover, "filter: brightness(.94)"
    assert_includes hover, "0 8px 16px -6px"
    refute_match(/brightness\(1\./, CSS)
  end

  def test_a_pending_disc_stays_flat
    pending = rule(".ftr-social[data-pending]")

    refute_nil pending
    assert_includes pending, "background: transparent"
    assert_includes pending, "box-shadow: none"
    assert_includes pending, "border: 1px dashed currentColor"
  end

  def test_reduced_motion_drops_the_transition
    assert_match(/@media \(prefers-reduced-motion: reduce\) \{ \.ftr a, \.ftr-social \{ transition: none; \} \}/, CSS)
  end
end
