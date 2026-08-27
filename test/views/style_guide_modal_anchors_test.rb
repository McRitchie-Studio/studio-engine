# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [unit] Every modal-guide subsection is addressable by a STABLE id.
#
# THE DEFECT THIS PINS. app/views/style/_modals.html.erb wrapped everything in
# <section id="modals"> but all eight subsections were bare
# `<section class="space-y-5">`. With no id, a consumer test can only grab one by
# HEADING TEXT — and the Web3 heading has been renamed twice in two releases
# ("Web3" -> "Web3 Contest" in engine 0.27.0, and back again), reddening the hub
# each time. A rename is a copy edit; it should never be able to break a consumer.
#
# THE IDS ARE NOT DERIVED FROM THE HEADINGS, deliberately. Slugifying the heading
# would reproduce the exact coupling this removes — the id would change with the
# words. They name the SUBJECT and are chosen once; renaming a heading must leave
# them untouched, which is what test_ids_do_not_track_heading_text asserts.
class StyleGuideModalAnchorsTest < ActiveSupport::TestCase
  GUIDE = File.expand_path("../../app/views/style/_modals.html.erb", __dir__)

  # The contract a consumer may rely on. Adding to this set is a feature; changing
  # or removing an entry BREAKS a consumer that anchors on it, so it needs a
  # deliberate edit here and a note in the release.
  ANCHORS = %w[
    modals-auth
    modals-profile
    modals-profile-leveling
    modals-web3
    modals-contest-entry
    modals-system-status
    modals-templates
    modals-rewards
  ].freeze

  def source = File.read(GUIDE)

  def test_every_published_anchor_is_present
    missing = ANCHORS.reject { |id| source.include?(%(id="#{id}")) }

    assert_empty missing,
                 "these style-guide anchors are gone: #{missing.inspect}. A consumer test " \
                 "anchoring on one is now broken — restore the id, or change it deliberately " \
                 "here and say so in the release notes."
  end

  # THE OTHER HALF, and the one that keeps this honest as the guide grows: a NEW
  # subsection added without an id is exactly the state this task removed, and it
  # would otherwise sail past the assertion above.
  def test_no_modal_subsection_is_left_unaddressable
    bare = source.scan(/<section class="space-y-5">/)

    assert_empty bare,
                 "#{bare.length} modal subsection(s) carry no id, so a consumer can only reach " \
                 "them by heading text — which is what renaming 'Web3' broke, twice. Give each " \
                 "one a stable id and add it to ANCHORS."
  end

  # A guard that counts nothing passes forever. If the section markup is restyled
  # away from `space-y-5`, both assertions above go quiet — this notices.
  def test_the_guard_reads_the_subsections_it_claims_to
    # [a-z0-9-] and not [a-z-]: modals-web3 carries a DIGIT, and the first version of
    # this pattern silently skipped it — reporting 7 of 8 and proving the value of
    # counting rather than assuming.
    anchored = source.scan(/<section id="modals-[a-z0-9-]+" class="space-y-5">/)

    assert_equal ANCHORS.length, anchored.length,
                 "found #{anchored.length} anchored subsection(s) but ANCHORS lists " \
                 "#{ANCHORS.length}. Either a subsection was added without being published, or " \
                 "the markup was restyled and this guard is now reading nothing."
  end

  # THE PROPERTY THE TASK EXISTS FOR: ids must not track heading text. Proven
  # structurally — no anchor may be a slug of the heading inside its own section.
  def test_ids_do_not_track_heading_text
    doc = Nokogiri::HTML.fragment(source)
    coupled = []

    ANCHORS.each do |id|
      section = doc.at_css("section##{id}")
      next if section.nil?

      heading = section.at_css("h3")&.text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      coupled << id if heading.present? && id == "modals-#{heading}"
    end

    assert_empty coupled,
                 "these ids are slugs of their own heading: #{coupled.inspect}. That is the " \
                 "coupling this task removed — a copy edit to the heading would silently " \
                 "invalidate the anchor a consumer depends on."
  end
end
