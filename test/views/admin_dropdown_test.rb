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

  # --- the geo signpost, THROUGH this chrome ---------------------------------
  #
  # A DISABLED row rather than a hidden one, because the point is signage: an app
  # that has not turned geo on should still learn the feature exists and what to
  # set. Hiding it teaches nobody anything.
  #
  # The row itself now lives in components/_geo_signpost and is covered
  # variant-by-variant in test/views/geo_signpost_test.rb. What these keep is the
  # CALL SITE: that this dropdown still composes the row, in every state, beside
  # the chrome it must not cost. The test hook lost its `admin-dropdown-` prefix
  # in the same change — the row renders in two chromes now, so a name claiming
  # one of them was a lie. Grepped ecosystem-wide first: it appeared only here
  # and in the engine's own partial, in no consumer.

  def test_geo_links_the_manager_when_the_flag_and_the_routes_are_both_there
    html = render_dropdown(admin: true, geo_flag: true, geo_routes: true)

    assert_includes html, "/admin/geo", "an app with geo on gets a live link"
    refute_includes html, "geo-signpost-disabled"
  end

  # THE VARIABLE IS THE SWITCH the operator asked for. Off, the row is still
  # there, still says Geo, and names what to set.
  def test_geo_is_disabled_and_names_the_variable_when_the_flag_is_off
    html = render_dropdown(admin: true, geo_flag: false, geo_routes: true)

    assert_includes html, "geo-signpost-disabled"
    assert_includes html, "ENABLE_GEO_BLOCKING", "the disabled row must say what to set"
    refute_includes html, "/admin/geo", "and must not link a page it is telling you is off"
  end

  # THE RAISE THIS AVOIDS: where the host never drew the geo routes,
  # `admin_geo_path` is not defined at all, so a disabled branch that reached for
  # it would take the whole dropdown — admin chrome on every page — down with a
  # NoMethodError. The row renders, and points at the other prerequisite.
  def test_geo_is_disabled_without_reaching_for_a_route_that_does_not_exist
    html = render_dropdown(admin: true, geo_flag: true, geo_routes: false)

    assert_includes html, "geo-signpost-disabled"
    assert_includes html, "Draw the geo routes first"
    refute_includes html, "/admin/geo"
  end

  # Geo is admin chrome like the rest of it: the leak this file exists for must
  # not reappear through the new row.
  def test_the_geo_row_is_admin_only_like_everything_else_here
    assert_empty render_dropdown(admin: false, geo_flag: true, geo_routes: true).strip
  end

  private

  def render_dropdown(admin:, geo_flag: nil, geo_routes: false)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.define_singleton_method(:admin?) { admin } unless admin.nil?
    # The host's route helper, present only where the app drew the geo routes.
    view.define_singleton_method(:admin_geo_path) { "/admin/geo" } if geo_routes

    previous = Studio.geo_blocking_enabled
    Studio.geo_blocking_enabled = geo_flag
    view.render(partial: "components/admin_dropdown")
  ensure
    Studio.geo_blocking_enabled = previous
  end
end
