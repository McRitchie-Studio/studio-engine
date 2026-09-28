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
require "json"
require "fileutils"
require "digest"

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

  # The one expression every consumer checkout must read its ref from.
  RESOLVED_SHAS = "needs.consumer-refs.outputs.shas"

  # ==== [unit] the wiring ==============================================================

  def test_unit_every_consumer_checkout_pins_the_resolved_sha
    consumer_checkouts = checkout_steps.select { |_job, s| s.dig("with", "repository").to_s.start_with?("McRitchie-Studio/") }

    refute_empty consumer_checkouts, "consumer-ci checks out no consumer at all — did the lane move?"

    unpinned = consumer_checkouts.reject { |_job, s| s.dig("with", "ref").to_s.include?(RESOLVED_SHAS) }

    assert_empty unpinned.map { |job, s| "#{job}: #{s["name"]}" },
                 "a consumer checkout does not read its ref from #{RESOLVED_SHAS}. A branch name " \
                 "(or no ref at all) is re-read by every shard minutes apart, so a consumer merge " \
                 "mid-run puts the shards on different commits and the executed-set gate goes red."

    consumer_checkouts.map(&:first).uniq.each do |job|
      assert_includes Array(workflow.dig("jobs", job, "needs")), "consumer-refs",
                      "#{job} checks a consumer out but does not `needs: consumer-refs`"
    end
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

  def test_unit_one_job_resolves_every_consumer_once
    assert_equal ["consumer-refs"], resolve_steps.map(&:first),
                 "exactly one `consumer-ref` resolve step, in the consumer-refs job. A resolve step " \
                 "per job (or per shard) re-reads a moving branch and splits the run across commits."

    step = resolve_steps.first.last
    assert_equal "${{ github.base_ref || github.ref_name }}", step.dig("env", "CANDIDATE"),
                 "the resolve step no longer derives the candidate from the PR base (falling back " \
                 "to the pushed branch). Those two together ARE the rung under test."
    assert_equal CONSUMER_REPOS.sort, step.dig("env", "CONSUMER_REPOS").split.sort,
                 "consumer-refs must resolve every consumer the matrix checks out"

    matrix_repos = workflow.dig("jobs", "consumer-tests", "strategy", "matrix", "include").map { |e| e["repo"] }.uniq
    assert_equal CONSUMER_REPOS.sort, matrix_repos.sort,
                 "the matrix and consumer-refs disagree on the consumers; a repo missing from " \
                 "consumer-refs would check out an empty ref"

    assert_equal "${{ steps.consumer-ref.outputs.shas }}",
                 workflow.dig("jobs", "consumer-refs", "outputs", "shas"),
                 "consumer-refs must export the resolved map as its `shas` job output"
  end

  def test_unit_the_gate_job_audits_the_hub_commit_the_shards_ran
    gate = checkout_steps.find do |job, s|
      job == "hub-executed-set" && s.dig("with", "repository").to_s.end_with?("mcritchie-studio")
    end
    refute_nil gate, "the executed-set gate no longer checks the hub out"

    assert_equal "${{ fromJSON(#{RESOLVED_SHAS})['mcritchie-studio'] }}", gate.last.dig("with", "ref"),
                 "bin/rails-executed-set-check RE-DERIVES the expected file set from the tree this " \
                 "job checks out, so it must be the hub commit the shards ran."
  end

  # ==== [integration] the shipped script, executed ======================================

  # The stub reports this as every consumer's default branch, so a default-branch fallback
  # is distinguishable from a `main` pairing.
  DEFAULT_BRANCH = "trunk"

  def fake_sha(repo, ref) = Digest::SHA1.hexdigest("#{repo}:#{ref}")

  def resolve_script
    @resolve_script ||= resolve_steps.first.last.fetch("run")
  end

  # Runs the REAL `run:` text with a stubbed `gh`; returns [status, shas-map].
  def run_resolver(candidate:, repos:, existing_branches:, unresolvable: [])
    Dir.mktmpdir do |dir|
      stub = File.join(dir, "gh")
      File.write(stub, <<~STUB)
        #!/usr/bin/env ruby
        require "digest"
        path = ARGV[1].to_s.split("/")
        repo = path[2]
        case path[3]
        when "branches"
          exit(ENV.fetch("STUB_BRANCHES").split.include?("\#{repo}:\#{path[4..].join("/")}") ? 0 : 1)
        when "commits"
          ref = path[4..].join("/")
          exit 1 if ENV.fetch("STUB_UNRESOLVABLE").split.include?(repo)
          puts Digest::SHA1.hexdigest("\#{repo}:\#{ref}")
        when nil
          puts "#{DEFAULT_BRANCH}"
        else
          exit 2
        end
      STUB
      File.chmod(0o755, stub)

      out_file = File.join(dir, "github_output")
      File.write(out_file, "")

      env = {
        "PATH" => "#{dir}:#{ENV.fetch("PATH")}",
        "CANDIDATE" => candidate,
        "CONSUMER_REPOS" => repos.join(" "),
        "GH_TOKEN" => "stub-token-not-a-real-secret",
        "GITHUB_OUTPUT" => out_file,
        "STUB_BRANCHES" => repos.product(existing_branches).map { |r, b| "#{r}:#{b}" }.join(" "),
        "STUB_UNRESOLVABLE" => unresolvable.join(" ")
      }

      _stdout, stderr, status = Open3.capture3(env, "bash", "-c", resolve_script, unsetenv_others: true)
      line = File.read(out_file).lines.map(&:strip).find { |l| l.start_with?("shas=") }
      [status, line && JSON.parse(line.delete_prefix("shas=")), stderr]
    end
  end

  # The branch whose commit the resolver pinned for one consumer ("" = default branch).
  def resolve(candidate:, consumer_repo:, existing_branches:)
    status, shas, stderr = run_resolver(candidate: candidate, repos: [consumer_repo], existing_branches: existing_branches)
    assert status.success?, "the resolve script exited #{status.exitstatus}: #{stderr}"
    refute_nil shas, "the resolve script wrote no `shas=` to GITHUB_OUTPUT"

    sha = shas.fetch(consumer_repo)
    ([DEFAULT_BRANCH] + LADDER).find { |ref| fake_sha(consumer_repo, ref) == sha }
                               .then { |ref| ref == DEFAULT_BRANCH ? "" : ref }
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
    # A consumer that lacks the rung must fall back to its default branch, never fail the run.
    CONSUMER_REPOS.each do |repo|
      LADDER.each do |rung|
        without = LADDER - [rung]

        assert_equal "", resolve(candidate: rung, consumer_repo: repo, existing_branches: without),
                     "#{repo} without a `#{rung}` branch must fall back to its DEFAULT branch."

        assert_equal rung, resolve(candidate: rung, consumer_repo: repo, existing_branches: [rung]),
                     "#{repo} WITH a `#{rung}` branch must pair with it."
      end
    end
  end

  def test_integration_an_off_ladder_branch_never_pairs_even_when_it_exists
    # A consumer branch whose NAME matches an engine feature branch is a coincidence, not a
    # pairing. The allowlist is checked BEFORE the branch lookup for exactly this reason.
    stray = "feat/break-consumer-lane-deadlock"

    assert_equal "", resolve(candidate: stray, consumer_repo: "mcritchie-studio",
                             existing_branches: LADDER + [stray]),
                 "an off-ladder branch paired just because the consumer happened to have one. " \
                 "Only #{LADDER.join(", ")} may pair; everything else takes the default branch."
  end

  def test_integration_one_run_emits_a_full_sha_for_every_consumer
    status, shas, stderr = run_resolver(candidate: "accepted", repos: CONSUMER_REPOS, existing_branches: LADDER)
    assert status.success?, stderr

    assert_equal CONSUMER_REPOS.to_h { |r| [r, fake_sha(r, "accepted")] }, shas,
                 "the job output must map every consumer to the full 40-hex SHA of its rung"
  end

  def test_integration_an_unresolvable_commit_fails_the_run_rather_than_emitting_a_branch
    # An empty or non-SHA ref would silently turn back into a branch checkout per shard.
    status, shas, = run_resolver(candidate: "accepted", repos: CONSUMER_REPOS, existing_branches: LADDER,
                                 unresolvable: ["turf-monster"])

    refute status.success?, "a consumer whose commit cannot be resolved must fail consumer-refs"
    assert_nil shas, "no partial map may reach GITHUB_OUTPUT"
  end

  # ==== the RUNG is not enough — the COMMIT has to match too ===========================
  #
  # Everything above pins the two jobs to the same LADDER RUNG. It cannot pin them to the
  # same COMMIT: a branch name is a moving target, and the shards resolve it when the
  # matrix starts while the gate resolves it again after all four have finished.
  #
  # MEASURED (run 32495361932, 2026-08-21). Shards checked out hub `accepted` at 15:02:17,
  # this job at 15:06:17; hub PR #979 merged f9a440e5 at 15:04:07 adding two test files.
  # bin/rails-executed-set-check audited 482 committed files against receipts written over
  # 480 and called the two newcomers files that "executed NOTHING" — they had run green in
  # the hub's own lane minutes earlier and simply had not existed when the shards started.
  # The receipts' union was byte-identical to the lane's file set at f9a440e5^. A false
  # coverage hole reads exactly like a true one, so it reddened every engine PR based on
  # `accepted` and blocked #187 behind a hub change unrelated to it.

  def repoint_step
    @repoint_step ||= steps_for("hub-executed-set")
                      .find { |s| s["name"].to_s.include?("Stand this checkout on the commit") }
  end

  def test_unit_the_gate_checkout_keeps_full_depth_so_the_repoint_can_reach_the_shards_commit
    gate = checkout_steps.find do |job, s|
      job == "hub-executed-set" && s.dig("with", "repository").to_s.end_with?("mcritchie-studio")
    end
    refute_nil gate, "the executed-set gate no longer checks the hub out"

    assert_equal 0, gate.last.dig("with", "fetch-depth"),
                 "the gate stands itself on the commit the SHARDS ran, and that commit is normally " \
                 "an ANCESTOR of the branch tip. A depth-1 fetch does not contain it, so the " \
                 "re-point would silently no-op and the gate would go back to auditing two trees " \
                 "as though they were one."
  end

  def test_unit_the_gate_stands_on_the_shards_commit_between_the_receipts_and_the_audit
    names = steps_for("hub-executed-set").map { |s| s["name"].to_s }
    download = names.index { |n| n.include?("Download every shard's receipt") }
    repoint  = names.index { |n| n.include?("Stand this checkout on the commit") }
    audit    = names.index { |n| n.include?("Assert the lane executed") }

    refute_nil repoint, "the gate no longer re-points at the commit its receipts name, so a hub " \
                        "merge landing mid-run puts it back to auditing a NEWER tree than the " \
                        "shards ran — the 2026-08-21 false 'executed NOTHING' verdict"
    refute_nil download
    refute_nil audit

    assert_operator download, :<, repoint,
                    "the commit is READ OUT of the receipts, so they must be downloaded first"
    assert_operator repoint, :<, audit,
                    "re-pointing after the audit would change nothing the audit saw"
  end

  # ==== [integration] the shipped resolver, executed ===================================

  # The ruby the workflow really runs, lifted out of the step rather than restated — a
  # restated copy proves only that the copy works.
  def repoint_resolver
    @repoint_resolver ||= repoint_step.fetch("run")[/ruby -rjson -e '(.*?)'\s*\)"/m, 1] ||
                          flunk("could not lift the resolver out of the re-point step")
  end

  def resolve_commit(receipt_commits)
    Dir.mktmpdir do |dir|
      reports = File.join(dir, "rails-reports")
      FileUtils.mkdir_p(reports)
      receipt_commits.each_with_index do |sha, index|
        payload = { "shard" => (index + 1).to_s, "shards" => receipt_commits.length.to_s,
                    "files" => {}, "totals" => {}, "unattributed" => [] }
        payload["commit"] = sha unless sha.nil?
        File.write(File.join(reports, "rails-report-shard-#{index + 1}.json"), JSON.generate(payload))
      end

      out, = Open3.capture2("ruby", "-rjson", "-e", repoint_resolver, chdir: dir)
      out
    end
  end

  def test_integration_the_shipped_resolver_names_a_commit_only_when_the_shards_agree
    old = "f4d28230f7d075ffb40565474c2330dedbf959fe"
    new = "f9a440e58d01811ac63aaa7e207c10b43b050919"

    assert_equal old, resolve_commit([ old ] * 4),
                 "four shards agreeing on a commit is the ordinary case, and the whole point: the " \
                 "gate audits THAT tree, so the expected set and the executed set describe one tree"

    assert_equal "", resolve_commit([ old, old, new, old ]),
                 "shards that STRADDLED a merge must not elect a winner here. Their union is a set " \
                 "no single tree ever held; the hub's gate refuses it by name, and this step must " \
                 "leave the tip alone rather than pick the majority and manufacture a green"

    assert_equal "", resolve_commit([ nil ] * 4),
                 "receipts from a hub older than the commit field name nothing, and this lane must " \
                 "degrade to auditing the tip exactly as it always did — never fail the checkout"

    assert_equal "", resolve_commit([]),
                 "no receipts at all is the condition the executed-set gate exists to refuse. This " \
                 "step must hand that verdict to the gate, not pre-empt it"
  end
end
