# frozen_string_literal: true

# Guard for consumer-ci.yml's CONSUMER REF PAIRING — the rule that this lane checks the
# consumer out at the LADDER RUNG matching the engine ref under test, never at whatever
# the consumer's default branch happens to be.
#
# WHY THIS FILE EXISTS. The checkout carried no `ref:` at all until 2026-08-21, so every
# consumer lane ran the consumer's DEFAULT branch — `main`, the last SHIPPED state — against
# an engine commit from a later rung. That is not a neutral choice. The lane runs the
# consumer's ENTIRE suite, and some of those tests are hub-internal guards that read the
# hub's own CROSS-BRANCH state, so a stale checkout makes them wrong about the hub rather
# than about the engine:
#
#   · E2eQuarantineRatchetTest baselines `quarantined:` against `origin/release` INSIDE the
#     checkout. On hub `main` (15) against hub `release` (12) it reported "Expected 15 to be
#     <= 12" — a checkout that merely LAGS release, read as a ceiling RISE.
#   · CiTestCommandTest's pin anti-vacuity assert ("Expected [] to not be empty") was fixed
#     on hub `accepted` and had never reached `main`.
#
# Both reds were unreachable from the engine side, and the hub's `main` only advances via
# `bin/release ship` → candidate assembled → gem published → this lane green. The loop held
# `studio_engine 0.58.0` unpublished. A comment would not have caught it; this file is the
# thing that stays true.
#
# WHAT IT ASSERTS, AND WHY IT RUNS THE SCRIPT RATHER THAN READING IT. A YAML grep proves the
# workflow SAYS the right words. It cannot prove the resolution BEHAVES — that `release`
# pairs to `release`, that a missing branch degrades to the default instead of failing the
# checkout, that an off-ladder base does not accidentally pair. So the integration tier
# EXTRACTS the shipped `run:` script out of the workflow and EXECUTES it under bash with a
# stubbed `gh`, once per (trigger context × consumer) cell. The thing under test is the text
# GitHub will run, not a Ruby restatement of it.
#
# Run directly:
#   ruby -Itest test/lib/consumer_ci_ref_pairing_test.rb
#
# Two tiers (backend shape):
#   [unit]        the workflow's checkout/resolve wiring, read from the real file.
#   [integration] the shipped resolve script, executed against a stubbed branch listing.

# bundler/setup FIRST — the engine's suite guard refuses a test file that reaches minitest
# before the bundle is set up, because it would resolve gems from the ambient environment
# rather than this gem's lock.
require "bundler/setup"
require "minitest/autorun"
require "yaml"
require "open3"
require "tmpdir"

class ConsumerCiRefPairingTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW = File.join(ROOT, ".github/workflows/consumer-ci.yml")

  # The rungs of the shared ladder. A consumer checkout may pair with these and nothing else.
  LADDER = %w[main release accepted].freeze

  # Every consumer this workflow checks out, and the rungs each one really has. VERIFIED with
  # `git ls-remote --heads origin main release accepted` against all three repos on
  # 2026-08-21: all nine branches exist. Kept as data so the integration tier can also drive
  # the branch-is-MISSING path, which no live repo currently exercises.
  CONSUMER_REPOS = %w[mcritchie-studio turf-monster mcritchie-industries].freeze

  # The resolution this lane promises, as a table. Left column is the engine trigger context
  # reduced to its candidate (`github.base_ref || github.ref_name`); right column is the
  # consumer ref that must come out. "" means actions/checkout's default-branch behaviour.
  RESOLUTION = {
    "release" => "release",             # push to engine release — the release candidate
    "main" => "main",                   # push to engine main — last shipped, both sides
    "accepted" => "accepted",           # PR based on engine accepted (the normal feature PR)
    "feat/break-consumer-lane-deadlock" => "", # PR based on a feature branch — off-ladder
    "" => ""                            # no context at all — degrade, never guess
  }.freeze

  def workflow = @workflow ||= YAML.safe_load_file(WORKFLOW, aliases: true)

  def steps_for(job) = workflow.dig("jobs", job, "steps") || []

  def all_steps = workflow["jobs"].keys.flat_map { |job| steps_for(job).map { |s| [job, s] } }

  def checkout_steps
    all_steps.select { |_job, s| s["uses"].to_s.start_with?("actions/checkout") }
  end

  def resolve_steps
    all_steps.select { |_job, s| s["id"] == "consumer-ref" }
  end

  # ==== [unit] the wiring ==============================================================

  def test_unit_every_consumer_checkout_pins_a_ref
    consumer_checkouts = checkout_steps.select { |_job, s| s.dig("with", "repository").to_s.start_with?("McRitchie-Studio/") }

    refute_empty consumer_checkouts, "consumer-ci checks out no consumer at all — did the lane move?"

    unpinned = consumer_checkouts.reject { |_job, s| s.dig("with", "ref").to_s.include?("steps.consumer-ref.outputs.ref") }

    assert_empty unpinned.map { |job, s| "#{job}: #{s["name"]}" },
                 "a consumer checkout carries no `ref:` wired to the resolve step, so it takes " \
                 "that repo's DEFAULT branch. That is the exact shape of the 2026-08-21 deadlock: " \
                 "the lane ran the hub's last-SHIPPED tree against a release-candidate engine, two " \
                 "hub-internal guards went red about the hub's own cross-branch state, and the gem " \
                 "publish those reds gated was the only thing that could have advanced the tree " \
                 "they complained about. Pair the checkout to the rung; do not silence the guard."
  end

  def test_unit_the_engine_checkout_stays_unpinned
    # The engine checkout must take the triggering commit — the thing on trial. A `ref:` here
    # would test some OTHER engine tree and quietly green the wrong commit.
    engine = checkout_steps.find { |_job, s| s.dig("with", "path") == "studio" }
    refute_nil engine, "consumer-ci no longer checks the engine out into ./studio"

    assert_nil engine.last.dig("with", "ref"),
               "the ENGINE checkout was pinned to a ref. This lane exists to test the commit that " \
               "triggered it; pinning it tests a different tree and reports the verdict as this one's."
  end

  def test_unit_the_lane_checkout_keeps_full_depth
    lane = checkout_steps.find { |job, s| job == "consumer-tests" && s.dig("with", "path") != "studio" }
    refute_nil lane, "consumer-ci no longer checks a consumer out in the consumer-tests job"

    assert_equal 0, lane.last.dig("with", "fetch-depth"),
                 "fetch-depth: 0 is LOAD-BEARING and works WITH the paired ref, not instead of it. " \
                 "Full depth makes `origin/release` RESOLVABLE inside the checkout; the paired ref " \
                 "makes the comparison against it MEANINGFUL. The hub's e2e quarantine ratchet fails " \
                 "closed without the first and lies without the second."
  end

  def test_unit_both_resolve_steps_are_byte_identical
    assert_equal 2, resolve_steps.length,
                 "expected exactly two `consumer-ref` resolve steps — one per job that checks a " \
                 "consumer out. Found #{resolve_steps.length}: #{resolve_steps.map(&:first).inspect}."

    scripts = resolve_steps.map { |_job, s| s["run"] }.uniq
    assert_equal 1, scripts.length,
                 "the two resolve steps have DRIFTED apart. GitHub Actions has no YAML anchors, so " \
                 "the duplicate is deliberate — but a duplicate nobody compares is how the sharded " \
                 "lane and its executed-set gate end up auditing two different branches against each " \
                 "other. Keep them byte-identical or give them a shared composite action."

    resolve_steps.each do |job, step|
      assert_equal "${{ github.base_ref || github.ref_name }}", step.dig("env", "CANDIDATE"),
                   "#{job}'s resolve step no longer derives the candidate from the PR base (falling " \
                   "back to the pushed branch). Those two together ARE the rung under test."
    end
  end

  def test_unit_the_gate_job_pairs_with_the_shards_it_audits
    gate = resolve_steps.find { |job, _s| job == "hub-executed-set" }
    refute_nil gate, "the executed-set gate no longer resolves a consumer ref"

    assert_equal "mcritchie-studio", gate.last.dig("env", "CONSUMER_REPO"),
                 "bin/rails-executed-set-check RE-DERIVES the expected file set from the tree this " \
                 "job checks out. Point it at a different repo or rung than the shards ran on and it " \
                 "reports drift that is only ever two branches being two branches."
  end

  # ==== [integration] the shipped script, executed ======================================

  def resolve_script
    @resolve_script ||= resolve_steps.first.last.fetch("run")
  end

  # Runs the REAL `run:` text with a stubbed `gh`, and returns what it wrote to GITHUB_OUTPUT.
  def resolve(candidate:, consumer_repo:, existing_branches:)
    Dir.mktmpdir do |dir|
      stub = File.join(dir, "gh")
      File.write(stub, <<~STUB)
        #!/bin/sh
        # $1 = api, $2 = repos/McRitchie-Studio/<repo>/branches/<branch>
        repo=$(echo "$2" | cut -d/ -f3)
        branch=$(echo "$2" | cut -d/ -f5-)
        case " $STUB_BRANCHES " in
          *" ${repo}:${branch} "*) exit 0 ;;
          *) exit 1 ;;
        esac
      STUB
      File.chmod(0o755, stub)

      out_file = File.join(dir, "github_output")
      File.write(out_file, "")

      env = {
        "PATH" => "#{dir}:#{ENV.fetch("PATH")}",
        "CANDIDATE" => candidate,
        "CONSUMER_REPO" => consumer_repo,
        "GH_TOKEN" => "stub-token-not-a-real-secret",
        "GITHUB_OUTPUT" => out_file,
        "STUB_BRANCHES" => existing_branches.map { |b| "#{consumer_repo}:#{b}" }.join(" ")
      }

      _stdout, stderr, status = Open3.capture3(env, "bash", "-c", resolve_script, unsetenv_others: true)
      assert status.success?, "the resolve script exited #{status.exitstatus}: #{stderr}"

      line = File.read(out_file).lines.map(&:strip).find { |l| l.start_with?("ref=") }
      refute_nil line, "the resolve script wrote no `ref=` to GITHUB_OUTPUT"
      line.delete_prefix("ref=")
    end
  end

  def test_integration_every_trigger_context_pairs_with_every_consumer
    # THE TABLE, driven against the shipped script. Every consumer really does carry all three
    # rungs today, so this is the resolution the lane performs in production.
    CONSUMER_REPOS.each do |repo|
      RESOLUTION.each do |candidate, expected|
        actual = resolve(candidate: candidate, consumer_repo: repo, existing_branches: LADDER)

        assert_equal expected, actual,
                     "engine ref #{candidate.inspect} against #{repo} resolved to #{actual.inspect}, " \
                     "expected #{expected.inspect} (\"\" = the consumer's default branch)."
      end
    end
  end

  def test_integration_a_missing_rung_degrades_to_the_default_branch
    # THE HARD CONSTRAINT: a consumer that lacks the rung must fall back, never fail the
    # checkout. A hard failure here takes a whole consumer lane down over a branch that was
    # simply never created — and it would do it on the release push, the worst possible moment.
    CONSUMER_REPOS.each do |repo|
      LADDER.each do |rung|
        without = LADDER - [rung]

        assert_equal "", resolve(candidate: rung, consumer_repo: repo, existing_branches: without),
                     "#{repo} without a `#{rung}` branch must fall back to its DEFAULT branch " \
                     "(empty ref), not pin a ref that does not exist. actions/checkout fails hard " \
                     "on a missing ref, and this lane must degrade instead."

        assert_equal rung, resolve(candidate: rung, consumer_repo: repo, existing_branches: [rung]),
                     "#{repo} WITH a `#{rung}` branch must pair with it."
      end
    end
  end

  def test_integration_an_off_ladder_branch_never_pairs_even_when_it_exists
    # A consumer may legitimately carry a branch whose NAME matches an engine feature branch —
    # two agents naming the same task the same thing. That coincidence is not a pairing, and
    # the lane must not let a stray branch decide which tree a release candidate is tested
    # against. The allowlist is checked BEFORE the branch lookup for exactly this reason.
    stray = "feat/break-consumer-lane-deadlock"

    assert_equal "", resolve(candidate: stray, consumer_repo: "mcritchie-studio",
                             existing_branches: LADDER + [stray]),
                 "an off-ladder branch paired just because the consumer happened to have one. " \
                 "Only #{LADDER.join(", ")} may pair; everything else takes the default branch."
  end
end
