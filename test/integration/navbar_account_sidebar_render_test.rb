# frozen_string_literal: true

# [integration] Studio.navbar_account_sidebar and Studio.navbar_menu_trigger
# through the dummy app: the account control (name and avatar, one control)
# becomes a button that opens the host's sidebar, and the host's trigger
# partial takes the admin dropdown's seat in the icon rail and the phone row.
# Unset, both render the 0.113.0 bytes. Read through the HTML5 parser: HTML4
# drops @click and :aria-expanded.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_render_host"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarAccountSidebarRenderTest < ActiveSupport::TestCase
  GEAR = { flag: "gearOpen", controls: %w[gear-sidebar gear-sidebar-mobile] }.freeze
  SECTIONS = [{ title: "Site", links: [{ label: "Home", href: "/", emoji: "*" }] }].freeze

  setup do
    @prior = [Studio.navbar_account_sidebar, Studio.navbar_menu_trigger, Studio.sidebar_sections]
  end

  teardown do
    Studio.navbar_account_sidebar, Studio.navbar_menu_trigger, Studio.sidebar_sections = @prior
  end

  test "unset, nil-answering and raising callables render the same bytes, signed in and out" do
    Studio.navbar_account_sidebar = nil
    Studio.navbar_menu_trigger = nil
    signed_in = render(signed_in: true)
    signed_out = render(signed_in: false)

    Studio.navbar_account_sidebar = ->(_view) {}
    Studio.navbar_menu_trigger = ->(_view) { raise KeyError, "x" }
    assert_equal signed_in, render(signed_in: true)
    assert_equal signed_out, render(signed_in: false)
    refute_includes signed_in, "data-nav-menu-trigger"
  end

  test "the account control becomes one button that toggles the host's flag" do
    Studio.navbar_account_sidebar = GEAR
    account = doc(signed_in: true).at_css("[data-nav-account]")

    assert_equal "button", account.name
    assert_equal "button", account["type"]
    assert_equal "gear-sidebar gear-sidebar-mobile", account["aria-controls"]
    assert_equal "dialog", account["aria-haspopup"]
    assert_equal "$store.sidebars && ($store.sidebars.gearOpen = !$store.sidebars.gearOpen)", account["@click.stop"]
    assert_equal "$store.sidebars && $store.sidebars.gearOpen ? 'true' : 'false'", account[":aria-expanded"]
    assert account.key?("data-profile-image-toggle"), "a host's capture-phase handler can claim it"
    assert_empty account.css("a, button"), "still one tab stop"
    assert_equal "Plain User", account.at_css("[data-nav-name]").text
  end

  test "it wins over the link sidebar and the account link" do
    Studio.sidebar_sections = SECTIONS
    Studio.navbar_account_sidebar = GEAR.merge(store: "menus", flag: "open")
    account = doc(signed_in: true).at_css("[data-nav-account]")

    assert_equal "gear-sidebar gear-sidebar-mobile", account["aria-controls"], "not the link sidebar's panels"
    assert_includes account["@click.stop"], "$store.menus.open"
    assert_nil account["href"]
  end

  test "the menu trigger takes the admin dropdown's seat in the rail and the phone row" do
    Studio.navbar_menu_trigger = "navbar_slot_fixtures/trigger"
    page = doc(signed_in: true)

    rail_seat = page.at_css("[data-nav-tools] [data-nav-menu-trigger]")
    refute_nil rail_seat
    assert_equal %w[hidden md:block], rail_seat["class"].split, "desktop only in the rail"
    phone_row = page.at_css("header > div.md\\:hidden")
    assert_equal 1, phone_row.css("[data-slot-trigger]").size
    assert_equal 2, page.css("[data-slot-trigger]").size, "one per row"
  end

  # engine.css lights the gear, name and avatar together (THE ACCOUNT GROUP,
  # A HOST SIDEBAR) by finding a row whose icon column holds the menu trigger
  # seat and whose account is a host sidebar toggle. Pin those hooks, on one row.
  test "with both set, the row carries the account group's host hooks" do
    Studio.navbar_menu_trigger = "navbar_slot_fixtures/trigger"
    Studio.navbar_account_sidebar = GEAR
    page = doc(signed_in: true)
    account = page.at_css("[data-nav-account]")
    row = account.parent

    assert row.at_css("> [data-nav-tools] [data-nav-menu-trigger] [aria-controls]"), "the gear sits in the row's icon column"
    assert account.key?("data-profile-image-toggle")
    refute_includes account["aria-controls"].split, "studio-link-sidebar"
  end

  test "for an admin the trigger replaces both admin gears" do
    assert_equal 2, Nokogiri::HTML5(render(signed_in: true, admin: true)).css("[data-nav-admin-gear]").size,
                 "the admin dropdown draws in the rail and the phone row by default"

    Studio.navbar_menu_trigger = "navbar_slot_fixtures/trigger"
    page = Nokogiri::HTML5(render(signed_in: true, admin: true))
    assert_empty page.css("[data-nav-admin-gear]")
    assert_equal 2, page.css("[data-slot-trigger]").size
  end

  test "signed out, the trigger still takes the phone row's seat" do
    Studio.navbar_menu_trigger = "navbar_slot_fixtures/trigger"

    assert_equal 1, doc(signed_in: false).css("header > div.md\\:hidden [data-slot-trigger]").size
  end

  test "bad config is refused when assigned" do
    assert_raises(Studio::NavbarAccountSidebar::InvalidConfig) { Studio.navbar_account_sidebar = { flag: "a;b", controls: "p" } }
    assert_raises(Studio::NavbarSlots::InvalidConfig) { Studio.navbar_menu_trigger = ["navbar_slot_fixtures/trigger"] }
  end

  # studio/link_sidebar claims a click on a trigger whose aria-controls names
  # the engine's link sidebar, so this control would open the engine's panel.
  test "controls naming the engine's link sidebar are refused when assigned, and not kept" do
    Studio.navbar_account_sidebar = GEAR
    error = assert_raises(Studio::NavbarAccountSidebar::InvalidConfig) do
      Studio.navbar_account_sidebar = { flag: "gearOpen", controls: "studio-link-sidebar studio-link-sidebar-mobile" }
    end
    assert_match(/engine's link sidebar/, error.message)
    assert_equal GEAR, Studio.navbar_account_sidebar, "the refused value is not kept"

    Studio.navbar_account_sidebar = ->(_view) { { flag: "gearOpen", controls: "studio-link-sidebar" } }
    raised = assert_raises(ActionView::Template::Error, "a callable's answer is checked when it resolves") do
      render(signed_in: true)
    end
    assert_instance_of Studio::NavbarAccountSidebar::InvalidConfig, raised.cause
  end

  private

  def render(signed_in:, admin: false) = NavbarRenderHost.render_navbar(signed_in: signed_in, admin: admin)
  def doc(signed_in:) = Nokogiri::HTML5(render(signed_in: signed_in))
end
