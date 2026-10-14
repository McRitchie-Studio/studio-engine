# frozen_string_literal: true

# Renders the engine navbar through the real dummy Rails app and pins the
# off-chain collapse: a user with no wallet and no level gets a single-row
# nav in a shrink-to-fit column, while a balance-bearing call keeps the
# fixed-width column and a level or wallet row keeps the second row (the turf-monster shape is untouched).

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "nokogiri"

class OffchainNavHostController < ActionController::Base
  helper_method :logged_in?, :current_user, :root_path

  class StubUser
    def display_name = "Plain User"
    def avatar = @avatar ||= Class.new { def attached? = false }.new
    def avatar_color = "#0ea5e9"
    def avatar_initials = "PU"
  end

  def logged_in? = true

  def current_user = @current_user ||= StubUser.new

  def root_path = "/"
end

class UserNavCollapseRenderTest < ActiveSupport::TestCase
  test "offchain navbar renders one row in a shrink-to-fit column" do
    html = OffchainNavHostController.render(inline: %(<%= render "layouts/navbar" %>))

    refute_includes html, "seedsNavbar", "empty second row must collapse"
    assert_match(/class="user-nav-fit /, html)
    refute_match(/class="user-nav-col /, html, "no balance → no fixed-width column")

    # The fit column is flex-shrink-0: without media-stepped max-width clamps
    # mirroring .user-nav-col, a long nowrap username sizes it past a narrow
    # viewport (Carl's review catch on PR #70).
    #
    # The two PHONE bands cap by min(<rem>, 46vw) rather than the bare rem they
    # carried until header-fits-a-phone. A constant 14rem is 57% of a 390px
    # screen on a column that cannot shrink, which left the app's own name too
    # little room to sit in — measured, it painted on top of the column beside
    # it. The rem is still the ceiling; the vw only binds on a phone.
    assert_includes html, ".user-nav-fit { max-width: min(14rem, 46vw); }"
    assert_match(/min-width: 400px.*\.user-nav-fit \{ max-width: min\(15rem, 46vw\); \}/, html)
    # 768px and up is UNCHANGED and must stay a bare rem: min() there would let
    # a desktop scrollbar's width into a header measurement for no benefit.
    assert_match(/min-width: 768px.*\.user-nav-fit \{ max-width: 20rem; \}/, html)
  end

  # With no second row the icon column is as tall as the avatar link beside it,
  # so it must centre its one row: top-aligned, the gear and theme toggle sat
  # above the name.
  test "the one-row icon column centres the icons on the name's row" do
    html = OffchainNavHostController.render(inline: %(<%= render "layouts/navbar" %>))

    assert_includes html, %(<div class="flex-1 min-w-0 flex flex-col justify-center" data-nav-tools data-nav-rows="1">)
  end

  test "a balance keeps the fixed-width column" do
    html = OffchainNavHostController.render(
      inline: %(<%= render "layouts/navbar", balance_html: "<span>$5</span>" %>)
    )

    assert_match(/class="user-nav-col /, html)
    refute_match(/class="user-nav-fit /, html)
  end

  # show_logout_link is retired: Log out lives in the link sidebar, and a stale
  # caller gets the one-row nav rather than a second row held open for it.
  test "a retired show_logout_link adds no Log out and no second row" do
    html = OffchainNavHostController.render(
      inline: %(<%= render "layouts/navbar", show_logout_link: true %>)
    )

    # The link sidebar the navbar mounts carries its own Log out; the user nav
    # must not.
    user_nav = Nokogiri::HTML.fragment(html).at_css("[data-nav-tools]").parent

    refute_includes user_nav.to_html, "Log out"
    refute_includes html, "seedsNavbar"
    assert_equal "1", user_nav.at_css("[data-nav-tools]")["data-nav-rows"]
  end
end
