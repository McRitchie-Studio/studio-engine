# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# [unit] components/_theme_toggle names itself (/tasks/engine-theme-toggle-labels):
# an icon-only toggle button with type="button", a fixed aria-label, and an
# aria-pressed bound to the theme store. Hosts patched these in at runtime
# (turf-monster app/javascript/nav_labels.js) until the engine rendered them.
# Read through the HTML5 parser: HTML4 drops @click and :aria-pressed.
class ThemeToggleTest < Minitest::Test
  PRESSED = "$store.theme.isDark ? 'true' : 'false'"

  def test_the_toggle_is_a_named_button_that_cannot_submit
    button = toggle(render_partial("components/theme_toggle"))

    assert_equal "button", button["type"], "an untyped button inside a form submits it"
    assert_equal "Dark theme", button["aria-label"]
    assert_equal "Toggle theme", button["title"], "the pointer tooltip stays"
    assert_equal "$store.theme.toggle()", button["@click"]
  end

  def test_aria_pressed_is_bound_to_the_theme_store
    button = toggle(render_partial("components/theme_toggle"))

    assert_equal PRESSED, button[":aria-pressed"]
    refute button.key?("aria-pressed"), "a static value would be wrong for half the readers until Alpine binds"
  end

  def test_the_morph_wrapper_renders_the_same_named_toggle
    doc = Nokogiri::HTML5.fragment(render_partial("components/theme_toggle_morph"))
    button = doc.at_css(".nav-toggle-icon > button")

    refute_nil button, "the morph wraps the toggle where hosts look for it"
    assert_equal "button", button["type"]
    assert_equal "Dark theme", button["aria-label"]
    assert_equal PRESSED, button[":aria-pressed"]
  end

  def test_visuals_unchanged_class_and_icons
    button = toggle(render_partial("components/theme_toggle"))

    assert_equal %w[flex text-secondary hover:text-heading transition], button["class"].split
    assert_equal ["$store.theme.isDark", "!$store.theme.isDark"], button.css("svg").map { |svg| svg["x-show"] }
  end

  private

  def toggle(html)
    buttons = Nokogiri::HTML5.fragment(html).css("button")
    assert_equal 1, buttons.size
    buttons.first
  end

  def render_partial(name)
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"]).render(partial: name)
  end
end
