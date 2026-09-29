# frozen_string_literal: true

# Renders the engine navbar through the dummy app and pins Studio.navbar_links:
# registered links land in the desktop bar AND the phone row, the active link
# carries aria-current, badges render, text is escaped, and an app that
# registers nothing gets the slots' pre-feature bytes.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarLinksRenderHostController < ActionController::Base
  helper_method :logged_in?, :root_path, :current_user

  def logged_in? = false
  def root_path = "/"
  def current_user = Struct.new(:rank).new(12)
end

class NavbarLinksRenderTest < ActiveSupport::TestCase
  # The slots exactly as the navbar rendered them before navbar_links existed.
  EMPTY_DESKTOP_SLOT = %(<nav class="hidden md:flex items-center gap-4">\n        </nav>)
  EMPTY_PHONE_ROW_OPEN = %(bg-surface-alt">\n    <span class="ml-auto)

  LINKS = [
    { label: "Contests", href: "/contests", active: %r{\A/contests} },
    { label: "Rank", href: "/rank", badge: "#12" }
  ].freeze

  setup { @prior_navbar_links = Studio.navbar_links }
  teardown { Studio.navbar_links = @prior_navbar_links }

  test "nothing registered renders the pre-feature slots and no link markup" do
    Studio.navbar_links = []
    html = render_navbar

    assert_includes html, EMPTY_DESKTOP_SLOT
    assert_includes html, EMPTY_PHONE_ROW_OPEN
    refute_includes html, "aria-current"
    refute_includes html, %(aria-label="Main")
  end

  test "an empty lambda renders the same bytes as the empty default" do
    Studio.navbar_links = []
    empty = render_navbar
    Studio.navbar_links = ->(_view) { [] }

    assert_equal empty, render_navbar
  end

  test "registered links render in both the desktop bar and the phone row" do
    Studio.navbar_links = LINKS
    doc = Nokogiri::HTML(render_navbar(path: "/contests/7"))

    desktop = doc.at_css("nav.hidden.md\\:flex")
    phone = doc.at_css("div.md\\:hidden nav")

    [desktop, phone].each do |nav|
      assert_equal "Main", nav["aria-label"]
      assert_equal ["/contests", "/rank"], nav.css("a").map { |a| a["href"] }
      assert_equal "Contests", nav.css("a").first.text
    end
    assert_includes desktop.css("a").first["class"], "text-sm"
    assert_includes phone.css("a").first["class"], "text-xs"
  end

  test "the active link carries aria-current and the primary tone; others do not" do
    Studio.navbar_links = LINKS
    doc = Nokogiri::HTML(render_navbar(path: "/contests/7"))

    contests, rank = doc.css("nav.hidden.md\\:flex a")
    assert_equal "page", contests["aria-current"]
    assert_includes contests["class"].split, "text-primary"
    assert_nil rank["aria-current"]
    assert_includes rank["class"].split, "text-secondary"
    assert_equal 2, doc.css("[aria-current=page]").size, "one per slot"
  end

  test "a badge renders inside its link, and the lambda reads current_user" do
    Studio.navbar_links = ->(view) { [{ label: "Rank", href: "/rank", badge: "##{view.current_user.rank}" }] }
    doc = Nokogiri::HTML(render_navbar)

    badges = doc.css("nav a span.rounded-full")
    assert_equal ["#12", "#12"], badges.map(&:text)
  end

  test "labels, badges and hrefs are escaped" do
    Studio.navbar_links = [{ label: "<b>x</b>", href: %(/a"onmouseover="y), badge: "<i>1</i>" }]
    html = render_navbar

    refute_includes html, "<b>x</b>"
    refute_includes html, "<i>1</i>"
    refute_includes html, %("onmouseover=)
    assert_includes html, "&lt;b&gt;x&lt;/b&gt;"
    assert_includes html, "&lt;i&gt;1&lt;/i&gt;"
  end

  test "a bad static list is refused when assigned, before any render" do
    error = assert_raises(Studio::NavbarLinks::InvalidLink) { Studio.navbar_links = [{ label: "No href" }] }

    assert_match(/navbar_links\[0\].*:href/, error.message)
  end

  private

  def render_navbar(path: "/")
    controller = NavbarLinksRenderHostController.new
    controller.request = ActionDispatch::TestRequest.create("PATH_INFO" => path)
    controller.response = ActionDispatch::TestResponse.new
    controller.render_to_string(inline: %(<%= render "layouts/navbar" %>))
  end
end
