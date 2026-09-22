# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] Every INSTRUCTIONAL `gem "studio-engine", "~> X"` pin in this repo's
# prose must sit at or above the release where local log capping began.
#
# WHY THIS GUARD EXISTS. docs/NEW_APP_SETUP.md told new apps to write
# `gem "studio-engine", "~> 0.6"` for fifty-odd minors. One app copied it
# verbatim — mcritchie-studio-ai-builder-cache, Gemfile `~> 0.6`, Gemfile.lock
# `studio-engine (0.6.0)` — and therefore shipped BELOW the release that caps
# local log files, growing dev/test logs to Rails' 100 MB default. The pin is a
# floor, so `~> 0.6` still RESOLVES to the newest 0.x on a fresh bundle; what it
# fails to do is stop a lock from freezing an app underneath the cap. A doc that
# hands out a number is a promise to hand-edit prose on every release, and this
# repo has now learned twice that the promise is not kept (see README.md's
# "it read v0.6.1 for fifty minors" and docs/RELEASE.md's "This section
# deliberately names no version").
#
# WHAT IS DERIVED AND WHAT IS PINNED. The floor is NOT a constant typed here: it
# is read out of CHANGELOG.md, as the lowest release whose body introduces the
# `studio.logger` initializer. So the day capping moves to a different release,
# this guard moves with it instead of asserting a number nobody re-checked.
#
# THE COUNTER-EXAMPLE, and why CHANGELOG.md is excluded. Released entries are a
# DATED RECORD of what shipped when; `0.4.0`'s git-tag install line is true
# forever and must not be swept forward. Present-tense INSTRUCTIONS move with
# the code; past-tense RECORDS do not. A find-and-replace cannot tell those
# apart, so only the instructional set is graded.
#
# Every scan asserts a FLOOR before it grades, so a selector that stops matching
# fails loudly instead of passing over an empty set.
class EnginePinFloorDocsTest < Minitest::Test
  ROOT      = File.expand_path("../..", __dir__)
  CHANGELOG = File.join(ROOT, "CHANGELOG.md")
  ENGINE_RB = File.join(ROOT, "lib/studio/engine.rb")
  VERSION_RB = File.join(ROOT, "lib/studio/version.rb")

  # The prose that TELLS someone what to write. CHANGELOG.md is deliberately absent.
  INSTRUCTIONAL_DOCS = [
    "README.md",
    "docs/NEW_APP_SETUP.md",
    "docs/RELEASE.md"
  ].freeze

  VERSION_HEADING = /^\#\#\s+(\d+\.\d+\.\d+)\b/
  PIN             = /gem\s+["']studio-engine["']\s*,\s*["']~>\s*([\d.]+)["']/

  # ── THE CODE THIS GRADES AGAINST ────────────────────────────────────────────

  # The lowest released version whose CHANGELOG body introduces `studio.logger`.
  def cap_floor
    current = nil
    hits    = []

    File.readlines(CHANGELOG).each do |line|
      if (m = line.match(VERSION_HEADING))
        current = m[1]
      elsif current && line.include?("studio.logger")
        hits << current
      end
    end

    refute_empty hits,
                 "CHANGELOG.md no longer mentions `studio.logger` under any released version. This guard " \
                 "derives the log-cap floor from that mention; losing it means the floor is underived, not " \
                 "that there is no floor. Fix the derivation rather than deleting this test."

    hits.map { |v| Gem::Version.new(v) }.min
  end

  def current_version
    raw = File.read(VERSION_RB)[/VERSION\s*=\s*["']([\d.]+)["']/, 1]
    assert raw, "could not read Studio::VERSION out of lib/studio/version.rb"
    Gem::Version.new(raw)
  end

  # Collapse hard wrapping: docs/RELEASE.md splits a pin across two lines, and a
  # line-at-a-time scan would silently skip it.
  def pins_in(relative_path)
    body = File.read(File.join(ROOT, relative_path)).gsub(/\s+/, " ")
    body.scan(PIN).flatten.map { |v| [relative_path, Gem::Version.new(v)] }
  end

  def all_pins
    INSTRUCTIONAL_DOCS.flat_map { |doc| pins_in(doc) }
  end

  # ── THE ASSERTIONS ──────────────────────────────────────────────────────────

  def test_the_floor_is_derivable_and_its_reason_is_still_true
    floor = cap_floor

    assert_operator floor, :>, Gem::Version.new("0"),
                    "derived a nonsense log-cap floor (#{floor})"

    # The floor MEANS something only while the engine still caps from the
    # ordered initializer. If this seam is ever demoted to a plain initializer it
    # becomes a silent no-op (Rails builds the logger in :initialize_logger,
    # a BOOTSTRAP initializer that runs first), and every pin below would be
    # graded against a promise the code no longer keeps.
    engine = File.read(ENGINE_RB)
    assert_includes engine, 'initializer "studio.logger"',
                    "lib/studio/engine.rb lost the `studio.logger` initializer — the reason the pin floor exists"
    assert_match(/initializer\s+"studio\.logger",\s*before:\s*:initialize_logger/, engine,
                 "`studio.logger` is no longer declared `before: :initialize_logger`. An engine that assigns " \
                 "the logger from an ordinary initializer is a SILENT NO-OP, so the documented floor would " \
                 "stop buying a log cap at all.")
    assert_includes engine, "config.log_file_size",
                    "`studio.logger` no longer sets config.log_file_size — the knob :initialize_logger reads"
  end

  def test_every_instructional_pin_sits_at_or_above_the_log_cap_floor
    floor = cap_floor
    pins  = all_pins

    assert_operator pins.length, :>=, 3,
                    "matched only #{pins.length} studio-engine pin(s) across #{INSTRUCTIONAL_DOCS.inspect}. " \
                    "Each of those files carries one, so the PIN selector has stopped matching and this test " \
                    "asserts NOTHING. Fix the scan; do not lower this floor."

    stale = pins.reject { |(_doc, version)| version >= floor }

    assert_empty stale.map { |(doc, version)| "#{doc} pins ~> #{version}, below the #{floor} log-cap floor" },
                 "local log capping ships from studio-engine #{floor} (`studio.logger`). These instructional " \
                 "pins would hand a NEW app a floor underneath it, which is exactly how " \
                 "mcritchie-studio-ai-builder-cache locked at 0.6.0 and grew uncapped logs:\n  " +
                 stale.map { |(doc, version)| "#{doc} — ~> #{version}" }.join("\n  ")
  end

  def test_no_instructional_pin_claims_a_floor_that_does_not_exist_yet
    live = current_version

    unresolvable = all_pins.reject { |(_doc, version)| version <= live }

    assert_empty unresolvable.map { |(doc, version)| "#{doc} — ~> #{version}" },
                 "these pins name a floor above the engine's own VERSION (#{live}), so `bundle install` " \
                 "against RubyGems could not resolve them:\n  " +
                 unresolvable.map { |(doc, version)| "#{doc} — ~> #{version}" }.join("\n  ")
  end
end
