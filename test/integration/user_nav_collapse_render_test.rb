# frozen_string_literal: true

# Renders the engine navbar through the real dummy Rails app and pins the
# off-chain collapse: a user with no wallet, no level, and no logout link
# gets a single-row nav in a shrink-to-fit column, while a balance-bearing
# call keeps the fixed-width column and a level/wallet/logout row keeps the
# second row (the turf-monster shape is untouched).

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

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
    assert_includes html, ".user-nav-fit { max-width: 14rem; }"
    assert_match(/min-width: 400px.*\.user-nav-fit \{ max-width: 15rem; \}/, html)
    assert_match(/min-width: 768px.*\.user-nav-fit \{ max-width: 20rem; \}/, html)
  end

  test "a balance keeps the fixed-width column" do
    html = OffchainNavHostController.render(
      inline: %(<%= render "layouts/navbar", balance_html: "<span>$5</span>" %>)
    )

    assert_match(/class="user-nav-col /, html)
    refute_match(/class="user-nav-fit /, html)
  end

  test "show_logout_link keeps the second row through the navbar" do
    html = OffchainNavHostController.render(
      inline: %(<%= render "layouts/navbar", show_logout_link: true %>)
    )

    assert_includes html, "seedsNavbar"
  end
end
