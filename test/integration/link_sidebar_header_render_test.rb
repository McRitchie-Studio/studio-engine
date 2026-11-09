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

  setup { @prior = [Studio.sidebar_sections, Studio.sidebar_geo_signpost, Studio.sidebar_style] }
  teardown { Studio.sidebar_sections, Studio.sidebar_geo_signpost, Studio.sidebar_style = @prior }

  test "the panel style defaults to the drawer, and the real writer validates" do
    assert_equal :default, Studio.sidebar_style
    Studio.sidebar_style = "glass"
    assert_equal :glass, Studio.sidebar_style
    assert_raises(ArgumentError) { Studio.sidebar_style = :frosted }
    assert_equal :glass, Studio.sidebar_style, "a refused value leaves the setting alone"
  end

  test "the surface style defaults to today's cards, and the real writer validates" do
    prior = Studio.surface_style
    assert_equal :default, prior
    Studio.surface_style = "glass"
    assert_equal :glass, Studio.surface_style
    assert_raises(ArgumentError) { Studio.surface_style = :frosted }
    assert_equal :glass, Studio.surface_style
  ensure
    Studio.surface_style = prior
  end

  test "a glass panel reaches a real page with the helper the host never wired" do
    Studio.sidebar_sections = [{ title: "Admin", header: true, links: [{ label: "Errors", href: "/up", emoji: "*", icon: "activity" }] }]
    Studio.sidebar_style = :glass
    page = Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true, admin: true))

    refute_nil page.at_css("#studio-link-sidebar[data-sidebar-glass] > [data-sidebar-glass-shell]")
    refute_nil page.at_css('#studio-link-sidebar nav a[href="/up"] [data-sidebar-row-icon] svg')
    refute_nil page.at_css('#studio-link-sidebar a[href="/logout"] svg')
  end

  # Turbo 8 prefetches a link the pointer rests on, and a prefetched GET /logout
  # signed the browser out (docs/DEVICE_SESSIONS.md, "Prefetch").
  test "Log out is never prefetched, in the drawer and in glass" do
    Studio.sidebar_sections = DECLARED
    [:default, :glass].each do |style|
      Studio.sidebar_style = style
      page = Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true))
      logout = page.at_css('#studio-link-sidebar a[href="/logout"]')

      refute_nil logout, "#{style}: the panel draws Log out"
      assert_equal "false", logout["data-turbo-prefetch"], "#{style}: Log out opts out of Turbo's prefetch"
    end
  end

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

  test "sidebar_geo_signpost false takes the Geo group out of the navbar's panel, and the partial still renders" do
    Studio.sidebar_sections = DECLARED
    group_names = ->(page) { page.css(GROUPS).map { |group| group["aria-label"] } }

    assert_includes group_names.call(Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true, admin: true))), "Geo, admin"

    Studio.sidebar_geo_signpost = false
    assert_equal ["You", "My Apps", "Help", "Admin"], group_names.call(Nokogiri::HTML5(NavbarRenderHost.render_navbar(signed_in: true, admin: true)))

    html = NavbarRenderHost.render_inline(%(<%= render "components/geo_signpost", variant: :sidebar, close_action: "" %>), signed_in: true, admin: true)
    assert_includes html, "Geo", "the partial is the host's to render on its own page"
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
