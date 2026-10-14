# frozen_string_literal: true

require "test_helper"

# [unit] Config rules for Studio.navbar_wordmark (lib/studio/navbar_wordmark.rb):
# nil stays nil, a Hash of the two theme paths normalizes to symbol keys, and
# anything else raises at boot rather than rendering a broken navbar.
class NavbarWordmarkTest < Minitest::Test
  W = Studio::NavbarWordmark

  def test_default_is_unset
    assert_nil Studio.navbar_wordmark
    assert_nil W.normalize(nil)
  end

  def test_symbol_keys_normalize_to_the_two_theme_paths
    config = { light: "/brand/navbar-light.svg", dark: "/brand/navbar-dark.svg" }

    assert_equal config, W.normalize(config)
  end

  def test_string_keys_and_padding_normalize_the_same
    normalized = W.normalize({ "light" => " /brand/l.svg ", "dark" => "/brand/d.svg" })

    assert_equal({ light: "/brand/l.svg", dark: "/brand/d.svg" }, normalized)
  end

  def test_a_bare_path_is_refused_because_a_lockup_needs_both_themes
    error = assert_raises(W::InvalidConfig) { W.normalize("/brand/navbar.svg") }
    assert_match(/light: path, dark: path/, error.message)
  end

  def test_a_missing_theme_is_refused_and_named
    error = assert_raises(W::InvalidConfig) { W.normalize({ light: "/brand/l.svg" }) }
    assert_match(/\[:dark\]/, error.message)
  end

  def test_a_blank_path_is_refused
    assert_raises(W::InvalidConfig) { W.normalize({ light: "/brand/l.svg", dark: "  " }) }
    assert_raises(W::InvalidConfig) { W.normalize({ light: :logo, dark: "/brand/d.svg" }) }
  end

  def test_an_unknown_key_is_refused_rather_than_ignored
    error = assert_raises(W::InvalidConfig) do
      W.normalize({ light: "/brand/l.svg", dark: "/brand/d.svg", mobile: "/brand/m.svg" })
    end
    assert_match(/:mobile/, error.message)
  end
end
