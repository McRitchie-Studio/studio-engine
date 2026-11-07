# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "rack/mock"
require "tmpdir"

# [integration] Studio::ExceptionsApp, the one-line opt-in for the friendly
# not-found page (docs/NOT_FOUND_PAGE.md): config.exceptions_app = Studio::ExceptionsApp.new
#
# These run a request the way production does. Rails' own ShowExceptions wraps
# the dummy app with this exceptions app, and the dummy app raises: an unknown
# address raises RoutingError and a missing record raises RecordNotFound. The
# dummy app runs show_exceptions :none (it re-raises for the other suites), so
# the outer ShowExceptions is the one that answers, as the app's own does in
# production.
#
# Every status is asserted as exactly 404. The page must never be a 200, and it
# must never redirect, even when the host's controller tries to.

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email
    t.string :name
    t.string :role
    t.timestamps
  end
  create_table :error_logs, force: true do |t|
    t.string :slug
    t.text :message
    t.text :inspect
    t.text :backtrace
    t.string :target_type
    t.bigint :target_id
    t.string :parent_type
    t.bigint :parent_id
    t.timestamps
  end
end

class User < ApplicationRecord
  def admin? = role == "admin"
end

# The host's ApplicationController, with its own layout: navbar and footer stand-ins.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  LAYOUTS = Dir.mktmpdir("studio-not-found-layouts")
  FileUtils.mkdir_p(File.join(LAYOUTS, "layouts"))
  File.write(File.join(LAYOUTS, "layouts/application.html.erb"), <<~ERB)
    <!DOCTYPE html>
    <html><head><title><%= content_for(:title) %></title></head>
    <body><nav data-test="host-navbar">Host nav</nav><main><%= yield %></main><footer data-test="host-footer">Host footer</footer></body></html>
  ERB
  prepend_view_path LAYOUTS
  layout "application"

  # A host wall that knows nothing of the page: what it does is the test's choice.
  before_action :host_wall

  class_attribute :wall, default: nil

  private

  def host_wall
    case self.class.wall
    when :redirect then redirect_to "/login"
    when :raise then raise "the layout's database is down"
    end
  end
end

class NotFoundProbesController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :host_wall

  def missing
    User.find(-1)
  end
end

Rails.application.routes.append do
  get "not_found_probe/missing", to: "not_found_probes#missing"
end
Rails.application.reload_routes!

