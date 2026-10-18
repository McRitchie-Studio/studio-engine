# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] THE STICKY TABLE HEADER READS THE PINNED STACK, AND ONLY THE PAGE
# THAT ASKS FOR IT GETS IT.
#
# The clone used to sit at --nav-h, a root snapshot of the header's HEIGHT re-read
# only on a scroll or a resize: on a scroll-timeline header a page loaded at a
# restored scroll position kept it at the expanded height (Turf Monster /contests,
# 96px under a 50px bar). The behaviour is a browser's, and e2e/sticky_table_header
# grades it there; this tier pins the two seams a browser cannot see cheaply:
#
#   · the real dummy host serves the sticky table assets to /lab/sticky_table, by
#     the head's `sticky_table_headers:` local, and to no other lab page (the
#     process-wide Studio.sticky_table_headers slot is never written);
#   · the shipped script places off the stack and listens for its republish, and no
#     engine view pins a `top:` to the header's height first.
class StickyTableHeaderStackTest < ActionDispatch::IntegrationTest
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "app/assets/javascripts/studio/sticky_table_header.js")

  def test_integration_the_lab_page_gets_the_assets_by_local_and_its_neighbour_does_not
    refute Studio.sticky_table_headers, "the dummy host leaves the config off"

    get "/lab/sticky_table?timeline=1"
    assert_response :success
    assert_includes response.body, "/e2e/js/studio/sticky_table_header.js"
    assert_includes response.body, "/e2e/css/studio/sticky_table_header.css"
    assert_includes response.body, "data-nav-timeline", "?timeline=1 reaches the navbar"

    get "/lab/bar_stack"
    assert_response :success
    refute_includes response.body, "studio/sticky_table_header", "the local did not leak into the next request"
    refute Studio.sticky_table_headers, "the lab never writes the process-wide slot"
  end

  def test_integration_the_clone_places_off_the_stack_and_hears_it_republish
    source = File.read(SCRIPT)
    code = source.lines.reject { |line| line.strip.start_with?("//") }.join

    refute_match(/--nav-h/, code, "the clone must not place off --nav-h, the header's height")
    assert_includes code, "window.studioPinnedStack?.read?.()"
    assert_includes code, '"--pin-stack-bottom"'
    assert_includes code, '"studio:pinned-stack-refresh"'
    assert_includes code, '"studio:pinned-stack-published"'
  end

  # A pinned `top:` that reads --nav-h FIRST is the same class of bug: a height
  # where an edge belongs. A fallback after the stack's own value is fine.
  def test_integration_no_engine_view_pins_top_to_the_header_height_first
    offenders = Dir.glob(File.join(ROOT, "app/{views,assets}/**/*.{erb,css,js}")).flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{path.delete_prefix("#{ROOT}/")}:#{index + 1}" if line.match?(/(?<![-\w])top:\s*var\(--nav-h\b/)
      end
    end

    assert_empty offenders, "position off --pin-stack-bottom or --nav-bottom, never --nav-h first"
  end
end
