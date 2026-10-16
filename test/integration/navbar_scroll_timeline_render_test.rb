# frozen_string_literal: true

# [integration] The scroll-driven collapse's opt-in, rendered through the real
# dummy Rails app. The collapse itself is computed style on a scroll timeline
# (e2e/navbar_scroll_timeline.spec.js); what the response bytes CAN show is who
# gets the attribute that turns it on, and that nobody else does.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

# The signed-out host, enough to render the navbar.
class NavbarTimelineHostController < ActionController::Base
  helper_method :logged_in?, :admin?, :current_user, :root_path
  def logged_in? = false
  def admin? = false
  def current_user = nil
  def root_path = "/"
end

class NavbarScrollTimelineRenderTest < ActiveSupport::TestCase
  setup { @prior = Studio.navbar_scroll_timeline }
  teardown { Studio.navbar_scroll_timeline = @prior }

  test "off by default: the header renders as before, on the --nav-p collapse" do
    Studio.navbar_scroll_timeline = false
    header = render_header

    assert_nil header["data-nav-timeline"]
    assert_equal "nav-collapse", header["data-studio-controller"]
  end

  test "the setting puts the opt-in on the header and keeps its controller" do
    Studio.navbar_scroll_timeline = true
    header = render_header

    assert header.key?("data-nav-timeline"), "the opt-in attribute"
    # The controller stays: it runs the timeline mode from 768px and the
    # --nav-p collapse below it.
    assert_equal "nav-collapse", header["data-studio-controller"]
  end

  test "a render's own local wins over the setting, both ways" do
    Studio.navbar_scroll_timeline = false
    assert render_header(scroll_timeline: true).key?("data-nav-timeline")

    Studio.navbar_scroll_timeline = true
    assert_nil render_header(scroll_timeline: false)["data-nav-timeline"]
  end

  test "a preview never carries it: the /navbar page drives --nav-p itself" do
    Studio.navbar_scroll_timeline = true
    header = render_header(preview: true)

    assert_nil header["data-nav-timeline"]
    assert_nil header["data-studio-controller"]
  end

  private

  def render_header(**locals)
    html = NavbarTimelineHostController.render(inline: %(<%= render "layouts/navbar", **locals %>), locals: { locals: locals })
    header = Nokogiri::HTML5(html).at_css("header")
    refute_nil header, "expected the navbar header"
    header
  end
end