class NotFoundExceptionsAppTest < ActiveSupport::TestCase
  STATIC_404 = '<!DOCTYPE html><html><body data-test="not-found" data-static>Static 404</body></html>'

  def setup
    @public = Dir.mktmpdir("studio-not-found-public")
    File.write(File.join(@public, "404.html"), STATIC_404)
    File.write(File.join(@public, "500.html"), "<html><body>Static 500</body></html>")
    ApplicationController.wall = nil
    ErrorLog.delete_all
    Studio.navbar_brand = nil
  end

  def teardown
    FileUtils.rm_rf(@public)
    ApplicationController.wall = nil
    Studio.navbar_brand = nil
  end

  # The dummy app inside ShowExceptions with this exceptions app, as a host's
  # middleware stack has it. Rails.application.call writes the dummy's
  # show_exceptions :none into the env; the ensure hands the outer layer :all,
  # the production value, before the exception reaches it.
  def request(path, accept: "text/html", referer: nil, exceptions_app: Studio::ExceptionsApp.new(@public))
    inner = lambda do |env|
      Rails.application.call(env)
    ensure
      env["action_dispatch.show_exceptions"] = :all
      env["action_dispatch.show_detailed_exceptions"] = false
    end
    app = ActionDispatch::ShowExceptions.new(inner, exceptions_app)
    headers = { "HTTP_ACCEPT" => accept, "HTTP_HOST" => "example.org" }
    headers["HTTP_REFERER"] = referer if referer
    status, response_headers, body = app.call(Rack::MockRequest.env_for("http://example.org#{path}", headers))
    text = +""
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)
    [status, response_headers, Nokogiri::HTML(text), text]
  end

  test "an unknown address answers 404 with the friendly page inside the host's layout" do
    Studio.navbar_brand = { logo: "/brand/mark.svg" }
    status, headers, doc = request("/no-such-page")

    assert_equal 404, status
    assert_match %r{\Atext/html}, headers["content-type"]
    assert_nil headers["location"], "never a redirect"
    page = doc.at_css("main [data-test='not-found']")
    assert page, "the page sits in the host's main"
    assert doc.at_css("[data-test='host-navbar']"), "the host's navbar"
    assert doc.at_css("[data-test='host-footer']"), "the host's footer"
    assert_nil page["data-static"], "the page, not the static file"
    assert_equal "Page not found · #{Studio.app_name}", doc.at_css("title").text
    home = page.at_css("a[data-test='not-found-home']")
    assert_equal "/", home["href"], "home is the app's root"
    assert_equal "Back to #{Studio.app_name}", home.text
    assert_equal "/brand/mark.svg", page.at_css("img")["src"], "the brand mark from the app's config"
  end

  test "a missing record answers 404 with the page, and writes no ErrorLog row" do
    status, _, doc = request("/not_found_probe/missing")

    assert_equal 404, status
    assert doc.at_css("main [data-test='not-found'] a[data-test='not-found-home'][href='/']")
    assert_equal 0, ErrorLog.count, "a 404 is not an error"
  end

  test "Accept */* (curl, monitors, crawlers) gets the HTML page with 404" do
    status, headers, doc = request("/no-such-page", accept: "*/*")

    assert_equal 404, status
    assert_match %r{\Atext/html}, headers["content-type"]
    assert doc.at_css("main [data-test='not-found']")
  end

  test "a JSON request gets a 404 JSON answer, not the page" do
    status, headers, _, text = request("/no-such-page", accept: "application/json")

    assert_equal 404, status
    assert_match %r{\Aapplication/json}, headers["content-type"]
    assert_equal({ "status" => 404, "error" => "Not Found" }, JSON.parse(text))
    refute_includes text, "<html"
  end

  test "a .json address on a missing record is a 404 JSON answer too" do
    status, headers, _, text = request("/not_found_probe/missing.json", accept: "*/*")

    assert_equal 404, status
    assert_match %r{\Aapplication/json}, headers["content-type"]
    assert_equal 404, JSON.parse(text)["status"]
  end

  test "a page on this app the visitor came from adds Go back; another site's does not" do
    _, _, doc = request("/no-such-page", referer: "http://example.org/dashboard?tab=2")
    assert_equal "/dashboard?tab=2", doc.at_css("a[data-test='not-found-back']")["href"]

    _, _, doc = request("/no-such-page", referer: "https://elsewhere.example/page")
    assert_nil doc.at_css("a[data-test='not-found-back']"), "no link back to another site"
  end

  test "a host wall that redirects cannot turn the 404 into a redirect: the static page answers" do
    ApplicationController.wall = :redirect
    status, headers, doc = request("/no-such-page")

    assert_equal 404, status
    assert_nil headers["location"]
    assert doc.at_css("body[data-static]"), "public/404.html, the last resort"
  end

  test "a page that raises falls back to public/404.html with 404, and does not loop" do
    ApplicationController.wall = :raise
    status, _, doc = request("/no-such-page")

    assert_equal 404, status
    assert doc.at_css("body[data-static]")
  end

  test "a page endpoint that answers 200 is thrown away: the status stays 404" do
    ok = ->(_env) { [200, { "content-type" => "text/html" }, ["<p>fine</p>"]] }
    status, _, doc = request("/no-such-page", exceptions_app: Studio::ExceptionsApp.new(@public, page: ok))

    assert_equal 404, status
    assert doc.at_css("body[data-static]")
  end

  test "other statuses keep Rails' public pages" do
    app = Studio::ExceptionsApp.new(@public)
    status, _, body = app.call(Rack::MockRequest.env_for("/500", "HTTP_ACCEPT" => "text/html"))

    assert_equal 500, status
    assert_includes body.join, "Static 500"
  end
end
