# frozen_string_literal: true

require "test_helper"
require "nokogiri"
require "action_view"
require_relative "../../app/helpers/studio_icon_helper"

# The vendored icon set and the helper that renders it. No file may carry anything but
# drawing elements, since the markup reaches every page inline.
class StudioIconsTest < Minitest::Test
  DRAWING = %w[circle ellipse line path polygon polyline rect].freeze

  include StudioIconHelper

  def test_each_vendored_file_is_only_a_drawing
    refute_empty Studio::Icons.names
    Studio::Icons.names.each do |name|
      svg = Nokogiri::XML(Studio::Icons.svg(name)) { |config| config.strict }.root
      assert_equal "svg", svg.name, name
      children = svg.element_children.map(&:name)
      refute_empty children, "#{name} drew nothing: the helper did not find its shapes"
      assert_empty children - DRAWING, "#{name} holds more than drawing elements"
    end
  end

  def test_the_license_ships_beside_the_icons
    license = File.read(File.join(Studio::Icons::DIR, "LICENSE"))
    assert_includes license, "ISC License"
    assert_includes license, "Lucide Icons and Contributors"
    assert_includes license, "Cole Bemis", "log-out comes from Feather, under MIT"
  end

  def test_renders_inline_in_current_color_at_the_asked_size
    svg = Nokogiri::HTML5.fragment(studio_icon("rocket", size: 20)).at_css("svg")

    assert_equal "20", svg["width"]
    assert_equal "20", svg["height"]
    assert_equal "0 0 24 24", svg["viewbox"] || svg["viewBox"]
    assert_equal "currentColor", svg["stroke"]
    assert_equal "none", svg["fill"]
    assert_equal "true", svg["aria-hidden"]
    assert_nil svg["style"], "a strict CSP refuses an inline style"
    assert_operator svg.css("path").size, :>=, 1
  end

  def test_default_size_is_the_sidebars_18
    assert_equal "18", Nokogiri::HTML5.fragment(studio_icon("user")).at_css("svg")["width"]
  end

  def test_output_is_html_safe_and_the_class_is_escaped
    icon = studio_icon("user", class: %(a"><script>))

    assert_predicate icon, :html_safe?
    refute_includes icon, "<script>"
    assert_equal %(a"><script>), Nokogiri::HTML5.fragment(icon).at_css("svg")["class"]
  end

  def test_an_unknown_name_renders_nothing_so_a_caller_can_fall_back
    assert_nil studio_icon("no-such-icon")
    assert_nil studio_icon(nil)
  end

  def test_a_name_never_reaches_the_file_system_as_a_path
    assert_nil studio_icon("../icons/lucide/user")
    assert_nil studio_icon("../../version")
    assert_nil studio_icon("LICENSE")
  end

  def test_a_size_that_is_not_a_number_raises_instead_of_reaching_the_markup
    assert_raises(ArgumentError) { studio_icon("user", size: %(1" onload="x)) }
  end
end
