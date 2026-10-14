# frozen_string_literal: true

# [integration] Renders the engine navbar through the dummy app both ways.
#
# Unset (the default for every consumer): the brand is the logo image and the
# app_name text exactly as before, byte for byte. Set: the brand lockup's two
# theme files replace both, inside the same link and the same h1, and no byte
# outside the brand link changes.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarWordmarkRenderHostController < ActionController::Base
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

class NavbarWordmarkRenderTest < ActiveSupport::TestCase
  WORDMARK = { light: "/brand/navbar-light.svg", dark: "/brand/navbar-dark.svg" }.freeze

  # The brand exactly as the navbar rendered it before the option existed.
  PRE_FEATURE_LOGO = %(<img src="/logo.png" alt="Lab Studio" class="nav-logo rounded-full shadow-lg group-hover:scale-105 transition-transform duration-300">)
  PRE_FEATURE_TITLE = %(<h1 class="nav-title font-extrabold text-heading tracking-tight min-w-0">) +
                      %(<span class="truncate">Lab</span><span class="text-primary truncate">Studio</span></h1>)

  # Everything between the brand link's open and close tags.
  BRAND_LINK_INNER = %r{(<a class="nav-logo-link[^"]*" href="/">).*?(</a>)}m

  setup do
    @prior = [Studio.app_name, Studio.theme_logos, Studio.navbar_wordmark]
    Studio.app_name = "Lab Studio"
    Studio.theme_logos = [{ file: "logo.png", title: "Navbar Logo" }]
    Studio.navbar_wordmark = nil
  end

  teardown do
    Studio.app_name, Studio.theme_logos, prior_wordmark = @prior
    Studio.navbar_wordmark = prior_wordmark
  end

  test "unset: the brand is the pre-feature logo and title text" do
    [true, false].each do |signed_in|
      html = render_navbar(signed_in: signed_in)

      assert_equal 1, html.scan(PRE_FEATURE_LOGO).size, "signed_in: #{signed_in}"
      assert_equal 1, html.scan(PRE_FEATURE_TITLE).size, "signed_in: #{signed_in}"
      refute_includes html, "nav-wordmark"
    end
  end

  test "set: both theme files render with the app name as alt, inside the h1 in the root link" do
    Studio.navbar_wordmark = WORDMARK
    doc = Nokogiri::HTML(render_navbar)

    imgs = doc.css("a.nav-logo-link[href='/'] > h1.nav-wordmark-brand > img.nav-wordmark")
    assert_equal ["/brand/navbar-light.svg", "/brand/navbar-dark.svg"], imgs.map { |i| i["src"] }
    assert_equal ["Lab Studio"] * 2, imgs.map { |i| i["alt"] }
    assert_equal ["nav-wordmark nav-wordmark-light", "nav-wordmark nav-wordmark-dark"], imgs.map { |i| i["class"] }
  end

  test "set: the logo image and the title text are gone" do
    Studio.navbar_wordmark = WORDMARK
    html = render_navbar

    refute_includes html, "nav-logo rounded-full"
    refute_includes html, %(class="nav-title)
    assert_equal 1, html.scan("<h1").size
  end

  test "set: no byte outside the brand link changes" do
    [true, false].each do |signed_in|
      plain = render_navbar(signed_in: signed_in)
      Studio.navbar_wordmark = WORDMARK
      lockup = render_navbar(signed_in: signed_in)
      Studio.navbar_wordmark = nil

      refute_equal plain, lockup
      assert_equal plain.sub(BRAND_LINK_INNER, '\1\2'), lockup.sub(BRAND_LINK_INNER, '\1\2'), "signed_in: #{signed_in}"
    end
  end

  test "set: brand_heading false draws the lockup in a div and keeps the page h1-free" do
    Studio.navbar_wordmark = WORDMARK
    doc = Nokogiri::HTML(render_navbar("brand_heading: false"))

    assert_nil doc.at_css("h1")
    assert_equal 2, doc.css("a.nav-logo-link > div.nav-wordmark-brand > img.nav-wordmark").size
  end

  test "set: the preview render (the /navbar review page) draws the lockup too" do
    Studio.navbar_wordmark = WORDMARK
    doc = Nokogiri::HTML(render_navbar("preview: true"))

    assert_nil doc.at_css("header[data-studio-controller]")
    assert_equal 2, doc.css("header.nav-shell a.nav-logo-link img.nav-wordmark").size
  end

  test "set: paths and the app name are escaped, never raw" do
    Studio.app_name = %(Lab "Studio")
    Studio.navbar_wordmark = { light: %(/a.svg" onerror="x), dark: "/d.svg" }
    html = render_navbar

    refute_includes html, %(onerror="x")
    assert_includes html, %(alt="Lab &quot;Studio&quot;")
  end

  test "the setter validates: a bad config raises instead of rendering" do
    assert_raises(Studio::NavbarWordmark::InvalidConfig) { Studio.navbar_wordmark = "/brand/one.svg" }
    assert_nil Studio.navbar_wordmark
  end

  private

  def render_navbar(locals = nil, signed_in: false)
    NavbarWordmarkRenderHostController.signed_in = signed_in
    call = ["render \"layouts/navbar\"", locals].compact.join(", ")
    NavbarWordmarkRenderHostController.render(inline: "<%= #{call} %>")
  end
end
