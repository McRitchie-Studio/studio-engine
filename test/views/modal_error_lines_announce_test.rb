# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] A modal error line must ANNOUNCE.
#
# THE DEFECT THIS PINS. Modal error text carried no `role="alert"` and no
# `aria-live`, so a failure announced NOTHING to assistive tech: the user presses
# a button, the operation fails, red text appears, and as far as a screen reader
# is concerned the page did not change. It was engine-wide rather than one card's
# slip — every inline error line in app/views/studio/modals matched.
#
# WHY `role="alert"` AND NOT `aria-live="polite"`. These lines are the direct
# result of an action the user just took, and they need to interrupt rather than
# queue behind whatever else is speaking. `role="alert"` carries an implicit
# assertive live region, which is the standard pairing.
#
# WHY IT WORKS HERE. Every one of these lines is filled by Alpine `x-text` and is
# EMPTY when the modal opens, so the announcement fires on the content change —
# the moment the error arrives. The modal host renders content through
# `<template x-if>` (studio/modals/_host.html.erb), so the element enters the DOM
# with the modal and is live by the time the failure lands.
class ModalErrorLinesAnnounceTest < ActiveSupport::TestCase
  # TWO DIRECTORIES, and the second was found the hard way. The first version of
  # this guard scanned only studio/modals and reported clean while THREE error
  # lines under style/modals rendered silent — its render-level sibling caught
  # them. A source scan is only ever as wide as its glob.
  MODAL_DIRS = [
    File.expand_path("../../app/views/studio/modals", __dir__),
    File.expand_path("../../app/views/style/modals", __dir__)
  ].freeze
  MODAL_DIR = MODAL_DIRS.first

  # An error line, as it actually appears in this tree: a <p> carrying a
  # `text-red-*` utility. Scoped to <p> on purpose — the same utility appears on
  # an <svg> stroke in blocks/_card_header.html.erb, which is an ICON and has
  # nothing to announce.
  ERROR_PARAGRAPH = /<p\b[^>]*\bclass\s*=\s*"[^"]*\btext-red-\d+\b[^"]*"[^>]*>/m
  ANNOUNCES = /\brole\s*=\s*"alert"|\baria-live\s*=\s*"(?:polite|assertive)"/

  # ERB TAGS ARE NEUTRALISED FIRST, and that is not tidiness. An attribute like
  # `x-show="<%= error_model %>"` contains a `>` inside `%>`, which terminates the
  # `[^>]*` in any tag pattern — so shared/_age_attestation.html.erb was INVISIBLE
  # to the first version of this scan. The guard reported a smaller set than exists
  # and would have missed a silent line in exactly the files that interpolate.
  def strip_erb(source)
    source.gsub(/<%#.*?%>/m, "").gsub(/<%.*?%>/m, "ERB")
  end

  def error_paragraphs(source)
    strip_erb(source).scan(ERROR_PARAGRAPH)
  end

  def modal_views
    MODAL_DIRS.flat_map { |dir| Dir.glob(File.join(dir, "**", "*.erb")) }.sort
  end

  def relative(path)
    MODAL_DIRS.each { |dir| return path.sub("#{File.dirname(dir)}/", "") if path.start_with?(dir) }
    path
  end

  def test_every_modal_error_line_announces_to_a_screen_reader
    silent = {}

    modal_views.each do |path|
      offenders = error_paragraphs(File.read(path)).reject { |tag| tag.match?(ANNOUNCES) }
      silent[relative(path)] = offenders if offenders.any?
    end

    assert_empty silent,
                 "these modal error lines announce NOTHING to a screen reader: " \
                 "#{silent.inspect}. The user acts, the operation fails, and assistive tech " \
                 "reports no change at all. Add role=\"alert\" to the element that carries the " \
                 "error text (see any sibling in app/views/studio/modals)."
  end

  # THE GUARD MUST ACTUALLY LOOK AT SOMETHING. A glob that matches nothing, or a
  # pattern that stops matching after a restyle, makes the assertion above pass
  # forever over an empty list — which is precisely the "green but blind" failure
  # this file exists to prevent, one level up.
  #
  # THE FLOOR MOVED 10 -> 8, AND ONLY FOR THIS REASON. The wallet_connect and
  # web3_step_up partials contributed one error line each and left this engine
  # for solana-studio with the two-template split — the engine ships no wallet UI
  # any more. Re-derived on this tree with the pattern above, not adjusted to fit
  # a red run. Lowering it for any OTHER reason is the failure this test names:
  # if the count drops again, find the line that stopped matching.
  #
  # Both moved partials still carry role="alert" in the gem, but solana-studio
  # ships NO equivalent guard, so those two lines are now unpinned in their new
  # home. Porting this test to the gem is filed as follow-up work.
  def test_the_guard_reads_the_error_lines_it_claims_to
    views = modal_views
    assert_operator views.length, :>=, 10,
                    "only #{views.length} modal view(s) under #{MODAL_DIR} — this guard covers nothing"

    found = views.sum { |path| error_paragraphs(File.read(path)).length }
    assert_operator found, :>=, 8,
                    "the error-line pattern matched only #{found} paragraph(s); it matched 8 when " \
                    "last re-derived. A restyle away from text-red-* would leave this guard passing " \
                    "over nothing — re-point the pattern rather than deleting the test."
  end

  # The reusable error CARD is a different mechanism and is pinned separately: its
  # message is server-rendered static text, so no live region would ever notice it
  # "change". The card itself enters the DOM at the moment of failure, so the role
  # belongs on the card root — the paragraph rule above would never catch this.
  def test_the_reusable_error_card_announces_as_a_whole
    source = File.read(File.join(MODAL_DIR, "blocks", "_error_card.html.erb"))
    root = strip_erb(source)[/<div\b[^>]*class\s*=\s*"[^"]*\btext-center\b[^"]*"[^>]*>/m]

    refute_nil root, "the error card's root element moved — re-point this assertion"
    assert_match ANNOUNCES, root,
                 "the reusable error card does not announce; every consumer's failure card is silent"
  end
end
