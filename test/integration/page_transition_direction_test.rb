# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [integration] Studio.page_transition_direction against the REAL lib/studio.rb (the
# test_helper mirror does not validate), and the lab route the browser lane drives.
class PageTransitionDirectionTest < ActionDispatch::IntegrationTest
  teardown { Studio.page_transition_direction = nil }

  test "the writer takes the four directions, as a symbol or a string, and nil" do
    %i[left right top bottom].each do |direction|
      Studio.page_transition_direction = direction
      assert_equal direction, Studio.page_transition_direction
    end
    Studio.page_transition_direction = "top"
    assert_equal :top, Studio.page_transition_direction
    Studio.page_transition_direction = nil
    assert_nil Studio.page_transition_direction
  end

  test "the writer refuses a typo at boot" do
    error = assert_raises(ArgumentError) { Studio.page_transition_direction = :diagonal }
    assert_includes error.message, "left, right, top, bottom"
  end

  test "a set direction renders the metas and the module tag; none renders neither" do
    get "/lab/page_transitions"
    assert_response :success
    refute_includes response.body, "page-transition-direction"
    refute_includes response.body, 'import "studio/page_transitions"'
    refute_includes response.body, "vt-pinned-header"

    get "/lab/page_transitions?direction=right"
    assert_includes response.body, '<meta name="page-transition-direction" content="right">'
    assert_includes response.body, '<meta name="view-transition" content="same-origin">'
    assert_includes response.body, 'import "studio/page_transitions"'
    assert_equal 1, response.body.scan("vt-pinned-header").size
  end

  test "the module is pinned for a host, and not preloaded on every page" do
    refute_includes Studio::Engine.javascript_boot_graph, "studio/page_transitions"
    assert_includes Studio::Engine.javascript_module_logical_paths, "studio/page_transitions.js"
  end
end
