# frozen_string_literal: true

require_relative "../../test_helper"

class StudioUiPrimitivesTest < Minitest::Test
  def test_the_emoji_swap_box_grows_with_its_glyph
    css = Studio::UiPrimitives::EMOJI_SWAP_CSS
    assert_includes css, "height: max(1.25rem, 1.25em)"
    assert_includes css, "width: max(1.5rem, 1.25em)"
  end

  def test_css_includes_emoji_swap_contract
    css = Studio::UiPrimitives.css

    assert_includes css, ".studio-emoji-swap"
    assert_includes css, ".studio-emoji-swap-base"
    assert_includes css, ".studio-emoji-swap-hover"
    assert_includes css, ".group:hover .studio-emoji-swap-base"
    assert_includes css, ".group:focus-visible .studio-emoji-swap-hover"
    assert_includes css, "prefers-reduced-motion: reduce"
  end

  def test_css_keeps_legacy_nav_emoji_class_aliases
    css = Studio::UiPrimitives.css

    assert_includes css, ".nav-emoji-swap"
    assert_includes css, ".nav-emoji-base"
    assert_includes css, ".nav-emoji-hover"
  end
end
