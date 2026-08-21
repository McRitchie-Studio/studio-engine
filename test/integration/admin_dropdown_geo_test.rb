# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] The admin dropdown's Geo row, against a BOOTED host that really
# drew the geo routes.
#
# WHAT THIS TIER ADDS over the component test beside it: that one defines
# `admin_geo_path` on the view itself, so it proves the row's BRANCHING but takes
# the route's existence on faith. Here the helper comes from the dummy app's real
# router — the same `Studio.routes(self)` every consumer calls — so a row that
# links a path the router cannot generate fails here instead of in someone's
# admin chrome.
#
# The reverse case is the one that would hurt: in an app that did NOT draw the
# routes, `admin_geo_path` is not defined at all, and this partial renders on
# EVERY page for an admin. Reaching for the helper there is a NoMethodError that
# takes the whole dropdown down, so the disabled branch must not touch it.
class AdminDropdownGeoTest < ActiveSupport::TestCase
  def setup
    @previous = Studio.geo_blocking_enabled
  end

  def teardown
    Studio.geo_blocking_enabled = @previous
  end

  test "the row links the path this app's router actually generates" do
    Studio.geo_blocking_enabled = true

    row = geo_row(with_routes: true)

    assert_equal Rails.application.routes.url_helpers.admin_geo_path, row["href"],
                 "the link must be the router's own path, not a hand-written string"
  end

  test "with the flag off the row is disabled even though the route exists" do
    Studio.geo_blocking_enabled = false

    doc = render_dropdown(with_routes: true)

    assert_nil doc.at_css("a[href*='/admin/geo']"), "a page you are told is off must not be linked"
    refute_nil doc.at_css("[data-test='admin-dropdown-geo-disabled']")
    assert_includes doc.text, "ENABLE_GEO_BLOCKING"
  end

  # THE ONE THAT PROTECTS EVERY PAGE. No route helper in scope at all — the state
  # of every app that has not opted in — and the dropdown still renders.
  test "an app without the geo routes renders the dropdown rather than raising" do
    Studio.geo_blocking_enabled = true

    doc = render_dropdown(with_routes: false)

    refute_nil doc.at_css("[data-test='admin-dropdown-geo-disabled']")
    assert_includes doc.text, "Draw the geo routes first"
    # The rest of the chrome is untouched — this row must not cost the others.
    assert_includes doc.to_html, "/admin/theme"
    assert_includes doc.to_html, "/error_logs"
  end

  private

  def geo_row(with_routes:)
    render_dropdown(with_routes: with_routes).at_css("a[href*='/admin/geo']")
  end

  def render_dropdown(with_routes:)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.define_singleton_method(:admin?) { true }
    # The host's real helpers, from the dummy's router — or none at all, which is
    # what an app that never drew them looks like.
    view.singleton_class.include(Rails.application.routes.url_helpers) if with_routes

    Nokogiri::HTML5.fragment(view.render(partial: "components/admin_dropdown"))
  end
end
