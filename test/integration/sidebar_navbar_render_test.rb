# frozen_string_literal: true

# Renders the engine navbar through the real dummy Rails app and pins the
# out-of-the-box seam: with Studio.sidebar_sections declared, the navbar
# mounts the trigger and the panels; with the default [], nothing
# sidebar-shaped reaches the page (the upgrade-safety promise: existing
# consumers see no change until they opt in).

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

class SidebarNavbarRenderHostController < ActionController::Base
  # The dummy app draws no root route; the navbar's logo link needs one.
  helper_method :logged_in?, :root_path

  def logged_in? = false

  def root_path = "/"
end

class SidebarNavbarRenderTest < ActiveSupport::TestCase
  SECTIONS = [
    { title: "Site", links: [{ label: "Home", href: "/", emoji: "🏠" }] }
  ].freeze

  teardown do
    Studio.sidebar_sections = []
  end

  test "navbar mounts trigger and panels when sections are declared" do
    Studio.sidebar_sections = SECTIONS

    html = render_navbar

    assert_includes html, "data-link-sidebar-trigger"
    assert_includes html, %(id="studio-link-sidebar")
    assert_includes html, %(id="studio-link-sidebar-mobile")
    assert_includes html, "window.__studioLinkSidebarBridge"
    assert_includes html, "Home"
  end

  test "navbar is untouched with the default empty sections" do
    html = render_navbar

    refute_includes html, "data-link-sidebar-trigger"
    refute_includes html, "studio-link-sidebar"
    refute_includes html, "__studioLinkSidebarBridge"
  end

  test "preview renders skip the sidebar even with sections declared" do
    Studio.sidebar_sections = SECTIONS

    html = SidebarNavbarRenderHostController.render(
      inline: %(<%= render "layouts/navbar", preview: true %>)
    )

    refute_includes html, "data-link-sidebar-trigger"
    refute_includes html, %(id="studio-link-sidebar")
  end

  private

  def render_navbar
    SidebarNavbarRenderHostController.render(inline: %(<%= render "layouts/navbar" %>))
  end
end
