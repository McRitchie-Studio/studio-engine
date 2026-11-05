# frozen_string_literal: true

# [integration] A section's opt-in header (header: true) through the dummy app: the host's
# declaration, Studio::SidebarSections, the engine navbar and the link sidebar's partial, then
# the engine lab's page. The engine's own "You" section stays without a word.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_render_host"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch/testing/integration"
require "nokogiri"

class LinkSidebarHeaderRenderTest < ActionDispatch::IntegrationTest
  HEADER = "#studio-link-sidebar [data-sidebar-group-header]"
  GROUPS = '#studio-link-sidebar nav > [role="group"]'
  DECLARED = [
    { "title" => "My Apps", "header" => true, "links" => [{ "label" => "Home", "href" => "/", "emoji" => "*" }] },
    { title: "Help", links: [{ label: "Docs", href: "/docs", emoji: "*" }] },
    { title: "Admin", admin: true, header: true, links: [{ label: "Errors", href: "/up", emoji: "*" }] }
  ].freeze

  setup { @prior = Studio.sidebar_sections }
  teardown { Studio.sidebar_sections = @prior }

  test "a host's header: true reaches the panel, and only for the sections that opted in" do
    Studio.sidebar_sections = DECLARED
    page = Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true, admin: true))

    assert_equal ["My Apps", "Admin"], page.css(HEADER).map(&:text)
    names = page.css(GROUPS).map { |group| group["aria-label"] }
    assert_equal ["You", "My Apps", "Help", "Admin"], names.first(4), "the engine's You section leads, with no word"
    assert_includes page.css(GROUPS).first.text, "Profile"
    refute_includes page.css(GROUPS).first.text, "You"
  end

  test "a section an admin alone may see takes its header with it" do
    Studio.sidebar_sections = DECLARED
    page = Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true, admin: false))

    assert_equal ["My Apps"], page.css(HEADER).map(&:text)
  end

  test "no section opted in: no header, and the groups' names are unchanged" do
    Studio.sidebar_sections = DECLARED.map { |section| section.to_h.except(:header, "header") }
    page = Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true, admin: true))

    assert_empty page.css(HEADER)
    assert_equal ["You", "My Apps", "Help", "Admin"], page.css(GROUPS).map { |group| group["aria-label"] }.first(4)
  end

  test "the engine lab shows the case on its own knob and leaves the plain page alone" do
    get "/lab/sidebar_panels?sidebar=1&headers=1&admin=1"
    assert_response :success
    assert_equal ["My Apps", "Admin"], Nokogiri::HTML5(response.body).css(HEADER).map(&:text)

    get "/lab/sidebar_panels?sidebar=1&admin=1"
    assert_response :success
    assert_empty Nokogiri::HTML5(response.body).css(HEADER)
  end
end
