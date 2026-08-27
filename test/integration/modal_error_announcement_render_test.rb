# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] The error announcement must survive RENDERING.
#
# Its sibling, test/views/modal_error_lines_announce_test.rb, scans the ERB
# SOURCE. That is the right shape for a sweep across every partial, but it proves
# only what is written down — an attribute placed inside a branch that never
# executes, or dropped by a helper on the way out, scans clean and reaches the
# browser as nothing. This renders the design-system page through the same
# ActionView path a host uses and asserts on the HTML that actually comes out.
class ModalErrorAnnouncementRenderTest < ActiveSupport::TestCase
  def render_style_index
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.extend(Studio::Engine.helpers)
    view.render(template: "style/index")
  end

  def doc
    @doc ||= Nokogiri::HTML.fragment(render_style_index)
  end

  # The reusable error card is what a consumer reaches for when an operation
  # fails, and it is staged on this page — so its announcement is checkable
  # end-to-end rather than by inspection.
  def test_the_rendered_error_card_carries_a_live_region
    cards = doc.css('[role="alert"]')

    refute_empty cards,
                 "nothing on the rendered design-system page announces at all — the error card " \
                 "is staged here, so its role should have survived rendering"
  end

  # THE REAL PROPERTY, stated over the rendered tree rather than the source: no
  # red error paragraph reaches the browser silent.
  def test_no_rendered_error_paragraph_is_silent
    silent = doc.css("p").select do |p|
      klass = p["class"].to_s
      red = klass.match?(/\btext-red-\d+\b/)
      red && p["role"] != "alert" && !%w[polite assertive].include?(p["aria-live"])
    end

    assert_empty silent.map { |p| p.to_html[0, 120] },
                 "these error paragraphs render WITHOUT a live region, so a screen reader is told " \
                 "nothing when the operation fails"
  end

  # A render assertion is worthless if the page rendered nothing of interest.
  def test_the_page_actually_staged_some_modal_markup
    assert_operator doc.css("p").length, :>=, 20,
                    "the design-system page rendered almost nothing — this test is covering an " \
                    "empty document, not the modals it claims to check"
  end
end
