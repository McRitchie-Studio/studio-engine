# frozen_string_literal: true

require "test_helper"

# THE GUARD FOR WHAT THE BROWSER LANE CANNOT SEE.
#
# e2e/at_time_script.spec.js drives the re-stamper in a real Chromium and proves it
# RUNS — which is the half a Rails test cannot reach. This file asserts the other
# half, and it is here BECAUSE the browser lane is structurally blind to it.
#
# THE DEFECT (local-at-time-format, one of the three that motivated the browser
# evidence gate). `isUS()` matched tzdb LONG-FORM zone ids. A browser does not hand
# back the id it was given — it hands back the CLDR-CANONICAL one, and the engines
# DISAGREE about which that is:
#
#     Chromium / WebKit   ->  America/Indianapolis        (two segments)
#     Firefox             ->  America/Indiana/Indianapolis (three segments)
#
# The short forms match no US_PREFIXES entry, and zoneFlag()'s parent fallback only
# fires for ids with MORE than two segments, so it never fired for them either. US
# readers in Indianapolis and Louisville saw an "abroad" globe in Chrome and Safari
# while Firefox readers beside them saw the correct bare clock.
#
# WHY THIS IS NOT A PLAYWRIGHT SPEC. Two reasons, and the second is the real one.
#
#   1. The lane runs one engine. Under Chromium, V8 canonicalizes the id BEFORE
#      isUS() ever sees it, so a spec pinned to America/Indiana/Indianapolis is
#      handed America/Indianapolis and passes over the exact bug.
#   2. Running all three engines would still not close it. The defect only appears
#      if a spec happens to pick INDIANA — every other US zone passes in all three
#      browsers. A three-engine matrix would triple the lane's cost to catch this
#      only if someone had already thought to test the zone that breaks, and if they
#      had, the one-engine lane plus this file would have caught it too.
#
# The honest tier for "both spellings are members of a table" is a table test. It is
# engine-independent, total rather than sampled, and runs in milliseconds on every
# PR. That is why playwright.config.js names Intl divergence as a KNOWN limit and
# points here instead of quietly widening the matrix.
class AtTimeZoneTableTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PARTIAL = File.join(ROOT, "app", "views", "studio", "_at_time_script.html.erb")

  # Each pair is [canonical-short (Chromium/WebKit), canonical-long (Firefox)]. BOTH
  # must resolve to the US or one engine's readers break. Deleting either spelling is
  # the regression.
  DIVERGENT_ZONES = [
    ["America/Indianapolis", "America/Indiana/Indianapolis"],
    ["America/Louisville", "America/Kentucky/Louisville"]
  ].freeze

  def source = @source ||= File.read(PARTIAL)

  # The literal members of US_ZONES, read out of the shipped partial rather than
  # copied here — a copy would drift and then assert about itself.
  def us_zones
    @us_zones ||= begin
      body = source[/var US_ZONES = \((.*?)\)\.split/m, 1]
      refute_nil body, "could not find US_ZONES in #{PARTIAL}"
      body.scan(/"([^"]*)"/).flatten.join.split
    end
  end

  def us_prefixes
    @us_prefixes ||= begin
      body = source[/var US_PREFIXES = \[(.*?)\]/m, 1]
      refute_nil body, "could not find US_PREFIXES in #{PARTIAL}"
      body.scan(/"([^"]*)"/).flatten
    end
  end

  # Mirrors isUS() exactly: literal membership, then prefix families.
  def resolves_to_us?(zone)
    us_zones.include?(zone) || us_prefixes.any? { |prefix| zone.start_with?(prefix) }
  end

  def test_unit_both_engine_spellings_of_every_divergent_zone_resolve_to_the_us
    DIVERGENT_ZONES.each do |short, long|
      assert resolves_to_us?(short),
             "#{short} does not resolve to the US. This is the CHROMIUM and WEBKIT spelling — " \
             "V8 and JavaScriptCore canonicalize the long id down to it, so removing this member " \
             "shows an 'abroad' flag to every Chrome and Safari reader in that city. The browser " \
             "lane CANNOT catch this: it runs Chromium, which hands isUS() this exact string."

      assert resolves_to_us?(long),
             "#{long} does not resolve to the US. This is the FIREFOX spelling — Gecko reports " \
             "the three-segment id — so removing it breaks Firefox readers only, in a lane that " \
             "runs no Firefox."
    end
  end

  # The prefix families and the literal aliases cover DIFFERENT engines, so a change
  # that keeps one working while dropping the other is a half-fix that reads as
  # green in whichever browser the author happened to open.
  def test_unit_the_prefix_families_cover_the_long_form_spellings
    %w[America/Indiana/ America/Kentucky/].each do |prefix|
      assert_includes us_prefixes, prefix,
                      "#{prefix} is the family Firefox's canonical ids live under; without it, " \
                      "every city in it falls through to the flag branch for Gecko readers."
    end
  end

  # zoneFlag()'s parent fallback splits on "/" and retries on the first two segments,
  # so it only ever helps ids with MORE than two. That is precisely why the short
  # aliases must be literal members and cannot lean on the fallback.
  def test_unit_the_short_aliases_cannot_rely_on_the_parent_fallback
    DIVERGENT_ZONES.each do |short, _long|
      assert_equal 2, short.split("/").size,
                   "#{short} is assumed to be a two-segment id by this test's reasoning"
      assert_includes us_zones, short,
                      "#{short} must be a LITERAL member of US_ZONES. It has two segments, so " \
                      "zoneFlag()'s parent fallback (which requires more than two) can never " \
                      "rescue it, and no US_PREFIXES entry matches it."
    end
  end
end
