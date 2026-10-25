# frozen_string_literal: true

require "test_helper"

# [unit] Config rules for Studio.navbar_brand (lib/studio/navbar_brand.rb):
# nil stays the default brand, every key is optional, words normalize to
# { text:, class: }, and a bad shape raises at assignment.
class NavbarBrandTest < Minitest::Test
  B = Studio::NavbarBrand

  def test_nil_is_the_default
    assert_nil B.normalize(nil)
  end

  def test_a_full_brand_normalizes_with_symbol_keys_and_plain_strings
    brand = B.normalize({ "logo" => " /icon-192.png ", "logo_size" => 48, "alt" => "Turf Monster",
                          "words" => ["Turf", { "text" => "Monster", "class" => "tm-wordmark" }] })

    assert_equal({ logo: "/icon-192.png", alt: "Turf Monster", logo_size: 48,
                   words: [{ text: "Turf", class: nil }, { text: "Monster", class: "tm-wordmark" }] }, brand)
  end

  def test_only_the_given_keys_are_kept
    assert_equal({ logo_size: 40 }, B.normalize({ logo_size: 40 }))
    assert_equal({}, B.normalize({}))
  end

  def test_an_html_safe_word_loses_the_flag
    word = B.normalize({ words: ["<b>Turf</b>".html_safe] })[:words].first[:text]

    refute word.html_safe?
  end

  def test_bad_shapes_are_refused_by_name
    assert_raises(B::InvalidConfig) { B.normalize("/icon.png") }
    assert_match(/unknown key :href/, assert_raises(B::InvalidConfig) { B.normalize({ href: "/" }) }.message)
    assert_match(/:logo_size\] must be a positive Integer/, assert_raises(B::InvalidConfig) { B.normalize({ logo_size: "48" }) }.message)
    assert_raises(B::InvalidConfig) { B.normalize({ logo_size: 0 }) }
    assert_raises(B::InvalidConfig) { B.normalize({ logo: " " }) }
    assert_raises(B::InvalidConfig) { B.normalize({ words: [] }) }
    assert_raises(B::InvalidConfig) { B.normalize({ words: "Turf Monster" }) }
    assert_match(/\[:words\]\[1\]\[:text\]/, assert_raises(B::InvalidConfig) { B.normalize({ words: ["a", { class: "x" }] }) }.message)
    assert_match(/\[:words\]\[0\] has unknown key :style/, assert_raises(B::InvalidConfig) { B.normalize({ words: [{ text: "a", style: "x" }] }) }.message)
  end
end
