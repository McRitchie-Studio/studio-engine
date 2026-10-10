# frozen_string_literal: true

# Renders the engine navbar through the dummy app and pins the brand_heading
# local: without it the brand is the h1 it has always been, byte for byte; with
# false the brand is a div carrying the same classes and words, and no other
# byte of the navbar changes.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarBrandHeadingRenderHostController < ActionController::Base
  helper_method :logged_in?, :root_path, :current_user

  class_attribute :signed_in, default: false

  def logged_in? = signed_in
  def root_path = "/"

  def current_user
    @current_user ||= Class.new do
      def display_name = "Plain User"
      def avatar = @avatar ||= Class.new { def attached? = false }.new
      def avatar_color = "#0ea5e9"
      def avatar_initials = "PU"
    end.new
  end
end

class NavbarBrandHeadingRenderTest < ActiveSupport::TestCase
  BRAND_CLASSES = "nav-title font-extrabold text-heading tracking-tight min-w-0"
  WORDS = %(<span class="truncate">Lab</span><span class="text-primary truncate">Studio</span>)

  # The brand exactly as the navbar rendered it before the local existed.
  PRE_FEATURE_BRAND = %(<h1 class="#{BRAND_CLASSES}">#{WORDS}</h1>)
  DIV_BRAND = %(<div class="#{BRAND_CLASSES}">#{WORDS}</div>)

  setup do
    @prior_app_name = Studio.app_name
    Studio.app_name = "Lab Studio"
  end

  teardown { Studio.app_name = @prior_app_name }

  test "without the local the brand is the pre-feature h1" do
    [true, false].each do |signed_in|
      html = render_navbar(signed_in: signed_in)

      assert_equal 1, html.scan(PRE_FEATURE_BRAND).size, "signed_in: #{signed_in}"
      assert_equal 1, html.scan("<h1").size
      refute_includes html, DIV_BRAND
    end
  end

  test "true is the default: the same bytes as passing nothing" do
    [true, false].each do |signed_in|
      assert_equal render_navbar(signed_in: signed_in), render_navbar("brand_heading: true", signed_in: signed_in)
    end
  end

  test "false draws the brand as a div and changes no other byte" do
    [true, false].each do |signed_in|
      default = render_navbar(signed_in: signed_in)
      html = render_navbar("brand_heading: false", signed_in: signed_in)

      assert_equal 1, html.scan(DIV_BRAND).size, "signed_in: #{signed_in}"
      refute_includes html, "<h1"
      assert_equal default, html.sub(DIV_BRAND, PRE_FEATURE_BRAND)
    end
  end

  test "the div brand keeps the logo link, the classes and the words" do
    brand = Nokogiri::HTML(render_navbar("brand_heading: false")).at_css("a.nav-logo-link > div.nav-title")

    assert_equal BRAND_CLASSES, brand["class"]
    assert_equal %w[Lab Studio], brand.css("span").map(&:text)
  end

  private

  def render_navbar(locals = nil, signed_in: false)
    NavbarBrandHeadingRenderHostController.signed_in = signed_in
    call = ["render \"layouts/navbar\"", locals].compact.join(", ")
    NavbarBrandHeadingRenderHostController.render(inline: "<%= #{call} %>")
  end
end
