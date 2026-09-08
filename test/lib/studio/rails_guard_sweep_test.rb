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

  def scanned_files
    Dir.glob(File.join(GEM_ROOT, "lib", "**", "*.rb")).sort
  end

  def relative(path)
    path.delete_prefix("#{GEM_ROOT}/")
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

    scanned_files.each do |path|
      File.readlines(path).each_with_index do |line, index|
        # COMMENTS ARE EXEMPT, and deliberately so. A comment cannot raise, and
        # the files that carry this guard EXPLAIN the bad shape in prose right
        # above the good one — lib/studio/s3.rb quotes `defined?(Rails)` while
        # describing why it is wrong. Scanning prose would make the correct
        # documentation of this very bug the thing that reddens the suite.
        next if line.lstrip.start_with?("#")
        next unless line.include?("defined?(Rails)")
        next if line.include?("Rails.respond_to?")

        # Only a line that actually CALLS something on the constant can raise.
        # `Rails.respond_to?` is excluded above; a bare boolean use is fine.
        next unless line.match?(/\bRails\.[a-z_][A-Za-z0-9_]*/)

        offenders << "#{relative(path)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty offenders,
                 "these lines guard a Rails method call on `defined?(Rails)` alone. " \
                 "rails-html-sanitizer (via action_view) ships a namespace-only " \
                 "`module Rails`, so the guard reads true and the call raises " \
                 "NoMethodError. Ask `Rails.respond_to?(:<method>)` too:\n  " +
                 offenders.join("\n  ")
  end

  # NON-VACUITY, the other half of trusting a clean scan. The predicate above is
  # only meaningful if it can still say NO — a typo'd regex, or a `next` that
  # swallows everything, would leave `offenders` empty forever and the suite
  # green. This feeds it the exact shape that was fixed and demands a hit.
  def test_the_predicate_still_flags_the_shape_that_was_fixed
    old_shape = 'rails_env: defined?(Rails) ? Rails.env : "development",'

    assert old_shape.include?("defined?(Rails)")
    refute old_shape.include?("Rails.respond_to?")
    assert old_shape.match?(/\bRails\.[a-z_][A-Za-z0-9_]*/),
           "the predicate that decides an offender must still match the original " \
           "straggler; if it stops matching, the scan above passes for free"
  end
end
