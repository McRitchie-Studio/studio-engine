# frozen_string_literal: true

require_relative "../../test_helper"

# [unit] A SOURCE SCAN, and it says so in the name — this is the cheap net for
# "no straggler anywhere under lib/", not a behavioural test of any one guard.
# The behavioural pins live in s3_namespace_only_rails_test.rb and
# mail_transport_namespace_only_rails_test.rb; this file exists for the third
# site, which no behavioural test can reach.
#
# WHY A SCAN IS THE HONEST INSTRUMENT HERE. The last straggler is
# `lib/studio.rb:859`, inside `Studio.routes(router)`. Loading lib/studio.rb at
# all requires studio/engine, which requires a full Rails application — and in a
# real application `Rails.env` EXISTS, so the very condition under test cannot be
# constructed in the only environment where the file loads. There is no call
# shape that reaches it with a namespace-only Rails. A scan pins it; nothing else
# does, and claiming otherwise would be the second false completeness claim this
# task exists to correct.
#
# WHAT IT ENFORCES, precisely: a line that both mentions `defined?(Rails)` AND
# invokes a method on the constant must also ask `Rails.respond_to?`. It does not
# fire on `defined?(Rails)` used as a bare boolean, because that shape never
# raises. A guard split across two lines would evade it — that is the known limit
# of a line-wise net, and the reason it is a backstop rather than the proof.
class RailsGuardSweepTest < Minitest::Test
  GEM_ROOT = File.expand_path("../../..", __dir__)

  # The three files that carried the defect, pinned BY NAME. A glob that silently
  # returns [] — a moved directory, a renamed lib — would make every assertion
  # below vacuously green, which is the exact failure mode this whole task is
  # about. Naming the members turns that into a red test.
  FILES_THAT_MUST_BE_SCANNED = %w[
    lib/studio.rb
    lib/studio/s3.rb
    lib/studio/mail_transport.rb
  ].freeze

  # A deliberately slack floor on the sweep — lib/ carries about 4,000 lines
  # across 30 files, so this trips only when the scan has stopped reading the
  # tree, never on ordinary growth or deletion.
  MINIMUM_LINES_SWEPT = 1_000

  # The shape that was fixed, kept as a constant so the guards below all feed the
  # predicate the SAME sample the scan was written for.
  ORIGINAL_STRAGGLER = 'rails_env: defined?(Rails) ? Rails.env : "development",'

  def scanned_files
    Dir.glob(File.join(GEM_ROOT, "lib", "**", "*.rb")).sort
  end

  def relative(path)
    path.delete_prefix("#{GEM_ROOT}/")
  end

  # THE PREDICATE, DEFINED ONCE — and the reason this file was rewritten.
  #
  # The scan and every non-vacuity guard below call THIS method. They used to
  # disagree: the rule lived inline in the scan, and the guard re-stated it as
  # string operations on a sample. That guard therefore exercised a COPY. Typing
  # a single typo into the scan's own regex — blinding the net so it could never
  # flag anything, no matter what lib/ contained — left the whole file GREEN,
  # because the floor was being measured against a duplicate implementation. A
  # control that cannot fail when the instrument breaks is not a control. One
  # definition and two callers means there is no second copy left to drift.
  def offending_line?(line)
    # COMMENTS ARE EXEMPT, and deliberately so. A comment cannot raise, and the
    # files that carry this guard EXPLAIN the bad shape in prose right above the
    # good one — lib/studio/s3.rb:130 quotes `defined?(Rails)` while describing
    # why it is wrong. Scanning prose would make the correct documentation of
    # this very bug the thing that reddens the suite.
    return false if line.lstrip.start_with?("#")
    return false unless line.include?("defined?(Rails)")
    return false if line.include?("Rails.respond_to?")

    # Only a line that actually CALLS something on the constant can raise.
    # `Rails.respond_to?` is excluded above; a bare boolean use is fine.
    line.match?(/\bRails\.[a-z_][A-Za-z0-9_]*/)
  end

  # THE PRECONDITION for a scan: prove it actually read the tree it claims to
  # cover, before trusting a clean result from it.
  def test_the_scan_really_reaches_the_files_that_carried_the_defect
    found = scanned_files.map { |path| relative(path) }

    refute_empty found, "the lib/**/*.rb glob returned nothing — the scan below is inert"

    FILES_THAT_MUST_BE_SCANNED.each do |expected|
      assert_includes found, expected,
                      "#{expected} must be inside the scanned set; if it moved, this " \
                      "test stops guarding the site it was written for"
    end
  end

  # The net itself. Offenders are reported as file:line with the source line, so a
  # failure names the straggler instead of only counting it.
  def test_no_rails_method_call_is_guarded_by_defined_alone
    offenders = []
    swept = []
    lines_swept = 0

    scanned_files.each do |path|
      swept << relative(path)
      File.readlines(path).each_with_index do |line, index|
        lines_swept += 1
        next unless offending_line?(line)

        offenders << "#{relative(path)}:#{index + 1}: #{line.strip}"
      end
    end

    # EXIT-BLINDNESS FLOOR, asserted inside the test that trusts the result rather
    # than only in its neighbour above. A source scan whose loop never runs reports
    # zero offenders and passes having proved nothing, so `assert_empty` is worth
    # reading only after these two assertions show the loop swept a real tree.
    FILES_THAT_MUST_BE_SCANNED.each do |expected|
      assert_includes swept, expected,
                      "#{expected} was never swept by THIS test, so the clean result " \
                      "below says nothing about it"
    end

    assert_operator lines_swept, :>, MINIMUM_LINES_SWEPT,
                    "only #{lines_swept} lines were read from #{swept.size} files — the " \
                    "scan has stopped reading the tree it claims to cover, and an empty " \
                    "offender list is vacuous"

    assert_empty offenders,
                 "these lines guard a Rails method call on `defined?(Rails)` alone. " \
                 "rails-html-sanitizer (via action_view's helpers) ships a " \
                 "namespace-only `module Rails`, so the guard reads true and the call " \
                 "raises NoMethodError. Ask `Rails.respond_to?(:<method>)` too:\n  " +
                 offenders.join("\n  ")
  end

  # NON-VACUITY, the other half of trusting a clean scan — and it now runs the
  # SCANNER'S OWN predicate instead of a retyped copy of it.
  #
  # ONE CLAUSE PER TEST, deliberately. `offending_line?` decides on four clauses,
  # and a single combined assertion would go red without saying WHICH of them went
  # inert — the same blindness as the copy, one level in. Split this way, a typo in
  # any one clause reddens the test named for that clause.
  def test_the_predicate_still_flags_the_shape_that_was_fixed
    assert offending_line?(ORIGINAL_STRAGGLER),
           "the predicate the scan actually runs must still match the original " \
           "straggler; if it stops matching, the scan above passes for free"
  end

  def test_the_predicate_exempts_a_comment
    refute offending_line?("    # #{ORIGINAL_STRAGGLER}"),
           "prose describing the bad shape must not be reported as the bad shape, or " \
           "documenting this defect correctly becomes the thing that reddens the suite"
  end

  def test_the_predicate_exempts_a_line_that_already_asks_respond_to
    repaired = 'rails_env: defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : "development",'

    refute offending_line?(repaired),
           "the repaired shape is the one the sweep installed everywhere; flagging it " \
           "would make the scan fail on its own fix"
  end

  def test_the_predicate_exempts_a_bare_boolean_use_of_defined
    refute offending_line?("      return false unless defined?(Rails)"),
           "`defined?(Rails)` with no call on the constant cannot raise, so flagging it " \
           "would report a safe line as a straggler"
  end

  def test_the_predicate_ignores_a_call_that_never_mentions_the_guard
    refute offending_line?("      Rails.env.production?"),
           "a Rails call outside a `defined?(Rails)` guard is a different concern; " \
           "flagging it would fire on most of a real Rails codebase"
  end
end
