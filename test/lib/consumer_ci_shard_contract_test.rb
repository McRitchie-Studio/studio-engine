# frozen_string_literal: true

# Guard for consumer-ci.yml's SHARDED HUB LANE.
#
# The mcritchie_studio lane was 83% of this workflow's wall time (416s of a 502s job on run
# 32334594299) — the hub's own suite, unsharded, run a second time against the engine
# commit. It shards now because the hub's tooling reached the hub's DEFAULT branch, which
# is what this lane checks out.
#
# THE COUPLING THIS FILE EXISTS FOR. The shard denominator lives in TWO repos: the matrix
# below, and `shards:` in the hub's config/rails_lane.yml. bin/ci-shard ABORTS loudly when
# they disagree ("asked for shard 1/4 but ... declares shards: 6"), so a divergence is a red
# build rather than a silent mis-cut — but only the hub's half can move without anyone here
# noticing. This file cannot read the hub's contract (different repo, no checkout at test
# time), so it asserts what it CAN: that this side is internally consistent, and that the
# lane still emits and audits the receipt that would catch a bad cut.
#
# Run directly:
#   ruby -Itest test/lib/consumer_ci_shard_contract_test.rb
#
# One tier (backend shape):
#   [unit] the sharded consumer lane's matrix, receipt and gate, read from the real workflow.

# bundler/setup FIRST — the engine's suite guard refuses a test file that reaches minitest
# before the bundle is set up, because it would resolve gems from the ambient environment
# rather than this gem's lock. bin/release-check caught exactly that on the first cert of
# this file.
require "bundler/setup"
require "minitest/autorun"
require "yaml"

class ConsumerCiShardContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github/workflows/consumer-ci.yml")
  SHARDED_CONSUMER = "mcritchie_studio"

  def workflow = @workflow ||= YAML.safe_load_file(WORKFLOW, aliases: true)
  def entries = workflow.dig("jobs", "consumer-tests", "strategy", "matrix", "include")
  def sharded = entries.select { |e| e["consumer"] == SHARDED_CONSUMER }

  def test_unit_the_hub_lane_is_sharded_and_its_indices_are_complete
    refute_empty sharded, "no #{SHARDED_CONSUMER} entries in consumer-ci's matrix"

    declared = sharded.map { |e| e["shards"] }.uniq
    assert_equal 1, declared.length,
                 "the #{SHARDED_CONSUMER} entries disagree about the shard TOTAL " \
                 "(#{declared.inspect}). bin/ci-shard compares that denominator against the " \
                 "hub's config/rails_lane.yml and aborts on a mismatch — disagreeing with " \
                 "ITSELF means some shards abort and others silently cut a different set."

    total = declared.first
    assert_equal (1..total).to_a, sharded.map { |e| e["shard"] }.sort,
                 "the #{SHARDED_CONSUMER} shard indices must be exactly 1..#{total}. A gap " \
                 "means files that belong to the missing bucket run NOWHERE; a duplicate " \
                 "means they run twice and the executed-set gate sees a shard claimed twice."
  end

  def test_unit_only_the_consumer_with_the_tooling_is_sharded
    # turf-monster and mcritchie-industries have no bin/ci-shard. Sharding them would cut a
    # suite with a planner they do not carry — the `if [ -x bin/ci-shard ]` fallback in the
    # run step keeps them whole, and this keeps the matrix honest about it.
    strays = entries.reject { |e| e["consumer"] == SHARDED_CONSUMER }.select { |e| e["shard"] }

    assert_empty strays.map { |e| e["consumer"] },
                 "these consumers carry a shard index but have no bin/ci-shard to cut with. " \
                 "Give them the tooling first, or leave them whole."
  end

  def test_unit_every_shard_emits_the_receipt_it_is_judged_on
    step = workflow.dig("jobs", "consumer-tests", "steps").find { |s| s["run"].to_s.include?("rails test") }
    refute_nil step, "consumer-ci no longer has a step that runs the consumer suite"

    assert_includes step["env"].to_s, "CI_RECEIPT_OUT",
                    "the suite step no longer sets CI_RECEIPT_OUT, so the consumer's minitest " \
                    "plugin stays inert and NO receipt is written. The gate below can then " \
                    "only report that it found nothing."
    assert_includes step["run"].to_s, "bin/ci-shard --print",
                    "the suite step no longer narrows to this shard's files. If sharding was " \
                    "removed deliberately, remove the matrix entries and this guard together."
  end

  def test_unit_no_expression_carries_shell_quote_escaping
    # BORN FROM A REAL FAILURE. Generating this workflow with a shell heredoc leaked the
    # `'"'"'` idiom into an expression:
    #
    #   CI_RECEIPT_OUT: ${{ matrix.shard && format('"'"'{0}/...'"'"', ...) || '"''"' }}
    #
    # GitHub REJECTED the whole workflow — zero jobs, no log, `conclusion: failure` at 0
    # minutes, which reads like an infrastructure blip rather than a syntax error. YAML
    # parsing does not catch it either: a mangled expression is still a perfectly valid
    # YAML string, so the guard above passed on the broken file.
    #
    # This is the cheapest possible check for the class: nothing in a workflow expression
    # should ever contain a shell quote-escape sequence.
    text = File.read(WORKFLOW)
    offenders = text.lines.each_with_index.select { |line, _| line.include?(%q('"'"')) }

    assert_empty offenders.map { |line, i| "line #{i + 1}: #{line.strip[0, 70]}" },
                 "a shell quote-escape sequence leaked into the workflow. GitHub rejects the " \
                 "file outright — zero jobs, no log — which is easy to misread as a runner " \
                 "problem. Write the expression with plain single quotes."
  end

  def test_unit_the_executed_set_gate_runs_unconditionally
    gate = workflow.dig("jobs", "hub-executed-set")
    refute_nil gate, "consumer-ci has no hub-executed-set job — four green shards over the " \
                     "hub's suite then mean nothing about what they covered"

    assert_equal "always()", gate["if"].to_s.strip,
                 "the gate must carry `if: always()`. On `needs:` alone a red shard SKIPS it, " \
                 "and a skipped required check does not report failure — so the gate goes " \
                 "quiet in exactly the runs where a shrunken lane would show up."
    assert_equal "consumer-tests", gate["needs"].to_s,
                 "the gate must `needs: consumer-tests`, or it runs before the receipts exist"
    assert(gate["steps"].any? { |s| s["run"].to_s.include?("rails-executed-set-check") },
           "the gate job no longer runs bin/rails-executed-set-check")
  end
end
