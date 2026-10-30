# frozen_string_literal: true

# [integration] Every navbar setting added since 0.113.0, left unset or set to
# its default, renders the bytes 0.113.0 rendered: the navbar, user nav, sidebar
# panel and link sidebar, signed out, signed in and admin, live and preview, with
# 0.113.0's own settings (link sidebar, scroll timeline, CTA, items, balance,
# logo, h1 or div) on and off. The bytes in
# test/fixtures/files/navbar_unset_baseline were captured from v0.113.0, loaded
# from its own Gemfile, by test/support/navbar_baseline_cases.rb, which also
# holds the cases and how to regenerate them.
#
# Deliberate changes since the capture, each regenerated and named in the
# CHANGELOG: the theme toggle's button gained type, aria-label and a bound
# aria-pressed (/tasks/engine-theme-toggle-labels).

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require_relative "../support/navbar_baseline_cases"

require "minitest/autorun"
require "active_support/test_case"

class NavbarUnsetBaselineTest < ActiveSupport::TestCase
  BASELINE = File.expand_path("../fixtures/files/navbar_unset_baseline", __dir__)

  # The settings added after 0.113.0, at their defaults.
  DEFAULTS = {
    navbar_header_bars: [], navbar_menu_trigger: nil, navbar_account_sidebar: nil,
    navbar_phone_name: false, navbar_name_in_rows: false, navbar_brand: nil, navbar_root_hook: false,
    navbar_z_tier: false
  }.freeze

  setup { @prior = DEFAULTS.keys.to_h { |key| [key, Studio.public_send(key)] } }
  teardown { @prior.each { |key, value| Studio.public_send(:"#{key}=", value) } }

  test "the baseline holds every case, and only those" do
    assert_equal NavbarBaselineCases::CASES.keys.sort, Dir.children(BASELINE).map { |f| File.basename(f, ".html") }.sort
  end

  NavbarBaselineCases::CASES.each_key do |name|
    test "#{name}: the new settings at their defaults render the 0.113.0 bytes" do
      DEFAULTS.each { |key, value| Studio.public_send(:"#{key}=", value) }

      assert_equal File.read(File.join(BASELINE, "#{name}.html")), NavbarBaselineCases.render(name)
    end
  end

  test "the new settings answering their defaults from callables render the same bytes" do
    Studio.navbar_header_bars = ->(_view) {}
    Studio.navbar_menu_trigger = ->(_view) {}
    Studio.navbar_account_sidebar = ->(_view) {}

    %w[navbar-in-live navbar-admin-live navbar-out-live].each do |name|
      assert_equal File.read(File.join(BASELINE, "#{name}.html")), NavbarBaselineCases.render(name), name
    end
  end
end
