# frozen_string_literal: true

require "test_helper"

# [unit] The stylesheet half of the footer's `lockup:` fact
# (studio/site_footer/_lockup_assets). The footer renders BOTH theme files;
# these rules are the only thing that shows one and hides the other, and the
# only thing that sizes the lockup. Each assertion spans a selector AND its
# declaration, so a rule moved onto the wrong selector fails here.
class SiteFooterLockupCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/views/studio/site_footer/_lockup_assets.html.erb", __dir__)).freeze
  FOOTER_CSS = File.read(File.expand_path("../../app/views/studio/site_footer/_assets.html.erb", __dir__)).freeze

  def test_the_lockup_is_height_led_and_never_wider_than_its_column
    rule = CSS[/\.ftr-lockup \{[^}]*\}/]

    refute_nil rule, "no .ftr-lockup rule"
    assert_includes rule, "height: var(--ftr-lockup-height, 7rem)"
    assert_includes rule, "width: auto"
    assert_includes rule, "max-width: 100%"
    assert_includes rule, "object-fit: contain"
    assert_includes rule, "object-position: center"
  end

  def test_a_lockup_centres_the_brand_block_and_its_social_row
    assert_match(/^\s*\.ftr-brand-lockup \{ text-align: center; \}/, CSS)
    assert_match(/^\s*\.ftr-brand-lockup \.ftr-home \{ display: inline-flex; justify-content: center; vertical-align: top; \}/, CSS)
    assert_match(/^\s*\.ftr-brand-lockup \.ftr-socials \{ justify-content: center; \}/, CSS)
  end

  # The home link hugs the lockup (inline-flex, never a column-wide flex box), so
  # its keyboard focus ring sits around the artwork, offset clear of it, instead
  # of crossing the name (Shannon, review of PR 468).
  def test_the_focus_ring_rings_the_lockup_not_the_column
    refute_match(/\.ftr-brand-lockup \.ftr-home \{[^}]*display: flex/, CSS)
    assert_match(/^\s*\.ftr-brand-lockup \.ftr-home:focus-visible \{ outline-offset: 4px; \}/, CSS)
  end

  def test_light_page_shows_the_light_file_and_dark_page_the_dark_file
    assert_match(/^\s*\.ftr-lockup-dark \{ display: none; \}/, CSS)
    assert_match(/^\s*\.dark \.ftr-lockup-light \{ display: none; \}/, CSS)
    assert_match(/^\s*\.dark \.ftr-lockup-dark \{ display: block; \}/, CSS)
  end

  def test_the_bare_dark_hide_comes_after_the_base_display_so_it_wins_on_order
    assert_operator CSS.index(".ftr-lockup { display: block"), :<, CSS.index(".ftr-lockup-dark { display: none")
  end

  def test_the_footer_stylesheet_every_footer_renders_carries_no_lockup_rule
    refute_includes FOOTER_CSS, "ftr-lockup", "a footer without a lockup must stay byte-identical"
  end
end
