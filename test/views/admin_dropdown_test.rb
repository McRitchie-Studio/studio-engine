# frozen_string_literal: true

require "test_helper"
require "action_view"
require "nokogiri"

# The admin dropdown is ADMIN chrome: it renders only for admin? viewers.
# Regression pin for the public-page leak (industries-declares-sidebar-sections
# wave-1 review): the un-gated partial offered /admin/theme and /error_logs to
# signed-out strangers on a public landing page.
class AdminDropdownTest < Minitest::Test
  def test_renders_nothing_for_a_viewer_without_the_admin_predicate
    html = render_dropdown(admin: nil)

    assert_empty html.strip, "bare viewers (no admin?) must see no dropdown"
  end

  def test_renders_nothing_for_a_non_admin
    html = render_dropdown(admin: false)

    assert_empty html.strip, "non-admins must see no dropdown"
  end

  def test_renders_the_menu_for_an_admin
    html = render_dropdown(admin: true)
    doc = Nokogiri::HTML5.fragment(html)

    refute_nil doc.at_css(%(button[title="Admin"]))
    assert_includes html, "/admin/theme"
    assert_includes html, "/error_logs"
  end

  private

  def render_dropdown(admin:)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.define_singleton_method(:admin?) { admin } unless admin.nil?
    view.render(partial: "components/admin_dropdown")
  end
end
