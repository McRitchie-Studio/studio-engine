# frozen_string_literal: true

# bin/lib/e2e_executed_set.rb — THE EXECUTED SET, read off the runner's own receipt.
#
# Asserts one property, and it is the only property that matters about a test lane:
#
#     THE LANE EXECUTED EXACTLY THE SPECS IT IS SUPPOSED TO EXECUTE.
#
# Not "the specs are declared". Not "the command looks right". EXECUTED — as reported
# by Playwright itself, in the JSON report it emits from the run that just happened.
#
# WHY A BRAND-NEW LANE SHIPS WITH THIS ON DAY ONE. Because the alternative was tried
# in this ecosystem and lost, three times. The hub's identical gate exists because
# three successive SOURCE-READING guards were each defeated by a different spelling
# of the same event — a `test.only`, a `testInfo.skip()`, a widened `--grep-invert` —
# and a fourth spelling is always available, because a source-level guard can only
# refuse what someone thought to refuse. The axes are not the disease; reading the
# SOURCE is.
#
# A receipt-reading gate has to be beaten by ARITHMETIC instead, and moving the
# arithmetic means editing config/e2e_lane.yml, which is a reviewable diff line with
# a comment attached. The hole can still grow — but only on purpose, in front of a
# reviewer.
#
# The engine also has a standing lesson of its own: bin/suite-guard exists because a
# curated Ruby test list ran 25 of 26 files with every guard structurally unable to
# see the miss. This is that same principle, one tier over — the engine already
# believes a suite must prove what it RAN, not what it declares.
#
# ================= WHAT IS DELIBERATELY NOT PORTED =================
#
# THE QUARANTINE, AND ITS RATCHET. The hub carries `quarantined`, `quarantine_tag`, a
# `--grep-invert` in its CI command, and an origin/release-baselined ratchet test to
# stop a branch raising its own ceiling. All of it is DEBT MACHINERY for a suite that
# rotted while it went unrun, and this lane has no rot: every spec here was written
# against code that is green today, and each was verified to go RED against its
# defect reintroduced.
#
# Porting it anyway would have been the expensive kind of cargo cult — it would ship
# a documented, reviewed, tested way to EXCLUDE a spec to a lane that has nothing to
# exclude, and the first inconvenient spec would find it. So the contract has no
# quarantine concept at all: `executed == total_specs`, and a spec that must not run
# has to be deleted, which is a diff a reviewer reads as what it is.
#
# WHAT THIS DELIBERATELY DOES NOT ASSERT: whether the specs PASSED. A failing spec is
# a red `playwright` job already. This gate answers the question that job cannot
# answer about ITSELF: did it run everything it claimed?

require "json"
require "yaml"

