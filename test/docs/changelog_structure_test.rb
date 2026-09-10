# frozen_string_literal: true

require "test_helper"

# [unit] STRUCTURE guard for CHANGELOG.md. It asserts the file's SHAPE, never its
# prose — no assertion here names an entry, a feature or a word, so ordinary
# changelog writing cannot turn it red.
#
# WHY IT EXISTS. Between 0.39.0 and 0.74.x, `## Unreleased` grew to 2,382 lines
# holding thirty-five minor versions' worth of shipped entries, because `bin/release
# prepare` bumps `lib/studio/version.rb` and its lockfile but never rolls the
# Unreleased heading into a version heading, and nothing failed when it didn't.
# Every reviewer who opened the file then had to decide, per entry, whether it was
# shipped history or pending work — Carl had to measure it during PR #305 just to
# rule on a scope question. This guard is the thing that would have gone red in
# week one.
#
# THE FLOOR MATTERS AS MUCH AS THE RULES. A structure test whose regex stops
# matching passes having proved nothing, so the parse count is asserted against a
# floor before any property is checked.
class ChangelogStructureTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CHANGELOG_PATH = File.join(ROOT, "CHANGELOG.md")

  UNRELEASED = "## Unreleased"

  # The two heading forms this file has used. Modern (everything from 0.8.0 on):
  #   ## 0.74.3 — 2026-09-08
  # Legacy (0.2.4 through v0.7.0, frozen history, deliberately not rewritten):
  #   ## v0.7.0 (2026-06-20)
  MODERN_HEADING = /\A\#\# (\d+\.\d+\.\d+) — (\d{4}-\d{2}-\d{2})\z/
  LEGACY_HEADING = /\A\#\# v(\d+\.\d+\.\d+) \((?:pre-)?\d{4}-\d{2}-\d{2}\)\z/

  # Parse floors. Both are well below the real counts (115 version headings, 83 of
  # them in the modern form at the time of writing) and exist only so a regex that
  # has stopped matching fails LOUDLY instead of vacuously passing.
  MIN_VERSION_HEADINGS = 110
  MIN_MODERN_HEADINGS = 80

  # How far `Studio::VERSION` may run ahead of the newest version heading before
  # the changelog counts as drifting. A release that ships no entry at all is
  # legitimate (0.74.4 was one), so the tolerance is not zero — but a drift of
  # thirty-five minor versions is the defect this file exists to catch.
  MAX_MINOR_DRIFT = 2

  def setup
    @lines = File.readlines(CHANGELOG_PATH, chomp: true)
    @headings = @lines.each_with_index.filter_map do |line, i|
      next unless line.start_with?("## ")

      { line: line, number: i + 1 }
    end
  end

  def test_parses_enough_headings_to_be_meaningful
    refute_empty @headings, "no '## ' headings found at all — the parse is broken, not the file"

    versions = parsed_versions
    unparsed = @headings.reject { |h| h[:line] == UNRELEASED }
                        .reject { |h| version_of(h[:line]) }
    assert_empty unparsed.map { |h| "line #{h[:number]}: #{h[:line]}" },
                 "version headings that match neither the modern nor the legacy form"

    assert_operator versions.size, :>=, MIN_VERSION_HEADINGS,
                    "only #{versions.size} version headings parsed; the regexes have stopped " \
                    "matching the file (floor #{MIN_VERSION_HEADINGS})"

    modern = @headings.count { |h| MODERN_HEADING.match?(h[:line]) }
    assert_operator modern, :>=, MIN_MODERN_HEADINGS,
                    "only #{modern} modern-form headings parsed (floor #{MIN_MODERN_HEADINGS})"
  end

  def test_unreleased_appears_once_and_leads_the_file
    occurrences = @headings.select { |h| h[:line] == UNRELEASED }
    assert_equal 1, occurrences.size,
                 "expected exactly one '#{UNRELEASED}' heading, found #{occurrences.size}"
    assert_equal @headings.first[:number], occurrences.first[:number],
                 "'#{UNRELEASED}' must be the first '## ' heading; found " \
                 "#{@headings.first[:line].inspect} above it"
  end

  def test_version_headings_are_strictly_decreasing
    versions = parsed_versions
    versions.each_cons(2) do |(a_line, a_ver), (b_line, b_ver)|
      assert_operator compare(a_ver, b_ver), :>, 0,
                      "version headings must decrease down the file, but line #{a_line} " \
                      "(#{a_ver.join('.')}) is not above line #{b_line} (#{b_ver.join('.')})"
    end
  end

  def test_no_version_appears_twice
    seen = parsed_versions.map { |_line, ver| ver.join(".") }
    duplicates = seen.tally.select { |_v, n| n > 1 }.keys
    assert_empty duplicates, "these versions carry more than one heading: #{duplicates.join(', ')}"
  end

  def test_every_subsection_sits_under_a_version_heading
    heading_numbers = @headings.map { |h| h[:number] }
    first_heading = heading_numbers.min
    orphans = @lines.each_with_index.filter_map do |line, i|
      next unless line.start_with?("### ")
      next if (i + 1) > first_heading

      "line #{i + 1}: #{line}"
    end
    assert_empty orphans, "'### ' subsections found above the first '## ' heading"
  end

  # THE DRIFT GUARD, and the one that would have caught the original defect.
  # `Studio::VERSION` is the version accepted currently carries; the newest
  # version heading is the newest release the changelog admits shipping. When the
  # second falls far behind the first, releases are going out while their entries
  # sit under Unreleased.
  def test_newest_heading_keeps_up_with_the_shipped_version
    newest = parsed_versions.first
    refute_nil newest, "no version heading to compare against Studio::VERSION"

    current = Studio::VERSION.split(".").map(&:to_i)
    _line, newest_version = newest

    assert_operator compare(current, newest_version), :>=, 0,
                    "the changelog's newest heading (#{newest_version.join('.')}) is AHEAD of " \
                    "Studio::VERSION (#{Studio::VERSION}) — a version was documented before it shipped"

    # A MAJOR bump has to be rolled at once — 1.0.0 shipping while the newest
    # heading still reads 0.74.x is the same defect at a louder scale — so a
    # differing major is refused outright rather than converted into a minor
    # count that would read as nonsense ("926 minor versions").
    major_gap = current[0] - newest_version[0]
    drift = major_gap.zero? ? current[1] - newest_version[1] : nil
    behind = drift ? "#{drift} minor version(s)" : "a whole major version"
    assert drift && drift <= MAX_MINOR_DRIFT,
           "Studio::VERSION is #{Studio::VERSION} but the newest changelog heading is " \
           "#{newest_version.join('.')} — #{behind} of entries are still filed under " \
           "'#{UNRELEASED}'. Roll them into their release headings " \
           "(see docs/RELEASE.md, 'Rolling Unreleased into a version')."
  end

  private

  def parsed_versions
    @parsed_versions ||= @headings.filter_map do |h|
      ver = version_of(h[:line])
      [h[:number], ver] if ver
    end
  end

  def version_of(line)
    match = MODERN_HEADING.match(line) || LEGACY_HEADING.match(line)
    match && match[1].split(".").map(&:to_i)
  end

  def compare(a, b)
    a <=> b
  end
end
