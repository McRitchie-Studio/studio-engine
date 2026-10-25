# frozen_string_literal: true

# Renders the engine navbar through the dummy app and pins
# Studio.navbar_signed_out_cta: unset, the signed-out navbar is the pre-feature
# bytes; set, the primary button carries the CTA, sign-in stays reachable as a
# quiet link beside it (desktop) and in the phone row (below md), and nothing
# else in the header moves. Signed in, the setting changes nothing.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarSignedOutCtaRenderHostController < ActionController::Base
  helper_method :logged_in?, :current_user, :root_path

  class StubUser
    def display_name = "Plain User"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#0ea5e9"
    def avatar_initials = "PU"
  end

  class_attribute :signed_in, default: false

  def logged_in? = signed_in
  def current_user = (@current_user ||= StubUser.new if signed_in)
  def root_path = "/"
end

class NavbarSignedOutCtaRenderTest < ActiveSupport::TestCase
  # The signed-out button exactly as the navbar rendered it before the setting.
  PRE_FEATURE_BUTTON = %(          <a class="btn btn-primary" href="/login">Log in</a>\n)

  # What the setting adds, line for line, in place of PRE_FEATURE_BUTTON (top
  # row) and at the head of the phone row's right-hand group.
  CTA_TOP_ROW =
    %(          <a class="hidden md:inline text-sm font-semibold text-secondary hover:text-primary whitespace-nowrap transition" data-nav-sign-in="" href="/login">Log in</a>\n) +
    %(          <a class="btn btn-primary whitespace-nowrap" data-nav-signed-out-cta="" href="/build">Build App</a>\n)
  PHONE_ROW_OPEN = %(    <span class="ml-auto flex items-center gap-3">\n)
  CTA_PHONE_LINK =
    %(      <a class="text-xs font-semibold text-secondary hover:text-primary whitespace-nowrap transition" data-nav-sign-in="" href="/login">Log in</a>\n)

  setup do
    @prior_cta = Studio.navbar_signed_out_cta
    @prior_label = Studio.sign_in_label
    NavbarSignedOutCtaRenderHostController.signed_in = false
  end

  teardown do
    Studio.navbar_signed_out_cta = @prior_cta
    Studio.sign_in_label = @prior_label
  end

  test "unset renders the pre-feature signed-out button and nothing new" do
    assert_nil Studio.navbar_signed_out_cta
    html = render_navbar

    assert_includes html, PRE_FEATURE_BUTTON
    refute_includes html, "data-nav-sign-in"
    refute_includes html, "data-nav-signed-out-cta"
    assert_equal 1, Nokogiri::HTML(html).css("a[href='/login']").size
  end

  test "a callable answering nil renders the same bytes as unset" do
    default = render_navbar
    Studio.navbar_signed_out_cta = ->(_view) {}

    assert_equal default, render_navbar
  end

  test "a raising callable renders the same bytes as unset instead of a 500" do
    default = render_navbar
    Studio.navbar_signed_out_cta = ->(_view) { raise "no build route" }

    assert_equal default, render_navbar
  end

  test "set, the CTA and the sign-in links are the only bytes that change" do
    default = render_navbar
    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build" }
    html = render_navbar

    assert_includes html, CTA_TOP_ROW
    assert_includes html, PHONE_ROW_OPEN + CTA_PHONE_LINK
    restored = html.sub(CTA_TOP_ROW, PRE_FEATURE_BUTTON).sub(PHONE_ROW_OPEN + CTA_PHONE_LINK, PHONE_ROW_OPEN)
    assert_equal default, restored
  end

  test "set, the primary button carries the CTA and sign-in stays reachable on both widths" do
    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build" }
    doc = Nokogiri::HTML(render_navbar)

    button = doc.at_css("a.btn.btn-primary")
    assert_equal ["Build App", "/build"], [button.text, button["href"]]
    refute button.key?("aria-haspopup"), "a CTA without modal: navigates; it opens no dialog " \
                                         "(the navbar-out-cta-live golden pins the same bytes)"

    sign_in = doc.css("a[href='/login']")
    assert_equal ["Log in", "Log in"], sign_in.map(&:text)
    refute sign_in.any? { |link| link["class"].split.include?("btn") }, "sign-in is a quiet link, not a second button"

    desktop, phone = sign_in.map { |link| link["class"].split }
    assert_includes desktop, "hidden"
    assert_includes desktop, "md:inline"
    assert phone_row(doc).css("a[href='/login']").any?, "the phone row carries sign-in below md"
  end

  test "the sign-in links follow Studio.sign_in_label" do
    Studio.sign_in_label = "Sign in"
    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build" }

    assert_equal ["Sign in", "Sign in"], Nokogiri::HTML(render_navbar).css("a[href='/login']").map(&:text)
  end

  test "a callable receives the view" do
    Studio.navbar_signed_out_cta = ->(view) { { label: "Build App", path: "#{view.root_path}build" } }

    assert_equal "/build", Nokogiri::HTML(render_navbar).at_css("a.btn.btn-primary")["href"]
  end

  test "the CTA label is escaped" do
    Studio.navbar_signed_out_cta = { label: "<b>Build</b>".html_safe, path: "/build" }
    html = render_navbar

    refute_includes html, "<b>Build</b>"
    assert_includes html, "&lt;b&gt;Build&lt;/b&gt;"
  end

  test "signed in, the setting changes nothing" do
    NavbarSignedOutCtaRenderHostController.signed_in = true
    default = render_navbar
    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build" }
    html = render_navbar

    assert_equal default, html
    refute_includes html, "Build App"
  end

  test "the writer refuses a bad Hash at assignment and keeps the prior value" do
    assert_raises(Studio::NavbarSignedOutCta::InvalidConfig) { Studio.navbar_signed_out_cta = { label: "Build App" } }
    assert_raises(Studio::NavbarSignedOutCta::InvalidConfig) { Studio.navbar_signed_out_cta = "/build" }
    assert_nil Studio.navbar_signed_out_cta
  end

  test "setting the CTA leaves Studio.sign_in_label, and so the auth pages, alone" do
    Studio.navbar_signed_out_cta = { label: "Build App", path: "/build" }

    assert_equal "Log in", Studio.sign_in_label
  end

  private

  def render_navbar
    NavbarSignedOutCtaRenderHostController.render(inline: %(<%= render "layouts/navbar" %>))
  end

  def phone_row(doc)
    doc.css("header > div").find { |div| div["class"].to_s.split.include?("md:hidden") }
  end
end