class E2eExecutedSet
  # Playwright statuses. A test is EXECUTED if it reached a verdict — pass, fail, or
  # flake. `skipped` is the one status that means "this spec left the lane", which is
  # the whole event we are here to catch, on every axis at once.
  EXECUTED_STATUSES = %w[expected unexpected flaky].freeze
  SKIPPED_STATUS = "skipped"

  Report = Struct.new(:source, :doc, keyword_init: true)

  def self.load_contract(path)
    YAML.safe_load_file(path)
  end

  # Every *.json in the reports directory. A report that is MISSING or UNPARSEABLE is
  # a failure, never a pass: a shard that died before writing its receipt is
  # precisely a shard whose specs did not run.
  def self.load_reports(dir)
    Dir.glob(File.join(dir, "**", "*.json")).sort.map do |path|
      Report.new(source: File.basename(path), doc: JSON.parse(File.read(path)))
    rescue JSON::ParserError => e
      Report.new(source: File.basename(path), doc: { "__parse_error__" => e.message })
    end
  end

  def initialize(contract:, reports:)
    @contract = contract
    @reports = reports
  end

  attr_reader :contract, :reports

  def expected_executed = contract.fetch("executed")

  # Walk the report's suite tree. Playwright nests suites per file and per
  # describe-block, so specs live at arbitrary depth; a flat read of `suites[].specs`
  # silently misses everything inside a `test.describe`, which would under-count and
  # fire a confusing failure.
  def specs_in(doc)
    found = []
    walk = lambda do |node|
      Array(node["specs"]).each { |spec| found << spec }
      Array(node["suites"]).each { |child| walk.call(child) }
    end
    Array(doc["suites"]).each { |suite| walk.call(suite) }
    found
  end

  # A spec carries one `test` per project. Count TESTS, not specs — that is what
  # Playwright's own `--list` and `stats` count, so the contract's numbers mean the
  # same thing here that they mean when a human runs the command by hand.
  #
  # This is also why adding a second browser project would DOUBLE the executed count
  # rather than leave it alone. See config/e2e_lane.yml.
  def tests_in(doc)
    specs_in(doc).flat_map do |spec|
      Array(spec["tests"]).map { |test| { "title" => spec["title"], "status" => test["status"] } }
    end
  end

  def all_tests = reports.flat_map { |report| tests_in(report.doc) }
  def executed_tests = all_tests.select { |test| EXECUTED_STATUSES.include?(test["status"]) }
  def skipped_tests = all_tests.select { |test| test["status"] == SKIPPED_STATUS }

  # An unsharded run reports no shard block; treat it as the only shard (1 of 1) so
  # the completeness check reads the same for a local `npx playwright test` and for a
  # future sharded matrix.
  def shard_of(doc)
    shard = doc.dig("config", "shard")
    return { current: 1, total: 1 } unless shard

    { current: shard["current"], total: shard["total"] }
  end

  def failures
    [
      parse_failures,
      shard_completeness_failures,
      report_shape_failures,
      skipped_failures,
      count_failures
    ].flatten.compact
  end

  def ok? = failures.empty?

  def summary
    "#{executed_tests.size} executed · #{skipped_tests.size} skipped · " \
      "#{reports.size} shard report(s) · contract: #{expected_executed} executed " \
      "(#{contract.fetch("total_specs")} committed)"
  end

  private

  def parse_failures
    reports.filter_map do |report|
      next unless report.doc.key?("__parse_error__")

      "#{report.source} is not parseable JSON (#{report.doc["__parse_error__"]}). A shard " \
        "whose report is missing or corrupt is a shard whose specs cannot be shown to have " \
        "run — that is a RED verdict, not a pass."
    end
  end

  # The report must look like the thing we think we are reading. If Playwright ever
  # changes the report schema, this gate must FAIL LOUDLY rather than quietly walk an
  # empty tree, read "0 executed", and get "fixed" by someone lowering the contract.
  def report_shape_failures
    reports.filter_map do |report|
      next if report.doc.key?("__parse_error__")

      stats = report.doc["stats"]
      next "#{report.source} has no `stats` block — this is not a Playwright JSON report." unless stats.is_a?(Hash)

      counted = tests_in(report.doc).size
      claimed = EXECUTED_STATUSES.sum { |status| stats[status].to_i } + stats["skipped"].to_i
      next if counted == claimed

      "#{report.source}: walked #{counted} test(s) out of the suite tree but its own `stats` " \
        "block claims #{claimed}. The report schema is not what this gate was written " \
        "against — FIX THE GATE (bin/lib/e2e_executed_set.rb), do not lower the contract."
    end
  end

  # KEPT EVEN THOUGH THE LANE RUNS ONE SHARD TODAY. `shards: 1` makes this check
  # assert "exactly one report arrived", which is a real property: a webServer that
  # died after the health probe, or an upload step that silently wrote nothing, both
  # land here. And the day the suite grows enough to shard, the guard is already in
  # place rather than being remembered.
  def shard_completeness_failures
    parsed = reports.reject { |report| report.doc.key?("__parse_error__") }
    return [] if parsed.empty?

    shards = parsed.map { |report| shard_of(report.doc) }
    totals = shards.map { |shard| shard[:total] }.uniq

    if totals.size > 1
      return ["the shard reports disagree about how many shards there are (#{totals.inspect}). " \
              "Some of these came from a different run."]
    end

    total = totals.first
    seen = shards.map { |shard| shard[:current] }.sort
    want = (1..total).to_a
    return [] if seen == want

    ["expected one report from each of #{total} shard(s) — #{want.inspect} — but got " \
     "#{seen.inspect}. A shard whose report never arrived is a shard whose specs never ran. " \
     "This is the DROPPED-SHARD vector: delete one entry from a `shard:` matrix and every " \
     "remaining job stays green over a smaller suite."]
  end

  def skipped_failures
    return [] if skipped_tests.empty?

    titles = skipped_tests.map { |test| "  · #{test["title"]}" }.join("\n")
    ["#{skipped_tests.size} spec(s) were SKIPPED AT RUNTIME:\n#{titles}\n" \
     "A skipped spec exits 0 and reports green. This is the axis no source-level guard can " \
     "close: `testInfo.skip()`, `test.info().skip()`, a destructured `const { skip } = " \
     "testInfo`, or a helper in another file that calls it for you — all identical here, all " \
     "invisible to a grep.\n" \
     "THIS LANE HAS NO QUARANTINE, so there is no third option to reach for: fix the spec, or " \
     "delete it and lower `total_specs`/`executed` in config/e2e_lane.yml. Both are diffs a " \
     "reviewer reads as what they are."]
  end

  # THE ARITHMETIC. Everything above is a named diagnosis; this is the catch-all that
  # fires for the vectors nobody has imagined yet, because they all reduce to the
  # same thing.
  def count_failures
    actual = executed_tests.size
    return [] if actual == expected_executed

    delta = actual - expected_executed
    direction = delta.negative? ? "FEWER" : "MORE"

    ["the lane EXECUTED #{actual} spec(s); config/e2e_lane.yml pins it at #{expected_executed} " \
     "(#{delta.abs} #{direction} than the contract).\n" \
     "The green `playwright` check now covers a DIFFERENT SET than the one this repo signed " \
     "off on, and the source may look completely innocent — this assertion is deliberately " \
     "blind to HOW the set changed, because every source-reading version of this guard in this " \
     "ecosystem was defeated by a HOW it had not enumerated.\n" \
     "If specs LEFT the lane, find out why before you touch this number. Known ways, none of " \
     "which change the spec count in the source: a `--grep`/`--grep-invert` added to the CI " \
     "command, `--only-changed`, `--last-failed`, a `--max-failures` early exit, a narrowed " \
     "`testDir`/`testIgnore`, a dropped shard, or a runtime skip.\n" \
     "If specs ARRIVED unexpectedly, a second browser PROJECT is the likeliest cause — " \
     "Playwright counts one test per spec PER PROJECT, so adding firefox doubles this number.\n" \
     "If you legitimately added or removed specs: move `total_specs` AND `executed` in " \
     "config/e2e_lane.yml in the same commit, and confirm with `npx playwright test --list`."]
  end
end
