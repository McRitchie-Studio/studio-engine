# frozen_string_literal: true

# [integration] Studio.navbar_brand, Studio.navbar_root_hook and
# Studio.navbar_z_tier through the dummy app: the host's logo at its size and
# a split wordmark in the title, the data-navbar-root hook live and preview,
# and the live header on the shared layer scale. Unset, all three render the
# 0.113.0 bytes.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_render_host"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarBrandRenderTest < ActiveSupport::TestCase
  TURF = { logo: "/icon-192.png", logo_size: 48,
           words: [{ text: "Turf", class: "dm-salmon" }, { text: "Monster", class: "dm-yellow tm-wordmark" }] }.freeze

  setup do
    @prior = [Studio.navbar_brand, Studio.navbar_root_hook, Studio.navbar_z_tier, Studio.app_name, Studio.theme_logos,
              Studio.navbar_wordmark]
    Studio.app_name = "Turf Monster"
    Studio.theme_logos = [{ file: "logo.png", title: "Navbar Logo" }]
  end

  teardown do
    Studio.navbar_brand, Studio.navbar_root_hook, Studio.navbar_z_tier, Studio.app_name, Studio.theme_logos,
      wordmark = @prior
    Studio.navbar_wordmark = wordmark
  end

  test "unset, all three render the same bytes as their explicit defaults" do
    plain = [render(signed_in: true), render(signed_in: false), render(signed_in: true, locals: "preview: true")]
    Studio.navbar_brand = nil
    Studio.navbar_root_hook = false
    Studio.navbar_z_tier = false

    assert_equal plain, [render(signed_in: true), render(signed_in: false), render(signed_in: true, locals: "preview: true")]
    refute_includes plain.first, "data-navbar-root"
    assert_includes header(plain.first)["class"].split, "z-50"
  end

  test "the brand draws the host's logo at its size and a split wordmark" do
    Studio.navbar_brand = TURF
    page = Nokogiri::HTML5(render(signed_in: true))
    logo = page.at_css("img.nav-logo")

    assert_equal "/icon-192.png", logo["src"]
    assert_equal %w[48 48], [logo["width"], logo["height"]]
    assert_equal "Turf Monster", logo["alt"]
    title = page.at_css("h1.nav-title")
    assert_equal [%w[dm-salmon truncate], %w[dm-yellow tm-wordmark truncate]], title.css("span").map { |s| s["class"].split }
    assert_equal "TurfMonster", title.text
    assert_empty title.css(".text-primary"), "the host's classes and nothing else"
  end

  test "a brand of words alone keeps the theme logo, and alt overrides the app name" do
    Studio.navbar_brand = { words: ["Turf"], alt: "Home" }
    page = Nokogiri::HTML5(render(signed_in: false))

    assert_equal "/logo.png", page.at_css("img.nav-logo")["src"]
    assert_equal "Home", page.at_css("img.nav-logo")["alt"]
    assert_nil page.at_css("img.nav-logo")["width"]
    assert_equal ["Turf"], page.css(".nav-title span").map(&:text)
  end

  test "the brand words are escaped" do
    Studio.navbar_brand = { words: ["<script>x</script>"] }

    assert_includes render(signed_in: false), "&lt;script&gt;x&lt;/script&gt;"
  end

  test "the wordmark wins over the brand" do
    Studio.navbar_brand = TURF
    Studio.navbar_wordmark = { light: "/l.svg", dark: "/d.svg" }
    page = Nokogiri::HTML5(render(signed_in: false))

    assert_nil page.at_css("img.nav-logo")
    assert_equal 2, page.css("img.nav-wordmark").size
  end

  test "the root hook marks the header live and on a preview" do
    Studio.navbar_root_hook = true

    assert header(render(signed_in: true)).key?("data-navbar-root")
    assert header(render(signed_in: true, locals: "preview: true")).key?("data-navbar-root")
  end

  test "the z tier layers the live header at --z-nav instead of z-50" do
    Studio.navbar_z_tier = true
    classes = header(render(signed_in: true))["class"].split

    assert_includes classes, "z-[var(--z-nav)]"
    refute_includes classes, "z-50"
    refute_includes header(render(signed_in: true, locals: "preview: true"))["class"], "z-", "a preview has no tier"
  end

  test "bad config is refused when assigned" do
    assert_raises(Studio::NavbarBrand::InvalidConfig) { Studio.navbar_brand = { logo_size: -1 } }
    assert_raises(ArgumentError) { Studio.navbar_root_hook = "yes" }
    assert_raises(ArgumentError) { Studio.navbar_z_tier = 1 }
  end

  private

  def render(signed_in:, locals: nil) = NavbarRenderHost.render_navbar(signed_in: signed_in, locals: locals)
  def header(html) = Nokogiri::HTML5(html).at_css("header")
end
