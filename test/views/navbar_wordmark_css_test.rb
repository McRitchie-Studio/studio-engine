# frozen_string_literal: true

require "test_helper"

# [unit] The stylesheet half of Studio.navbar_wordmark, in engine.css's nav band
# table. The partial renders BOTH theme files; these rules are the only thing
# that shows one and hides the other, and the only thing that sizes the lockup.
# Each assertion spans a selector AND its declaration, so a rule moved onto the
# wrong selector fails here.
class NavbarWordmarkCssTest < Minitest::Test
  CSS = File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)).freeze

  def test_the_lockup_height_rides_the_logo_collapse_size
    assert_match(/\.nav-shell \.nav-wordmark \{ height: var\(--nav-logo-size\); \}/, CSS)
  end

  def test_the_lockup_is_height_led_and_shrinks_inside_its_column
    rule = CSS[/\.nav-wordmark \{[^}]*\}/]

    refute_nil rule, "no .nav-wordmark rule in engine.css"
    assert_includes rule, "width: auto"
    assert_includes rule, "max-width: 100%"
    assert_includes rule, "min-width: 0"
    assert_includes rule, "object-fit: contain"
    assert_match(/\.nav-wordmark-brand \{[^}]*min-width: 0/, CSS)
  end

  def test_light_page_shows_the_light_file_and_dark_page_the_dark_file
    assert_match(/^\s*\.nav-wordmark-dark \{ display: none; \}/, CSS)
    assert_match(/^\s*\.dark \.nav-wordmark-light \{ display: none; \}/, CSS)
    assert_match(/^\s*\.dark \.nav-wordmark-dark \{ display: block; \}/, CSS)
  end

  def test_the_bare_dark_hide_comes_after_the_base_display_so_it_wins_on_order
    assert_operator CSS.index(".nav-wordmark { display: block"), :<, CSS.index(".nav-wordmark-dark { display: none")
  end

  def test_the_rules_sit_in_the_layered_band_table_so_an_app_can_override_them
    layer = CSS[/@layer utilities \{\n\s*\.nav-title \{.*?\n\}\n/m]

    refute_nil layer
    assert_includes layer, ".nav-shell .nav-wordmark"
  end
end
