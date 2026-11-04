# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "rack/test"
require "fileutils"

# Studio::ErrorHandling#require_authentication answers turbo_stream, which a host
# registers through turbo-rails and the dummy does not load.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

# The host's base controller in the shape the strictest adopters have it: the
# engine's sign-in gate on every controller, and the hub's admin wall on top.
# Signing in is a request header, so the suite needs no users table.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  before_action :require_admin_wall
  layout "site_footer_host"

  def logged_in? = request.headers["X-Signed-In"].present?
  def current_user = nil

  private

  def require_admin_wall = (redirect_to "/walled" unless request.headers["X-Admin"].present?)
end

# The control: this host really does wall a page that says nothing.
class KitHostWalledController < ApplicationController
  def show = render(inline: "<h1>Walled</h1>", layout: true)
end

class KitHostOpenController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :require_admin_wall

  def show = render(inline: "<h1>Open</h1>", layout: true)
end

# [integration] /marketing-kit through a real request, in a host that gates every
# controller, and the footer's link to it.
class MarketingKitIntegrationTest < ActionDispatch::IntegrationTest
  ActionDispatch::IntegrationTest.app = Rails.application

  FILES = "kit-test"
  SIGNED_IN = { "X-Signed-In" => "1" }.freeze

  def self.draw_extra_routes
    Rails.application.routes.append do
      get "kit_host/walled", to: "kit_host_walled#show"
      get "kit_host/open", to: "kit_host_open#show"
    end
    Rails.application.reload_routes!
  end
  draw_extra_routes

  def setup
    @saved = { marketing_kit: Studio.marketing_kit, theme_logos: Studio.theme_logos, site_footer: Studio.site_footer,
               site_footer_controllers: Studio.site_footer_controllers, app_name: Studio.app_name }
    Studio.marketing_kit = nil
    Studio.theme_logos = []
    Studio.site_footer = nil
    Studio.site_footer_controllers = []
    Studio.app_name = "Example Co"
    Studio::SiteFooterHelper.reported = nil
    @dir = Rails.public_path.join(FILES)
    FileUtils.mkdir_p(@dir)
  end

  def teardown
    @saved.each { |key, value| Studio.public_send("#{key}=", value) }
    Studio::SiteFooterHelper.reported = nil
    FileUtils.rm_rf(@dir)
  end

  def write_file(name) = File.write(@dir.join(name), "x")

  # ---- the page, signed out --------------------------------------------------

  test "a host that walls every controller still serves the page to a visitor, with no setup" do
    get "/kit_host/walled"
    assert_response :redirect, "the control: this host must wall a page that says nothing"

    get "/marketing-kit"
    assert_response :success
    assert_select "h1", text: "Marketing Kit", count: 1
    assert_select "[data-marketing-kit] .mkit-lede", text: /The Example Co logos/
  end

  test "the route's helper is the engine's own, so it cannot collide with a host's marketing_kit name" do
    assert_equal "/marketing-kit", Rails.application.routes.url_helpers.studio_marketing_kit_path
    assert_nil Rails.application.routes.named_routes[:marketing_kit]
  end

  test "with nothing configured the colours are the theme's and every part with nothing is gone" do
    get "/marketing-kit"

    Studio.theme_config.each_value do |hex|
      assert_select "[data-test='kit-colours'] code.mkit-hex", text: hex
    end
    assert_select "[data-test='kit-logos']", 0
    assert_select "[data-test='kit-type']", 0
    assert_select ".mkit-tagline", 0
    assert_select "[data-marketing-kit] img", 0
  end

  test "theme_logos derives the logos, and a logo whose file is not there shows nothing" do
    write_file("mark-light.svg")
    write_file("mark-dark.png")
    Studio.theme_logos = [{ file: "#{FILES}/mark-light.svg", title: "Mark" },
                          { file: "#{FILES}/gone.png", title: "Gone" },
                          { file: "/#{FILES}/also-gone.svg", title: "Also gone" }]

    get "/marketing-kit"
    assert_response :success

    assert_select "[data-test='kit-logos'] .mkit-name", text: "Mark", count: 1
    assert_select "[data-test='kit-logos'] .mkit-name", text: "Gone", count: 0
    assert_select "[data-test='kit-logos'] img", 2
    assert_select "[data-test='kit-logos'] img[src=?]", "/#{FILES}/mark-light.svg?kit"
    assert_select "[data-test='kit-logos'] a[download][href=?]", "/#{FILES}/mark-light.svg", text: "Download Light"
    assert_select "[data-test='kit-logos'] a[download][href=?]", "/#{FILES}/mark-dark.png", text: "Download Dark"
  end

  test "a declared kit prints whole, each link reading exactly Download Light or Download Dark" do
    %w[icon-light.png icon-light.svg icon-dark.png icon-dark.svg].each { |name| write_file(name) }
    Studio.marketing_kit = lambda do |view|
      raise "the callable takes the view" unless view.respond_to?(:studio_marketing_kit_path)

      { name: "Declared Co", tagline: "Everything, by example",
        logos: [{ title: "Icon", light: { png: "/#{FILES}/icon-light.png", svg: "/#{FILES}/icon-light.svg" },
                                 dark: { png: "/#{FILES}/icon-dark.png", svg: "/#{FILES}/icon-dark.svg" } }],
        palette: [{ name: "Ink", hex: "#1A1535" }],
        typefaces: [{ role: "Headings", family: "Montserrat", weight: 800, name: "Montserrat ExtraBold" }] }
    end

    get "/marketing-kit"
    assert_response :success

    assert_select ".mkit-tagline", text: "Everything, by example"
    assert_select ".mkit-lede", text: /The Declared Co logos/
    assert_equal ["Download Light", "Download Dark"], css_select("a[download]").map { |a| a.text.strip }
    assert_equal ["/#{FILES}/icon-light.png", "/#{FILES}/icon-dark.png"], css_select("a[download]").map { |a| a["href"] }
    assert_equal ["/#{FILES}/icon-light.svg?kit", "/#{FILES}/icon-dark.svg?kit"], css_select("[data-test='kit-logos'] img").map { |i| i["src"] }
    assert_select ".mkit-specimen[style*='font-family: Montserrat'][style*='font-weight: 800']"
    assert_select ".mkit-face-label", text: "Headings · Montserrat ExtraBold"
  end

  test "a colour is one button, naming the controller, the hex and no inline handler" do
    Studio.marketing_kit = { palette: [{ name: "Ink", hex: "#1A1535" }] }

    get "/marketing-kit"

    assert_select "[data-studio-controller='copy-text'][data-copy-text-text-value='#1A1535']", 1 do
      assert_select "button[data-studio-action='click->copy-text#copy']", 1 do
        assert_select ".mkit-chip[style='background-color: #1A1535']", 1
        assert_select "code.mkit-hex", text: "#1A1535"
      end
      assert_select "[role='status'][data-copy-text-target='status']", 1
    end
    assert_no_match(/\son(click|load|error)=/i, css_select("[data-marketing-kit]").to_s)
  end

  test "a kit callable that raises shows here, and in production costs only its own facts" do
    Studio.marketing_kit = ->(_view) { raise "the kit's own bug" }

    controller = KitHostOpenController.new
    controller.request = ActionDispatch::TestRequest.create
    view = controller.view_context
    assert_raises(RuntimeError) { view.studio_marketing_kit }

    view.define_singleton_method(:studio_site_footer_raise?) { false }
    reported = []
    view.define_singleton_method(:studio_site_footer_report) { |error| reported << error.message }

    kit = view.studio_marketing_kit

    assert_equal ["the kit's own bug"], reported
    assert_equal Studio.theme_config.values, kit[:palette].map { |swatch| swatch[:hex] }
  end

  # ---- the footer ------------------------------------------------------------

  test "the footer links the page with nothing declared, on the page and on another, in the brand block" do
    ["/marketing-kit", "/kit_host/open"].each do |path|
      get path
      assert_select "footer[data-site-footer] .ftr-brand .ftr-kit a.ftr-link[href='/marketing-kit']", { text: "Marketing Kit", count: 1 }, path
    end
  end

  test "an app's own facts get the link too, and its columns and legal line stay what it wrote" do
    Studio.site_footer = { name: "Example Co", columns: [["Company", [["Home", "/"]]]], legal: [["Privacy Policy", "/privacy"]] }

    get "/kit_host/open"

    assert_select "footer[data-site-footer] a[href='/marketing-kit']", 1
    assert_select "footer[data-site-footer] .ftr-brand a[href='/marketing-kit']", 1
    assert_select "footer[data-site-footer] nav.ftr-col a", 1
    assert_select "footer[data-site-footer] .ftr-legal a", 1
    assert_select "footer[data-site-footer] .ftr-legal p", 2
  end

  { "a column" => { columns: [["Company", [["Home", "/"], ["Our Kit", "/marketing-kit"]]]] },
    "the legal line" => { legal: [["Our Kit", "/marketing-kit"]] },
    "a column, with a query" => { columns: [["Company", [["Our Kit", "/marketing-kit/?from=footer"]]]] } }.each do |where, facts|
    test "an app that links the page in #{where} keeps its own row and gets no second" do
      Studio.site_footer = facts.merge(name: "Example Co")

      get "/kit_host/open"

      assert_select "footer[data-site-footer] a[href^='/marketing-kit']", 1
      assert_select "footer[data-site-footer] .ftr-kit", 0
      assert_select "footer[data-site-footer] a", text: "Our Kit", count: 1
    end
  end

  test "marketing_kit: false in the facts shows no link" do
    Studio.site_footer = { name: "Example Co", marketing_kit: false }

    get "/kit_host/open"

    assert_select "footer[data-site-footer]", 1
    assert_select "footer[data-site-footer] a[href='/marketing-kit']", 0
  end

  test "a signed-in viewer keeps the footer on the page, and on no working surface it did not have" do
    get "/marketing-kit", headers: SIGNED_IN
    assert_response :success
    assert_select "footer[data-site-footer] .ftr-kit a[href='/marketing-kit']", 1

    get "/kit_host/open", headers: SIGNED_IN
    assert_select "footer[data-site-footer]", 0
  end

  test "with the flag off there is no page and no link" do
    Studio.draw_marketing_kit_routes = false
    Rails.application.reload_routes!

    get "/kit_host/open"
    assert_select "footer[data-site-footer]", 1
    assert_select "footer[data-site-footer] .ftr-kit", 0

    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/marketing-kit") }
  ensure
    Studio.draw_marketing_kit_routes = true
    Rails.application.reload_routes!
  end

  # ---- a host route of the same path -------------------------------------------

  HOST_PAGE = ->(_env) { [200, { "content-type" => "text/plain" }, ["the host's page"]] }

  def route_set(&block)
    ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&block) }
  end

  def body_at(set, path) = Rack::MockRequest.new(set).get(path).body

  test "a host route drawn BEFORE Studio.routes wins, the engine draws nothing and no name is claimed" do
    set = route_set do
      get "marketing-kit", to: HOST_PAGE, as: :marketing_kit
      Studio.marketing_kit_routes(self)
    end

    assert_equal "the host's page", body_at(set, "/marketing-kit")
    assert_nil set.named_routes[:studio_marketing_kit], "a host walking its route table must not see the engine's page"
    assert_equal 1, set.routes.size
    assert Studio::MarketingKit.host_route?(set)
  end

  test "a host route drawn AFTER Studio.routes wins too, at request time" do
    set = route_set do
      Studio.marketing_kit_routes(self)
      get "marketing-kit", to: HOST_PAGE, as: :marketing_kit
    end

    assert set.named_routes[:studio_marketing_kit], "the engine drew first, knowing nothing yet"
    assert_equal "the host's page", body_at(set, "/marketing-kit")
  end

  test "a POST or another path of the host's is not its page" do
    set = route_set do
      post "marketing-kit", to: HOST_PAGE
      get "marketing-kit/extra", to: HOST_PAGE
      Studio.marketing_kit_routes(self)
    end

    assert set.named_routes[:studio_marketing_kit]
    refute Studio::MarketingKit.host_route?(set)
  end

  test "an app whose own route has another helper name still gets the footer link, on that path" do
    set = route_set { get "marketing-kit", to: HOST_PAGE, as: :press_kit }
    view = Object.new

    assert_equal "/marketing-kit", Studio::MarketingKit.page_path(view, set)
  end

  test "an app with neither has no page to link" do
    assert_nil Studio::MarketingKit.page_path(Object.new, route_set { get "other", to: HOST_PAGE })
    assert_nil Studio::MarketingKit.page_path(Object.new, nil)
  end
end
