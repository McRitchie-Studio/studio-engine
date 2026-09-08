# frozen_string_literal: true

# Guard for bin/lock-bump-mergeable — the four-condition decision that decides
# whether a Dependabot lock PR may merge itself without a human.
#
# WHY THE DECISION IS A SCRIPT AND NOT A YAML `if:`. The four conditions are the
# entire safety argument for auto-merging anything, and a condition expressed as
# a workflow expression can only be tested by READING it. A source-scanning test
# asserts that a string is present, which is not the same claim as "this rejects
# a multi-file PR" — and the difference is invisible until the day it matters.
# Extracted here, every condition is EXECUTED against a fixture, and a mutation
# to any one of them reddens a test rather than passing quietly.
#
# WHY THE CONDITIONS ARE WHAT THEY ARE. The engine's lock trailed the released
# solana-studio five times on 2026-09-07 alone; the 0.6.1 fix went stale 36
# minutes after it was committed. bin/gem-drift-check reddens EVERY open engine
# PR while that is true, so the cost lands on PR authors who did not touch the
# line. Automating it is only defensible while the blast radius of a WRONG
# auto-merge stays smaller than the drift it removes — which is what these four
# conditions buy, and why each is asserted separately below.
#
# THE DEGRADATION PATH IS PART OF THE CONTRACT. A genuinely breaking bump must
# not merge, and must not be swallowed either: the PR stays open and red, the
# drift gate goes on reddening other engine PRs, and a human is pulled in within
# one PR cycle. That is TODAY's behaviour — the floor this feature may never
# drop below — and it is asserted at the bottom of this file rather than left as
# a claim in a commit message.
#
# Run directly:
#   ruby -Itest test/lib/lock_bump_mergeable_test.rb
#
# Two tiers (library shape):
#   [unit] each of the four merge conditions, executed against fixtures.
#   [integration] the workflow really invokes the gate, and cannot merge around it.

# bundler/setup FIRST — the engine's suite guard refuses a test file that reaches
# minitest before the bundle is set up, because it would resolve gems from the
# ambient environment rather than this gem's lock.
require "bundler/setup"
require "minitest/autorun"
require "json"
require "open3"
require "yaml"

