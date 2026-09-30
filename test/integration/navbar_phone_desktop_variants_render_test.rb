# frozen_string_literal: true

# [integration] Renders the engine navbar through the real dummy Rails app,
# signed in, and reads it at both widths the way Tailwind's classes decide
# them: `hidden` hides below md unless the same element also carries an
# `md:` display class, and `md:hidden` hides from md up.
#
# THE DEFECTS THIS PINS (engine-navbar-phone-polish). A phone showed TWO theme
# toggles — the navbar's phone row and the user nav each drew one — and the
# name and avatar were two links to the same page, the name truncating to
# "Guest 55…" on a phone. What must survive the fix: the desktop sidebar
# button the navbar passes into the user nav as extra_icons_html (a fork of
# this partial once dropped it), the admin menu, and the account destination.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarVariantsHostController < ActionController::Base
  helper_method :logged_in?, :admin?, :current_user, :profile_path, :root_path

  class StubUser
    def display_name = "Guest 55 Long Name"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#6366f1"
    def avatar_initials = "GL"
  end

  def logged_in? = true
  def admin? = false
  def current_user = @current_user ||= StubUser.new
  def profile_path = "/profile"
  def root_path = "/"
end

class NavbarVariantsAdminHostController < NavbarVariantsHostController
  def admin? = true
end

class NavbarPhoneDesktopVariantsRenderTest < ActiveSupport::TestCase
  MD_DISPLAY = %w[md:flex md:block md:inline-flex md:inline md:grid md:inline-block].freeze

  setup { @prior_sidebar_sections = Studio.sidebar_sections }
  teardown { Studio.sidebar_sections = @prior_sidebar_sections }

  test "a phone shows one theme toggle, in the phone row" do
    header = render_header

    toggles = header.css(".nav-toggle-icon").select { |t| visible?(t, :phone) }

    assert_equal 1, toggles.size, "two toggles on a phone is the bug"
    assert toggles.first.ancestors.any? { |el| classes(el).include?("md:hidden") },
      "the phone's toggle is the phone row's"
  end

  test "a desktop shows one theme toggle, in the user nav" do
    header = render_header

    toggles = header.css(".nav-toggle-icon").select { |t| visible?(t, :desktop) }

    assert_equal 1, toggles.size
    refute_nil toggles.first.ancestors("[data-nav-theme-toggle]").first
  end

  test "the name and avatar are one account link at both widths" do
    header = render_header
    links = header.css("a[href='/profile']").reject { |a| a.ancestors("#studio-link-sidebar, #studio-link-sidebar-mobile").any? }

    assert_equal 1, links.size, "one account link, one tab stop"
    account = links.first
    assert account.key?("data-nav-account")
    assert_includes account.text, "Guest 55 Long Name", "the name stays the link's accessible text"
    assert_includes account.to_html, "GL", "the avatar is in the same link"
  end

  test "a phone shows the avatar alone; a desktop shows the name beside it" do
    account = render_header.at_css("[data-nav-account]")
    name_box = account.at_css("[data-nav-name]").parent

    assert_includes classes(name_box), "sr-only", "below md the name is screen-reader text"
    assert_includes classes(name_box), "md:not-sr-only", "from md up the name shows"
    avatar = account.css("[aria-hidden='true']").find { |el| el.to_html.include?("GL") }
    assert visible?(avatar, :phone) && visible?(avatar, :desktop), "the avatar shows at both widths"
  end

  test "the desktop sidebar button still reaches the user nav" do
    Studio.sidebar_sections = [{ title: "Site", links: [{ label: "Home", href: "/", emoji: "🏠" }] }]

    header = render_header
    user_nav_triggers = header.css("[data-link-sidebar-trigger]").select { |t| visible?(t, :desktop) }

    assert_equal 1, user_nav_triggers.size, "desktops need their way into the sidebar"
    assert_nil user_nav_triggers.first.ancestors("[data-nav-account]").first
    assert_equal 1, header.css("[data-link-sidebar-trigger]").count { |t| visible?(t, :phone) },
      "the phone row keeps its own trigger"
  end

  test "an admin keeps the admin menu" do
    header = render_header(NavbarVariantsAdminHostController)

    refute_empty header.css("button[title='Admin']")
  end

  # engine-button-contrast-admin-cog: the user nav drew the admin cog at every
  # width and the phone row drew another, so an admin's phone showed two.
  test "an admin sees exactly one admin cog on a phone, in the phone row" do
    header = render_header(NavbarVariantsAdminHostController)

    cogs = visible_cogs(header, :phone)

    assert_equal 1, cogs.size, "two cogs on a phone is the bug"
    assert cogs.first.ancestors.any? { |el| classes(el).include?("md:hidden") },
      "the phone's cog is the phone row's"
  end

  test "an admin sees exactly one admin cog on a desktop, in the user nav" do
    header = render_header(NavbarVariantsAdminHostController)

    cogs = visible_cogs(header, :desktop)

    assert_equal 1, cogs.size
    assert cogs.first.ancestors.none? { |el| classes(el).include?("md:hidden") },
      "the desktop's cog is the user nav's"
  end

  test "with a sidebar that does not carry the admin menu, still one cog at each width" do
    Studio.sidebar_sections = [{ title: "Site", links: [{ label: "Home", href: "/", emoji: "🏠" }] }]
    header = render_header(NavbarVariantsAdminHostController)

    assert_equal 1, visible_cogs(header, :phone).size
    assert_equal 1, visible_cogs(header, :desktop).size
  end

  test "a non-admin sees no admin cog at either width" do
    header = render_header

    assert_empty header.css("button[title='Admin']")
  end

  private

  def render_header(controller = NavbarVariantsHostController)
    html = controller.render(inline: %(<%= render "layouts/navbar" %>))
    header = Nokogiri::HTML5(html).at_css("header")
    refute_nil header, "expected the navbar header"
    header
  end

  def classes(el) = el["class"].to_s.split

  def visible_cogs(header, width)
    header.css("button[title='Admin']").select { |cog| visible?(cog, width) }
  end

  def visible?(node, width)
    [node, *node.ancestors].none? do |el|
      next false unless el.respond_to?(:[]) && el.element?

      c = classes(el)
      case width
      when :phone then c.include?("hidden") || c.include?("sr-only")
      when :desktop then c.include?("md:hidden") || (c.include?("hidden") && (c & MD_DISPLAY).empty?)
      end
    end
  end
end
