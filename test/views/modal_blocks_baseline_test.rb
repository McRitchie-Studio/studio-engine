# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require_relative "modal_blocks_baseline_cases"

# [unit] Every local the modal blocks gained after 0.113.0 is opt-in: unset, each
# block renders BYTE FOR BYTE what 0.113.0 rendered.
#
# The blocks are blocks/_error_card, blocks/_success_card, blocks/_birthday,
# blocks/_change_username and studio/profiles/_newsletter_modals
# (engine-modal-blocks-carry-consumer). Every consumer renders them today with
# the locals 0.113.0 knew, so a stray newline or a reordered attribute would
# change every consumer's markup on a bump that promised to change nothing.
#
# THE GOLDENS ARE 0.113.0's OWN OUTPUT, not this tree's: they were rendered by the
# released gem, resolved from a Gemfile of its own, over the cases in
# modal_blocks_baseline_cases.rb (whose header says how). Regenerating them from
# this tree would turn the test into a tautology.
#
# A CASE ADDED HERE needs its golden from 0.113.0 too; a case with no golden
# fails rather than skips.
class ModalBlocksBaselineTest < ActiveSupport::TestCase
  GOLDENS = File.expand_path("../fixtures/files/modal_blocks_0.113.0", __dir__)

  def view
    v = ActionView::Base.with_empty_template_cache.with_view_paths([File.expand_path("../../app/views", __dir__)])
    v.extend(Studio::Engine.helpers)
    v.define_singleton_method(:profile_newsletter_path) { "/profile/newsletter" }
    v.define_singleton_method(:protect_against_forgery?) { false }
    v
  end

  ModalBlocksBaselineCases::CASES.each do |name, (partial, locals, block)|
    define_method(:"test_#{name}_renders_as_0_113_0_did") do
      golden = File.join(GOLDENS, "#{name}.html")
      assert File.exist?(golden), "#{name} has no 0.113.0 golden; render it from the released gem"

      expected = File.binread(golden).force_encoding(Encoding::UTF_8)
      actual = ModalBlocksBaselineCases.render(view, partial, locals, block).to_str

      assert_equal expected, actual, "#{partial} with only 0.113.0's locals no longer renders as 0.113.0 did"
    end
  end

  def test_every_golden_has_a_case
    names = Dir[File.join(GOLDENS, "*.html")].map { |f| File.basename(f, ".html") }.sort
    assert_equal ModalBlocksBaselineCases::CASES.keys.sort, names,
                 "a golden with no case is a check nobody runs"
  end

  def test_the_goldens_can_fail
    # NON-VACUITY: the comparison sees a one-byte change.
    partial, locals, = ModalBlocksBaselineCases::CASES.fetch("error_min")
    refute_equal File.binread(File.join(GOLDENS, "error_min.html")).force_encoding(Encoding::UTF_8),
                 ModalBlocksBaselineCases.render(view, partial, locals.merge(title: "Still processing."), nil).to_str
  end
end
