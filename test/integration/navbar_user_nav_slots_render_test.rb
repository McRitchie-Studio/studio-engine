# frozen_string_literal: true

# [integration] layouts/_navbar forwards components/_user_nav's slot locals
# (balance_slot, extra_icons_slot, div2_slot, div2_html), so an app rendering
# the engine navbar can fill the user nav's second row and balance seat without
# forking either partial. A navbar that passes none renders as in 0.113.0.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_render_host"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarUserNavSlotsRenderTest < ActiveSupport::TestCase
  SECTIONS = [{ title: "Site", links: [{ label: "Home", href: "/", emoji: "*" }] }].freeze

  setup { @prior_sections = Studio.sidebar_sections }
  teardown { Studio.sidebar_sections = @prior_sections }

  test "div2_slot reaches the user nav's second row, and makes it a two-row nav" do
    doc = parse(render(locals: %(div2_slot: "user_nav_fixtures/div2")))
    tools = doc.at_css("[data-nav-tools]")

    assert_equal "SLOT-DIV2", tools.at_css("[data-slot=div2]").text
    assert_equal "2", tools["data-nav-rows"]
  end

  test "a hash div2_slot carries its locals, and div2_html is forwarded too" do
    doc = parse(render(locals: %(div2_slot: { partial: "user_nav_fixtures/balance_amount", locals: { amount: 7 } })))
    assert_equal "$7", doc.at_css("[data-nav-tools] [data-slot=balance-amount]").text

    doc = parse(render(locals: %(div2_html: "<em data-legacy-div2>d</em>")))
    refute_nil doc.at_css("[data-nav-tools] [data-legacy-div2]")
  end

  test "balance_slot renders in the balance seat and reserves the balance column" do
    doc = parse(render(locals: %(balance_slot: "user_nav_fixtures/balance")))

    refute_nil doc.at_css("[data-nav-tools] [data-slot=balance]")
    assert_includes doc.at_css("[data-nav-tools]").ancestors("div.flex-shrink-0").first["class"].split, "user-nav-col"
  end

  test "extra_icons_slot renders in the icon rail, and the link sidebar's trigger still follows it" do
    Studio.sidebar_sections = SECTIONS
    doc = parse(render(locals: %(extra_icons_slot: "user_nav_fixtures/icons")))
    rail = doc.at_css("[data-nav-tools] div.ml-auto")

    order = rail.css("[data-slot=icons], [data-link-sidebar-trigger]").map { |el| el["data-slot"] || "trigger" }
    assert_equal %w[icons trigger], order, "the slot, then the trigger the navbar appends"
  end

  test "a slot wins over its legacy string, as on the user nav" do
    doc = parse(render(locals: %(div2_slot: "user_nav_fixtures/div2", div2_html: "<em data-legacy-div2>d</em>")))

    refute_nil doc.at_css("[data-slot=div2]")
    assert_nil doc.at_css("[data-legacy-div2]")
  end

  test "no slots passed renders the same bytes as passing only the legacy strings as nil" do
    assert_equal render(locals: "balance_html: nil, extra_icons_html: nil"), render
    assert_equal render, render(locals: "balance_slot: nil, div2_slot: nil, extra_icons_slot: nil, div2_html: nil")
  end

  private

  def parse(html) = Nokogiri::HTML5(html)

  def render(locals: nil)
    NavbarRenderHost.render_navbar(signed_in: true, locals: locals)
  end
end