class LockBumpMergeableTest < Minitest::Test
  ROOT     = File.expand_path("../..", __dir__)
  SCRIPT   = File.join(ROOT, "bin/lock-bump-mergeable")
  WORKFLOW = File.join(ROOT, ".github/workflows/engine-lock-automerge.yml")
  DEPENDABOT = File.join(ROOT, ".github/dependabot.yml")

  # The diff a real `bundle update solana-studio` produces: ONE resolved spec
  # line, at the four-space indent a Gemfile.lock uses for a resolution.
  def lock_diff(from: "0.6.1", to: "0.7.0")
    <<~DIFF
      diff --git a/Gemfile.lock b/Gemfile.lock
      index 1111111..2222222 100644
      --- a/Gemfile.lock
      +++ b/Gemfile.lock
      @@ -120,7 +120,7 @@ GEM
           simplecov-html (0.13.1)
      -    solana-studio (#{from})
      +    solana-studio (#{to})
           sqlite3 (2.7.4)
    DIFF
  end

  # A PR that satisfies ALL FOUR conditions. Every test below starts from this
  # and breaks exactly one thing, so a test that fails names the condition that
  # failed it rather than "something in the payload".
  def mergeable(**overrides)
    {
      "author" => "dependabot[bot]",
      "files"  => ["Gemfile.lock"],
      "diff"   => lock_diff,
      "checks" => [
        { "name" => "Engine CI",   "status" => "COMPLETED", "conclusion" => "SUCCESS" },
        { "name" => "Consumer CI", "status" => "COMPLETED", "conclusion" => "SUCCESS" }
      ]
    }.merge(overrides)
  end

  def decide(payload)
    out, err, status = Open3.capture3("ruby", SCRIPT, stdin_data: JSON.generate(payload))
    [out, err, status.exitstatus]
  end

  # --- the control: the whole point is that this one DOES merge ---------------

  def test_a_green_lock_only_solana_studio_pr_is_mergeable
    # THE ANTI-VACUOUS FLOOR. Every other test here asserts a REFUSAL, so a gate
    # that refused everything — including a script that crashed on startup —
    # would pass all of them. This is the only test that proves the gate can say
    # yes, which makes it the one that gives the refusals their meaning.
    out, err, code = decide(mergeable)

    assert_equal 0, code, "a green, lock-only solana-studio bump is the ONE case this automates. " \
                          "stdout: #{out.inspect} stderr: #{err.inspect}"
    assert_includes out, "solana-studio"
  end

  # --- condition 1: the author -----------------------------------------------

  def test_a_human_authored_pr_is_never_auto_merged
    # A human PR touching only the lock is a person doing something deliberate.
    # Auto-merging it would merge unreviewed human code, which is a strictly
    # larger blast radius than the drift this feature removes.
    _out, err, code = decide(mergeable("author" => "amcritchie"))
    assert_equal 1, code, "only dependabot[bot] may auto-merge"
    assert_includes err, "author"
  end

  def test_an_author_that_merely_contains_dependabot_is_not_the_bot
    # `dependabot[bot]` is an exact identity, not a substring. A substring test
    # would accept an attacker-registered `not-dependabot[bot]`.
    _out, _err, code = decide(mergeable("author" => "not-dependabot[bot]"))
    assert_equal 1, code, "the author check must be exact, not a substring match"
  end

  # --- condition 2: the changed FILE SET --------------------------------------

  def test_a_multi_file_pr_is_never_auto_merged
    # The named case from the task's test plan. A PR that touches the lock AND
    # anything else is not a lock bump; it is a change wearing one as a hat.
    _out, err, code = decide(mergeable("files" => ["Gemfile.lock", "lib/studio/version.rb"]))
    assert_equal 1, code, "a PR touching more than Gemfile.lock must not auto-merge"
    assert_includes err, "Gemfile.lock"
  end

  def test_a_pr_that_does_not_touch_the_lock_at_all_is_refused
    _out, _err, code = decide(mergeable("files" => ["README.md"]))
    assert_equal 1, code
  end

  def test_an_empty_file_set_is_refused_rather_than_read_as_lock_only
    # An empty list is what a FAILED api read looks like. Treated as "no
    # disallowed files present" it would satisfy a subset-style check and merge
    # a PR nobody measured — the same shape of defect bin/gem-drift-check's
    # "prove the input" guard exists to close.
    _out, _err, code = decide(mergeable("files" => []))
    assert_equal 1, code, "an empty file set is a failed read, not a lock-only PR"
  end

  # --- condition 3: the changed LINE ------------------------------------------

  def test_a_lock_diff_touching_another_gem_is_refused
    # The file set can be exactly [Gemfile.lock] while the CONTENT is a wholesale
    # `bundle update`. Only the solana-studio line is in scope.
    diff = <<~DIFF
      diff --git a/Gemfile.lock b/Gemfile.lock
      --- a/Gemfile.lock
      +++ b/Gemfile.lock
      @@ -120,7 +120,7 @@ GEM
      -    nokogiri (1.18.2)
      +    nokogiri (1.19.0)
      -    solana-studio (0.6.1)
      +    solana-studio (0.7.0)
    DIFF
    _out, err, code = decide(mergeable("diff" => diff))
    assert_equal 1, code, "only the solana-studio line may change"
    assert_includes err, "nokogiri"
  end

  def test_a_lock_diff_that_changes_nothing_is_refused
    # No changed lines means nothing was measured. Merging on it would be a pass
    # over an empty set.
    diff = "diff --git a/Gemfile.lock b/Gemfile.lock\n--- a/Gemfile.lock\n+++ b/Gemfile.lock\n"
    _out, _err, code = decide(mergeable("diff" => diff))
    assert_equal 1, code, "a diff with no changed lines is a failed read, not an approval"
  end

  def test_the_file_header_lines_are_not_mistaken_for_changed_content
    # `--- a/Gemfile.lock` and `+++ b/Gemfile.lock` start with - and +. A naive
    # line scan reads them as changed content that does NOT match solana-studio,
    # which would refuse every real PR — the gate would be inert and look strict.
    out, _err, code = decide(mergeable)
    assert_equal 0, code, "the +++/--- file headers must not be counted as changed lines. #{out}"
  end

  # --- condition 4: CI is green ------------------------------------------------

  def test_a_red_ci_pr_is_never_auto_merged
    # The named case from the task's test plan, and the one that carries the
    # whole safety argument: a BREAKING bump is exactly a lock-only,
    # dependabot-authored, solana-studio-line PR whose CI is red.
    checks = [
      { "name" => "Engine CI",   "status" => "COMPLETED", "conclusion" => "SUCCESS" },
      { "name" => "Consumer CI", "status" => "COMPLETED", "conclusion" => "FAILURE" }
    ]
    _out, err, code = decide(mergeable("checks" => checks))
    assert_equal 1, code, "a red CI must never auto-merge — this is the breaking-bump case"
    assert_includes err, "Consumer CI"
  end

  def test_a_still_running_check_is_not_green
    # Pending is not success. Merging on an incomplete board would merge before
    # the consumer suites — the ones that would SEE a breaking bump — have run.
    checks = [
      { "name" => "Engine CI",   "status" => "COMPLETED",   "conclusion" => "SUCCESS" },
      { "name" => "Consumer CI", "status" => "IN_PROGRESS", "conclusion" => nil }
    ]
    _out, err, code = decide(mergeable("checks" => checks))
    assert_equal 1, code, "an unfinished check is not a green check"
    assert_includes err, "Consumer CI"
  end

  def test_an_empty_check_list_is_refused_rather_than_read_as_green
    # "No checks failed" is TRUE of a board with no checks — including one the
    # API failed to return. This is the single most dangerous vacuous pass
    # available to this script, because it is also the state a brand-new PR is
    # in for the first few seconds of its life.
    _out, _err, code = decide(mergeable("checks" => []))
    assert_equal 1, code, "an empty check list is a failed read, not a green board"
  end

  def test_a_cancelled_check_is_not_green
    checks = [{ "name" => "Engine CI", "status" => "COMPLETED", "conclusion" => "CANCELLED" }]
    _out, _err, code = decide(mergeable("checks" => checks))
    assert_equal 1, code
  end

  def test_a_skipped_check_does_not_block_a_merge
    # SKIPPED is how a path-filtered lane reports itself, and the e2e lane is
    # path-filtered on purpose (docs/E2E_LANE.md). Treating it as red would make
    # the gate inert — always refusing, for a reason no reader would find.
    checks = [
      { "name" => "Engine CI", "status" => "COMPLETED", "conclusion" => "SUCCESS" },
      { "name" => "e2e",       "status" => "COMPLETED", "conclusion" => "SKIPPED" }
    ]
    _out, _err, code = decide(mergeable("checks" => checks))
    assert_equal 0, code, "a skipped path-filtered lane is not a failure"
  end

  # --- the conditions are ANDed, not ORed --------------------------------------

  def test_every_condition_must_hold_at_once
    # Four ANDed conditions is exactly where three go inert behind one. Each
    # payload below satisfies THREE and breaks the fourth; if any single
    # condition stopped being consulted, one of these would start merging.
    [
      ["author", mergeable("author" => "amcritchie")],
      ["files",  mergeable("files" => ["Gemfile.lock", "README.md"])],
      ["diff",   mergeable("diff" => lock_diff.sub("solana-studio", "nokogiri"))],
      ["checks", mergeable("checks" => [{ "name" => "Engine CI", "status" => "COMPLETED",
                                          "conclusion" => "FAILURE" }])]
    ].each do |broken, payload|
      _out, _err, code = decide(payload)
      assert_equal 1, code, "breaking the #{broken} condition alone must refuse the merge"
    end
  end

  # --- malformed input is never a merge -----------------------------------------

  def test_malformed_input_exits_distinguishably_and_never_merges
    _out, err, status = Open3.capture3("ruby", SCRIPT, stdin_data: "not json at all")
    assert_equal 64, status.exitstatus, "usage must not share an exit code with a real refusal"
    assert_includes err, "JSON"
    refute_equal 0, status.exitstatus, "unparseable input must never read as approval"
  end

  def test_a_missing_key_is_refused_rather_than_defaulted
    payload = mergeable
    payload.delete("checks")
    _out, _err, code = decide(payload)
    assert_equal 64, code, "a missing key is a broken caller, not an empty-and-therefore-fine value"
  end

  # --- the wiring: without this the script is prose -----------------------------

  def test_the_workflow_invokes_the_gate_and_merges_only_on_its_verdict
    workflow = YAML.safe_load_file(WORKFLOW, aliases: true)
    steps = workflow.dig("jobs", "auto-merge", "steps")
    refute_nil steps, "engine-lock-automerge.yml must define an auto-merge job"

    gate = steps.find { |s| s["run"].to_s.include?("bin/lock-bump-mergeable") }
    refute_nil gate, "the workflow must run bin/lock-bump-mergeable or the conditions never fire"

    merge = steps.find { |s| s["run"].to_s.include?("gh pr merge") }
    refute_nil merge, "the workflow must actually merge when the gate approves"

    # ORDER IS THE SAFETY PROPERTY. A merge step that can run before the gate is
    # a merge with no conditions at all.
    assert_operator steps.index(merge), :>, steps.index(gate),
                    "the merge must run AFTER the gate, never beside it"
  end

  def test_the_merge_is_a_merge_commit_and_never_a_squash
    # `--squash` rewrites history, which breaks the `git rev-list` ancestry the
    # accepted -> release -> main ladder walks. This is not a style preference.
    body = File.read(WORKFLOW)
    assert_includes body, "gh pr merge --merge"
    refute_includes body, "--squash", "a squash merge breaks the release ladder's ancestry"
    refute_includes body, "--rebase", "a rebase merge breaks the release ladder's ancestry"
  end

  def test_the_merge_step_is_conditional_on_the_gate_outcome
    workflow = YAML.safe_load_file(WORKFLOW, aliases: true)
    steps = workflow.dig("jobs", "auto-merge", "steps")
    merge = steps.find { |s| s["run"].to_s.include?("gh pr merge") }

    refute_nil merge["if"],
               "an unconditional merge step merges every PR the workflow sees, gate or no gate"
  end

  # --- the Dependabot config's three load-bearing properties ---------------------

  def test_dependabot_targets_accepted_on_every_entry
    # Without target-branch, Dependabot targets the DEFAULT branch (main).
    # Merging there puts a commit on main that `release` lacks, and the next
    # `bin/release ship` fails closed on the divergence.
    config = YAML.safe_load_file(DEPENDABOT, aliases: true)
    updates = config["updates"]
    refute_empty updates, "a dependabot config with no updates entries automates nothing"

    updates.each do |entry|
      assert_equal "accepted", entry["target-branch"],
                   "every entry must target `accepted` — target-branch is PER-ENTRY, not global"
    end
  end

  def test_dependabot_is_scoped_to_solana_studio_alone
    # THE JUSTIFICATION FOR AUTOMATING THIS ONE GEM. Dependabot is already
    # installed in mcritchie-studio and turf-monster and has opened 22 PRs since
    # 2026-08-14 with ZERO merged. An unscoped config here buys a 23rd. What
    # makes solana-studio different is that it is FIRST-PARTY and GATED; the
    # graveyard is third-party major bumps that need human judgment.
    config = YAML.safe_load_file(DEPENDABOT, aliases: true)
    config["updates"].each do |entry|
      allow = entry["allow"]
      refute_nil allow, "an entry with no allow block inherits the third-party graveyard"
      assert_equal ["solana-studio"], allow.map { |a| a["dependency-name"] },
                   "the allow block must name solana-studio and nothing else"
    end
  end

  def test_dependabot_keeps_the_target_branch_rationale_in_the_file
    # The comment is hard-won: it is the only place a reader learns that
    # target-branch is per-entry and that SECURITY updates cannot be retargeted.
    # It travelled from the consumers' copies on purpose.
    body = File.read(DEPENDABOT)
    assert_includes body, "per-entry", "the target-branch rationale must travel with the config"
    assert_match(/security updates always target the default branch/i, body,
                 "the un-retargetable security-update caveat must survive")
  end

  # --- the degradation path: a breaking bump must land on TODAY's behaviour ------

  def test_a_breaking_bump_degrades_to_todays_behaviour_and_no_worse
    # THE FLOOR THIS FEATURE MAY NEVER DROP BELOW. A genuinely breaking bump is
    # a PR that satisfies conditions 1-3 exactly and fails 4. Assert the whole
    # shape at once, because "it does not merge" is only half the claim — the
    # other half is that it is not swallowed either.
    breaking = mergeable("checks" => [
      { "name" => "Engine CI",   "status" => "COMPLETED", "conclusion" => "SUCCESS" },
      { "name" => "Consumer CI", "status" => "COMPLETED", "conclusion" => "FAILURE" }
    ])

    _out, err, code = decide(breaking)

    # 1. It does not merge.
    assert_equal 1, code, "a breaking bump must never auto-merge"

    # 2. It is REFUSED, not errored. Exit 64 would mean the gate broke, which is
    #    a different (and unmonitored) state than a considered refusal.
    refute_equal 64, code, "a breaking bump is a refusal, not a malformed input"

    # 3. The refusal names the failing check, so the human pulled in by the
    #    still-red drift gate lands on the reason rather than on a bare exit code.
    assert_includes err, "Consumer CI"

    # 4. The workflow does not close, comment away, or otherwise dispose of the
    #    PR — it leaves it open and red for a human. Anything that mutates PR
    #    state on refusal would be BELOW today's behaviour.
    body = File.read(WORKFLOW)
    refute_includes body, "gh pr close", "closing a refused PR hides the finding"
    refute_includes body, "--delete-branch", "deleting the branch of a refused PR loses the work"
  end
end
