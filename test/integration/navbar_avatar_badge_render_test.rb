# frozen_string_literal: true

# Renders the signed-in engine navbar through the dummy app and pins
# Studio.navbar_avatar_badge: the badge partial renders beside the account
# control (never inside it, so the control stays one tab stop and the badge
# may carry its own button), right after it so engine.css can seat it over
# the avatar, and an app that sets nothing gets the user nav's pre-feature
# bytes.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class NavbarAvatarBadgeHostController < ActionController::Base
  prepend_view_path File.expand_path("../views/fixtures", __dir__)
  helper_method :logged_in?, :current_user, :root_path, :profile_path, :tokens

  class StubUser
    def display_name = "Plain User"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#0ea5e9"
    def avatar_initials = "PU"
  end

  def logged_in? = true
  def current_user = @current_user ||= StubUser.new
  def root_path = "/"
  def profile_path = "/profile"
  def tokens = 2
end

class NavbarAvatarBadgeRenderTest < ActiveSupport::TestCase
  setup { @prior_badge = Studio.navbar_avatar_badge }
  teardown { Studio.navbar_avatar_badge = @prior_badge }

  test "nil, the default, renders no badge seat" do
    Studio.navbar_avatar_badge = nil
    html = render_navbar

    refute_includes html, "data-nav-avatar-badge"
    refute_includes html, "data-slot-badge"
  end

  test "a nil-answering or raising callable renders the same bytes as the default" do
    Studio.navbar_avatar_badge = nil
    empty = render_navbar

    Studio.navbar_avatar_badge = ->(_view) {}
    assert_equal empty, render_navbar
    Studio.navbar_avatar_badge = ->(_view) { raise ArgumentError, "no tokens" }
    assert_equal empty, render_navbar
  end

  test "the badge renders in a seat right after the account control" do
    Studio.navbar_avatar_badge = "navbar_slot_fixtures/badge"
    doc = Nokogiri::HTML(render_navbar)

    account = doc.at_css("[data-nav-account]")
    seat = account.next_element

    refute_nil seat
    assert seat.key?("data-nav-avatar-badge"), "the seat follows the account control"
    assert_equal 1, seat.css("[data-slot-badge]").size
    assert_equal 1, doc.css("[data-slot-badge]").size, "one badge per navbar"
  end

  test "the account control stays one tab stop, and the badge keeps its own button" do
    Studio.navbar_avatar_badge = "navbar_slot_fixtures/badge"
    doc = Nokogiri::HTML(render_navbar)

    account = doc.at_css("[data-nav-account]")
    assert_includes %w[a button], account.name, "the control is itself the one tab stop"
    assert_empty account.css("a, button, [tabindex]"), "nothing focusable inside the account control"
    assert_empty account.css("[data-slot-badge]"), "the badge is not inside the control"
    assert_equal "button", doc.at_css("[data-slot-badge]").name
  end

  test "the seat adds no box to the flex row: it is out of flow, sized by engine.css" do
    Studio.navbar_avatar_badge = "navbar_slot_fixtures/badge"
    seat = Nokogiri::HTML(render_navbar).at_css("[data-nav-avatar-badge]")

    assert_nil seat["class"], "no utility classes: engine.css positions the seat"
    assert_equal "", seat["data-nav-avatar-badge"], "a bare hook, as data-nav-account is"
  end

  test "a hash spec's locals reach the partial, and a callable reads the view" do
    Studio.navbar_avatar_badge = ->(view) { { partial: "navbar_slot_fixtures/wallet", locals: { tone: "t#{view.tokens}" } } }
    doc = Nokogiri::HTML(render_navbar)

    assert_equal "t2", doc.at_css("[data-nav-avatar-badge] [data-slot-item=wallet]")["data-tone"]
  end

  test "signed out, the badge never renders" do
    Studio.navbar_avatar_badge = "navbar_slot_fixtures/badge"
    html = render_navbar(show_logged_in: false)

    refute_includes html, "data-slot-badge"
  end

  test "a bad static badge is refused when assigned, before any render" do
    assert_raises(Studio::NavbarSlots::InvalidConfig) { Studio.navbar_avatar_badge = ["navbar_slot_fixtures/badge"] }
    error = assert_raises(Studio::NavbarSlots::InvalidConfig) { Studio.navbar_avatar_badge = { path: "x" } }
    assert_match(/navbar_avatar_badge has unknown key :path/, error.message)
  end

  private

  def render_navbar(show_logged_in: true)
    controller = NavbarAvatarBadgeHostController.new
    controller.request = ActionDispatch::TestRequest.create("PATH_INFO" => "/")
    controller.response = ActionDispatch::TestResponse.new
    controller.render_to_string(inline: %(<%= render "layouts/navbar", show_logged_in: #{show_logged_in} %>))
  end
end
