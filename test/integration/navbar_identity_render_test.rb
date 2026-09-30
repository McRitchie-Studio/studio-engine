# frozen_string_literal: true

# Renders the engine navbar through the dummy app and pins
# Studio.navbar_user_name and Studio.sign_in_label: the configured name lands in
# the signed-in user nav, the configured label on both signed-out buttons, the
# name is escaped, a failing name never 500s the layout, and an app that
# configures neither renders the pre-feature bytes.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarIdentityRenderHostController < ActionController::Base
  helper_method :logged_in?, :current_user, :root_path

  class StubUser
    attr_accessor :player_name

    def display_name = "Plain User"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#0ea5e9"
    def avatar_initials = "PU"
  end

  class_attribute :signed_in, default: true
  class_attribute :player, default: "Guest_4821"

  def logged_in? = signed_in

  def current_user
    @current_user ||= StubUser.new.tap { |user| user.player_name = player }
  end

  def root_path = "/"
end

class NavbarIdentityRenderTest < ActiveSupport::TestCase
  # The markup exactly as the navbar rendered it before these settings existed.
  PRE_FEATURE_NAME = %(leading-none transition group-hover:text-primary" data-nav-name>Plain User</span></span>)
  PRE_FEATURE_NAVBAR_BUTTON = %(<a class="btn btn-primary" href="/login">Log in</a>)
  PRE_FEATURE_USER_NAV_BUTTON =
    %(<a class="text-heading hover:text-primary text-sm font-semibold transition" href="/login">Log in</a>)

  setup do
    @prior_name = Studio.navbar_user_name
    @prior_label = Studio.sign_in_label
    NavbarIdentityRenderHostController.signed_in = true
    NavbarIdentityRenderHostController.player = "Guest_4821"
  end

  teardown do
    Studio.navbar_user_name = @prior_name
    Studio.sign_in_label = @prior_label
  end

  test "neither setting configured renders the pre-feature name and buttons" do
    assert_nil Studio.navbar_user_name
    assert_equal "Log in", Studio.sign_in_label

    assert_includes render_navbar, PRE_FEATURE_NAME
    assert_includes render_navbar(signed_in: false), PRE_FEATURE_NAVBAR_BUTTON
    assert_includes render_user_nav(signed_in: false), PRE_FEATURE_USER_NAV_BUTTON
  end

  test "configuring changes those words and no other byte" do
    default_in = render_navbar
    default_out = render_navbar(signed_in: false)
    default_nav_out = render_user_nav(signed_in: false)

    Studio.navbar_user_name = :player_name
    Studio.sign_in_label = "Sign in"

    assert_equal default_in, render_navbar.sub(">Guest_4821</span>", ">Plain User</span>")
    assert_equal default_out, render_navbar(signed_in: false).sub(">Sign in</a>", ">Log in</a>")
    assert_equal default_nav_out, render_user_nav(signed_in: false).sub(">Sign in</a>", ">Log in</a>")
  end

  test "a symbol prints that method's answer as the signed-in name" do
    Studio.navbar_user_name = :player_name
    doc = Nokogiri::HTML(render_navbar)

    assert_equal "Guest_4821", doc.at_css("[data-nav-name]").text
    refute_includes doc.to_html, "Plain User"
  end

  test "a lambda receives the user and the view" do
    Studio.navbar_user_name = ->(user, view) { "#{user.player_name} @ #{view.root_path}" }

    assert_equal "Guest_4821 @ /", Nokogiri::HTML(render_navbar).at_css("[data-nav-name]").text
  end

  test "the configured label is on both signed-out buttons" do
    Studio.sign_in_label = "Sign in"

    navbar = Nokogiri::HTML(render_navbar(signed_in: false))
    user_nav = Nokogiri::HTML(render_user_nav(signed_in: false))

    assert_equal ["Sign in"], navbar.css("a[href='/login']").map(&:text)
    assert_equal ["Sign in"], user_nav.css("a[href='/login']").map(&:text)
    refute_includes navbar.to_html + user_nav.to_html, "Log in"
  end

  test "a name is escaped, even when the host hands back html_safe markup" do
    Studio.navbar_user_name = ->(_user, _view) { "<b>x</b>".html_safe }
    html = render_navbar

    refute_includes html, "<b>x</b>"
    assert_includes html, "data-nav-name>&lt;b&gt;x&lt;/b&gt;</span>"
  end

  test "a raising name falls back to display_name instead of a 500" do
    Studio.navbar_user_name = ->(_user, _view) { raise "no player row" }

    assert_equal "Plain User", Nokogiri::HTML(render_navbar).at_css("[data-nav-name]").text
  end

  test "a blank name falls back to display_name" do
    NavbarIdentityRenderHostController.player = nil
    Studio.navbar_user_name = :player_name

    assert_equal "Plain User", Nokogiri::HTML(render_navbar).at_css("[data-nav-name]").text
  end

  test "bad settings are refused when assigned, before any render" do
    assert_raises(Studio::NavbarIdentity::InvalidConfig) { Studio.navbar_user_name = 42 }
    assert_raises(Studio::NavbarIdentity::InvalidConfig) { Studio.sign_in_label = "" }
  end

  private

  def render_navbar(signed_in: true)
    NavbarIdentityRenderHostController.signed_in = signed_in
    NavbarIdentityRenderHostController.render(inline: %(<%= render "layouts/navbar" %>))
  end

  # The user nav's own signed-out branch: reached when a host passes
  # show_logged_in: true to a signed-out page, so render the partial directly.
  def render_user_nav(signed_in:)
    NavbarIdentityRenderHostController.signed_in = signed_in
    NavbarIdentityRenderHostController.render(inline: %(<%= render "components/user_nav" %>))
  end
end
