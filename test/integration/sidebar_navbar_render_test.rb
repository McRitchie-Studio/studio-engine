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

# Logged-in admin variant for the double-gear rule: the user-nav icon rail
# renders both the sidebar trigger and the admin dropdown, which share the
# cog glyph.
class SidebarAdminHostController < SidebarNavbarRenderHostController
  helper_method :current_user, :admin?

  class StubUser
    def display_name = "Admin User"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#0ea5e9"
    def avatar_initials = "AU"
  end

  def logged_in? = true

  def admin? = true

  def current_user = @current_user ||= StubUser.new
end

# A host that draws /profile and has someone signed in — the shape every consumer
# is in once the engine's standard link ships.
class SidebarProfileLinkHostController < SidebarNavbarRenderHostController
  class StubUser
    def display_name = "Pat Studio"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#6366f1"
    def avatar_initials = "PS"
  end

  def logged_in? = true
  def admin? = false
  def current_user = @current_user ||= StubUser.new
  def profile_path = "/profile"
  helper_method :logged_in?, :admin?, :current_user, :profile_path
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

  # The panel's geometry, asserted where it actually reaches a page: mounted BY the
  # navbar, through the real dummy app, rather than rendered as a partial in isolation.
  # A `fixed` overlay's `top` is a viewport coordinate, so it must be the header's bottom
  # edge (--nav-bottom) and never its height (--nav-h) — the two differ by exactly the
  # height of any chrome an app stacks above the navbar, and mcritchie-industries' 47px
  # environment banner put this panel on top of the header, over the Log in button.
  # Unit-level coverage of the same contract, including the publisher half, lives in
  # test/views/nav_offset_contract_test.rb.
  test "the mounted sidebar panel offsets from the header's bottom edge" do
    Studio.sidebar_sections = SECTIONS

    html = render_navbar

    assert_includes html, "top:var(--nav-bottom, var(--nav-h, 6rem))",
                    "the mounted panel must start at the header's bottom edge, not its height"
    refute_includes html, "top:var(--nav-h,",
                    "offsetting a fixed panel by the header HEIGHT is the banner-overlap bug"
  end

  # THE STANDARD LINK, asserted where it actually reaches a page: mounted BY the
  # navbar through the real dummy app, not resolved as a Hash in isolation. The
  # unit suite proves the resolution rules; this proves a consumer that declares
  # NOTHING still gets a working sidebar with the viewer's own profile in it.
  test "a signed-in host with no declared sections still gets the Profile link" do
    html = render_navbar(controller: SidebarProfileLinkHostController)

    assert_includes html, "data-link-sidebar-trigger",
      "the sidebar now has content in every signed-in app, so the trigger mounts"
    assert_includes html, "Profile"
    assert_includes html, "/profile"
  end

  test "navbar is untouched with the default empty sections" do
    html = render_navbar

    refute_includes html, "data-link-sidebar-trigger"
    refute_includes html, "studio-link-sidebar"
    refute_includes html, "__studioLinkSidebarBridge"
  end

  test "sidebar with an admin section replaces the admin dropdown" do
    Studio.sidebar_sections = SECTIONS + [
      { title: "Ops", admin: true, links: [{ label: "Errors", href: "/error_logs", emoji: "🚨" }] }
    ]

    html = SidebarAdminHostController.render(inline: %(<%= render "layouts/navbar" %>))

    assert_includes html, "data-link-sidebar-trigger"
    refute_includes html, %(title="Admin"),
                    "the admin dropdown must yield to the sidebar's admin menu (double gear)"
  end

  test "sidebar with only public sections keeps the admin dropdown" do
    Studio.sidebar_sections = SECTIONS

    html = SidebarAdminHostController.render(inline: %(<%= render "layouts/navbar" %>))

    assert_includes html, "data-link-sidebar-trigger"
    assert_includes html, %(title="Admin"),
                    "admins keep the dropdown when the sidebar carries no admin section"
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

  def render_navbar(controller: SidebarNavbarRenderHostController)
    controller.render(inline: %(<%= render "layouts/navbar" %>))
  end
end
