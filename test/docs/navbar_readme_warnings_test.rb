# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] The README's navbar sections carry the three adoption traps the
# ui-consistency-program reviews found, each in the section a host reads when
# it sets that key:
#   - navbar_menu_trigger renders the host partial twice (the icon rail and the
#     phone row), so the partial must carry no ids;
#   - a navbar_header_bars callable that raises drops every bar for that render
#     (reported once), so a bar carrying an OPSEC control must not raise;
#   - navbar_brand's word classes live in the host's initializer, which the
#     host's Tailwind scan must include.
class NavbarReadmeWarningsTest < Minitest::Test
  README = File.read(File.expand_path("../../README.md", __dir__))

  def section(heading)
    body = README[/^### #{Regexp.escape(heading)}.*?(?=^#+ )/m]
    refute_nil body, "README lost its #{heading} section"
    body.gsub(/\s+/, " ")
  end

  def test_the_menu_trigger_partial_carries_no_ids
    body = section("Menu trigger and account sidebar")
    assert_match(/renders the partial twice/, body)
    assert_match(/no `id`/, body)
  end

  def test_a_header_bars_callable_that_raises_drops_the_bars
    body = section("Header bars")
    assert_match(/raises, the navbar renders no header bars/, body)
    assert_match(/OPSEC/, body)
    assert_match(/must not raise/, body)
  end

  def test_brand_word_classes_need_the_host_tailwind_scan
    body = section("Brand, root hook and layer tier")
    assert_match(/initializer/, body)
    assert_match(/Tailwind/, body)
    assert_match(/config\/initializers/, body)
  end
end
