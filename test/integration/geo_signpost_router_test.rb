# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] The Geo signpost in BOTH engine chromes, against a BOOTED host
# that really drew the geo routes.
#
# WHAT THIS TIER ADDS over the component tests beside it: those define
# `admin_geo_path` on the view itself, so they prove the row's BRANCHING but take
# the route's existence on faith. Here the helper comes from the dummy app's real
# router — the same `Studio.routes(self)` every consumer calls — so a row that
# links a path the router cannot generate fails here instead of in someone's
# admin chrome.
#
# BOTH chromes, because the reach gap this file grew for was a chrome the tests
# never rendered: the row shipped into the dropdown alone, and the app whose
# admin menu is the link sidebar suppresses the dropdown outright. A router
# proof for one chrome says nothing about the other.
#
# The reverse case is the one that would hurt: in an app that did NOT draw the
# routes, `admin_geo_path` is not defined at all, and this partial renders on
# EVERY page for an admin. Reaching for the helper there is a NoMethodError that
# takes the whole chrome down, so the disabled branch must not touch it.
class GeoSignpostRouterTest < ActiveSupport::TestCase
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
    refute_nil doc.at_css("[data-test='geo-signpost-disabled']")
    assert_includes doc.text, "ENABLE_GEO_BLOCKING"
  end

  # THE ONE THAT PROTECTS EVERY PAGE. No route helper in scope at all — the state
  # of every app that has not opted in — and the dropdown still renders.
  test "an app without the geo routes renders the dropdown rather than raising" do
    Studio.geo_blocking_enabled = true

    doc = render_dropdown(with_routes: false)

    refute_nil doc.at_css("[data-test='geo-signpost-disabled']")
    assert_includes doc.text, "Draw the geo routes first"
    # The rest of the chrome is untouched — this row must not cost the others.
    assert_includes doc.to_html, "/admin/theme"
    assert_includes doc.to_html, "/error_logs"
  end

  # THE SIDEBAR CHROME, against the same real router. This is the assertion that
  # makes the fix a REACH fix rather than a refactor: mcritchie-studio renders
  # components/_link_sidebar from its layout and declares admin-flagged sections,
  # which is exactly the shape declared below.
  test "the sidebar chrome links the path this app's router actually generates" do
    Studio.geo_blocking_enabled = true

    row = render_sidebar(with_routes: true).at_css(%(a[href*="/admin/geo"]))

    refute_nil row, "the link sidebar must carry the geo row for an admin"
    assert_equal Rails.application.routes.url_helpers.admin_geo_path, row["href"],
                 "the link must be the router's own path, not a hand-written string"
  end

  # And the same protection: an app on sidebar chrome that never drew the routes
  # renders its whole admin menu, signposted, rather than raising through it.
  test "a sidebar app without the geo routes renders the panel rather than raising" do
    Studio.geo_blocking_enabled = true

    doc = render_sidebar(with_routes: false)

    refute_nil doc.at_css("[data-test='geo-signpost-disabled']")
    assert_includes doc.text, "Draw the geo routes first"
    # The host's own sections are untouched — this row must not cost the others.
    assert_includes doc.to_html, "/error_logs"
  end

  private

  def render_sidebar(with_routes:)
    sections = [{ title: "Ops", admin: true, links: [{ label: "Errors", href: "/error_logs", emoji: "🚨" }] }]
    view = build_view(with_routes: with_routes)
    view.define_singleton_method(:studio_sidebar_sections) { sections }
    view.define_singleton_method(:logged_in?) { true }
    view.define_singleton_method(:logout_path) { "/logout" }

    Nokogiri::HTML5.fragment(view.render(partial: "components/link_sidebar"))
  end

  def geo_row(with_routes:)
    render_dropdown(with_routes: with_routes).at_css("a[href*='/admin/geo']")
  end

  def render_dropdown(with_routes:)
    Nokogiri::HTML5.fragment(build_view(with_routes: with_routes).render(partial: "components/admin_dropdown"))
  end

  def build_view(with_routes:)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.define_singleton_method(:admin?) { true }
    # The host's real helpers, from the dummy's router — or none at all, which is
    # what an app that never drew them looks like.
    view.singleton_class.include(Rails.application.routes.url_helpers) if with_routes
    view
  end
end
