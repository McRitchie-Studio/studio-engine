# frozen_string_literal: true

# One h1 per page. The layout draws the engine navbar after the page has
# rendered, so the navbar knows whether the page has an h1 of its own: the
# standard page header (studio/_page_header) records one, and a hand-written
# h1 in the page body counts too. Then the brand is a div with the same
# classes; otherwise it stays the page's h1. An explicit brand_heading wins.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarOneH1RenderHostController < ActionController::Base
  helper_method :logged_in?, :root_path, :current_user

  def logged_in? = false
  def root_path = "/"
  def current_user = nil
end

class NavbarOneH1RenderTest < ActiveSupport::TestCase
  BRAND_CLASSES = "nav-title font-extrabold text-heading tracking-tight min-w-0"
  PAGE_HEADER = %(<%= render "studio/page_header", title: "Contests" %>)

  setup do
    @prior_app_name = Studio.app_name
    Studio.app_name = "Lab Studio"
  end

  teardown { Studio.app_name = @prior_app_name }

  test "a page with the standard header has exactly one h1, and the brand is not it" do
    doc = render_page(PAGE_HEADER)

    assert_equal ["Contests"], doc.css("h1").map { |h| h.text.strip }
    assert_equal ["page-header-title"], doc.css("h1").map { |h| h["class"] }
    brand = doc.at_css("header a.nav-logo-link > .nav-title")
    assert_equal "div", brand.name, "the brand is a div beside the page's h1"
    assert_equal BRAND_CLASSES, brand["class"], "the brand keeps its classes, the stable selector"
    assert_equal %w[Lab Studio], brand.css("span").map(&:text)
  end

  test "a page with no h1 of its own keeps the brand as its one h1" do
    doc = render_page(%(<h2>Profile</h2><p>Settings</p>))

    assert_equal 1, doc.css("h1").size
    assert_equal BRAND_CLASSES, doc.at_css("h1")["class"]
    assert_equal "LabStudio", doc.at_css("h1").text.strip
  end

  test "a hand-written h1 in the page body counts as the page's own" do
    doc = render_page(%(<h1 class="text-2xl">Style</h1>))

    assert_equal ["Style"], doc.css("h1").map { |h| h.text.strip }
    assert doc.at_css("header div.nav-title")
  end

  test "an h1 lookalike tag does not count" do
    doc = render_page(%(<h10>not a heading</h10><h2>Errors</h2>))

    assert_equal 1, doc.css("h1").size
    assert doc.at_css("header h1.nav-title")
  end

  test "a page header drawn through content_for, outside the page body, still counts" do
    controller = Class.new(NavbarOneH1RenderHostController) do
      def self.name = "NavbarOneH1ContentForController"
    end
    # The page header goes into a content_for block that this layout never
    # yields, so only the recorded mark can tell the navbar about it.
    doc = Nokogiri::HTML(controller.render(inline: %(<% content_for :page_top do %>#{PAGE_HEADER}<% end %><p>body</p>),
                                           layout: "one_h1_lab"))

    assert_empty doc.css("h1"), "the header was never drawn, so only the mark was recorded"
    assert doc.at_css("header div.nav-title"), "the mark alone draws the brand as a div"
  end

  test "an explicit brand_heading wins over the page" do
    with_header = render_page(PAGE_HEADER, brand_heading: true)
    assert_equal 2, with_header.css("h1").size, "true keeps the brand h1 beside the page's"
    assert with_header.at_css("header h1.nav-title")

    without = render_page(%(<h2>Profile</h2>), brand_heading: false)
    assert_empty without.css("h1"), "false makes the brand a div even with no page h1"
    assert without.at_css("header div.nav-title")
  end

  test "a preview navbar keeps the brand h1 by default" do
    html = NavbarOneH1RenderHostController.render(
      inline: %(#{PAGE_HEADER}<%= render "layouts/navbar", preview: true %>)
    )

    assert Nokogiri::HTML(html).at_css("h1.nav-title")
  end

  test "the helper reads the mark and the page body" do
    view = NavbarOneH1RenderHostController.new.view_context
    refute view.studio_page_has_h1?

    view.studio_page_h1!
    view.studio_page_h1!
    assert view.studio_page_has_h1?
    assert_equal "1", view.content_for(:studio_page_h1), "the mark is recorded once"

    body_view = NavbarOneH1RenderHostController.new.view_context
    body_view.view_flow.set(:layout, "<main><H1>Shout</H1></main>".html_safe)
    assert body_view.studio_page_has_h1?
  end

  # The engine's own pages. Those with no heading of their own keep the brand
  # as their one h1, so they must not grow an h1 or a page header unnoticed;
  # the style guide draws the standard header, so its brand is a div.
  NO_OWN_H1 = %w[
    app/views/studio/profiles/show.html.erb
    app/views/studio/profiles/edit.html.erb
    app/views/error_logs/index.html.erb
    app/views/error_logs/show.html.erb
  ].freeze

  test "engine pages with no heading of their own leave the brand as the page's h1" do
    root = File.expand_path("../..", __dir__)
    NO_OWN_H1.each do |path|
      source = File.read(File.join(root, path))
      refute_match NavbarOneH1RenderTest.page_h1, source, "#{path}: an h1 of its own"
      refute_includes source, "studio/page_header", "#{path}: the standard header"
    end
    assert_includes File.read(File.join(root, "app/views/style/index.html.erb")), %(render "studio/page_header")
  end

  def self.page_h1 = StudioNavbarHelper::PAGE_H1

  private

  def render_page(body, **navbar_locals)
    controller = Class.new(NavbarOneH1RenderHostController) do
      def self.name = "NavbarOneH1PageController"
    end
    Nokogiri::HTML(controller.render(inline: body, layout: "one_h1_lab", assigns: { navbar_locals: navbar_locals.presence }))
  end
end
