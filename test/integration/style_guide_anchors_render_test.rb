# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] The anchors must survive RENDERING.
#
# Its sibling, test/views/style_guide_modal_anchors_test.rb, scans the ERB source.
# That is the right shape for asserting the published set, but an id written
# inside a branch that never runs — or emitted by a helper that escapes it — scans
# clean and reaches the consumer as nothing. A consumer selecting on an anchor
# does so against the RENDERED document, so that is what this asserts.
class StyleGuideAnchorsRenderTest < ActiveSupport::TestCase
  ANCHORS = %w[
    modals-auth modals-profile modals-profile-leveling modals-web3
    modals-contest-entry modals-system-status modals-templates modals-rewards
  ].freeze

  def doc
    @doc ||= begin
      view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
      view.extend(Studio::Engine.helpers)
      Nokogiri::HTML.fragment(view.render(template: "style/index"))
    end
  end

  def test_every_anchor_is_addressable_in_the_rendered_document
    missing = ANCHORS.reject { |id| doc.at_css("##{id}") }

    assert_empty missing,
                 "these anchors are published in the source but absent from the RENDERED page: " \
                 "#{missing.inspect}. A consumer selecting on one gets nothing back."
  end

  # Each anchor must be UNIQUE. A duplicated id makes a consumer's selector
  # ambiguous and silently returns whichever came first — worse than missing,
  # because it looks like it worked.
  def test_no_anchor_is_duplicated
    dupes = ANCHORS.select { |id| doc.css("##{id}").length > 1 }

    assert_empty dupes, "these anchors render more than once: #{dupes.inspect}"
  end

  # The anchors are only useful if they sit inside the modals section a consumer
  # scopes to, and if each actually wraps content.
  def test_each_anchor_wraps_a_real_subsection
    empty = ANCHORS.select do |id|
      node = doc.at_css("##{id}")
      node.nil? || node.text.strip.length < 20
    end

    assert_empty empty,
                 "these anchored sections rendered (nearly) empty: #{empty.inspect} — the id is " \
                 "attached to the wrong element, or the subsection did not render"
  end
end
