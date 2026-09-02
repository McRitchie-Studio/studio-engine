# frozen_string_literal: true

# Guard for bin/gem-drift-check — the gate that fails when THIS ENGINE's lock
# resolves a tracked gem OLDER than a consumer's.
#
# WHY THE GATE EXISTS, in one line: studio-engine's lock sat on solana-studio
# 0.5.3 for four patch releases while both consumers shipped 0.5.7, and nothing
# could have been red — engine CI installs with `bundler-cache: true`, so it
# never resolves fresh. Full reasoning lives in the script's own header.
#
# WHY THIS FILE EXISTS. The gate itself runs only inside consumer-ci.yml, where
# two repos' lockfiles are on disk at once. That is exactly the place a bug in
# it would be most expensive and least observable, so the ARITHMETIC is proved
# here against fixtures, on every local cert, with no checkout of anything.
#
# The decoys are the point. A Gemfile.lock names a gem THREE times at three
# indents — the resolved spec (4), a sub-dependency of the gem above it (6), and
# the DEPENDENCIES constraint (2). Reading the wrong one reports a RANGE or a
# NEIGHBOUR as "the resolved version", which is the same species of defect the
# gate was written to catch.
#
# Run directly:
#   ruby -Itest test/lib/gem_drift_check_test.rb
#
# One tier (library shape):
#   [unit] the drift gate's arithmetic, parse and wiring, read from the real script.

# bundler/setup FIRST — the engine's suite guard refuses a test file that reaches
# minitest before the bundle is set up.
require "bundler/setup"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class GemDriftCheckTest < Minitest::Test
  ROOT     = File.expand_path("../..", __dir__)
  SCRIPT   = File.join(ROOT, "bin/gem-drift-check")
  WORKFLOW = File.join(ROOT, ".github/workflows/consumer-ci.yml")

  # A minimal but STRUCTURALLY REAL lock: the three indents a real lock uses for
  # one gem name, so every test below is run against the decoys, not around them.
  #   6 spaces — a sub-dependency of the spec above it
  #   4 spaces — the resolved spec (the only line that answers the question)
  #   2 spaces — the DEPENDENCIES constraint (a range, not a resolution)
  def lock(solana: "0.5.7", decoy_dependency: ">= 0.0.1")
    <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          ed25519 (1.3.0)
          some-wrapper (2.0.0)
            solana-studio (#{decoy_dependency})
      #{solana ? "    solana-studio (#{solana})\n      ed25519 (~> 1.3)" : "    ed25519 (1.3.0)"}

      PLATFORMS
        arm64-darwin-25

      DEPENDENCIES
        solana-studio (#{decoy_dependency})

      BUNDLED WITH
         2.6.9
    LOCK
  end

  def run_check(engine_body, consumers)
    Dir.mktmpdir do |dir|
      engine_path = File.join(dir, "engine.lock")
      File.write(engine_path, engine_body)
      args = consumers.map do |label, body|
        path = File.join(dir, "#{label}.lock")
        File.write(path, body)
        "#{label}=#{path}"
      end
      out, err, status = Open3.capture3("ruby", SCRIPT, engine_path, *args)
      [out, err, status.exitstatus]
    end
  end

  # --- the arithmetic -------------------------------------------------------

  def test_the_engine_trailing_a_consumer_fails_and_names_the_remedy
    out, err, code = run_check(lock(solana: "0.5.3"), { "turf_monster" => lock(solana: "0.5.7") })

    assert_equal 1, code, "engine behind a consumer must FAIL — this is the whole gate"
    assert_includes out, "engine 0.5.3 TRAILS turf_monster 0.5.7"
    assert_includes err, "bundle update solana-studio",
      "a gate that fails without naming its one-command remedy costs the next reader the finding"
  end

  def test_the_engine_level_with_its_consumers_passes
    _out, _err, code = run_check(lock(solana: "0.5.7"), { "turf_monster" => lock(solana: "0.5.7") })
    assert_equal 0, code
  end

  def test_the_engine_ahead_of_a_consumer_passes
    # DIRECTIONAL BY DESIGN. The engine is the producer and may legitimately test
    # against an unreleased gem; a consumer that lags is the consumer's business.
    # Without this the gate would redden engine PRs for a defect elsewhere.
    out, _err, code = run_check(lock(solana: "0.5.9"), { "turf_monster" => lock(solana: "0.5.7") })
    assert_equal 0, code
    assert_includes out, "engine 0.5.9 > turf_monster 0.5.7"
  end

  def test_one_consumer_behind_fails_even_when_another_is_level
    _out, err, code = run_check(
      lock(solana: "0.5.3"),
      { "mcritchie_industries" => lock(solana: nil), "turf_monster" => lock(solana: "0.5.7") }
    )
    assert_equal 1, code
    assert_includes err, "turf_monster 0.5.7"
  end

  # --- the parse, against its own decoys ------------------------------------

  def test_the_dependencies_constraint_is_not_read_as_the_resolution
    # The gate must read the 4-space SPEC, never the 2-space DEPENDENCIES range.
    # Here the constraint is a version that WOULD pass while the resolution fails,
    # so a parse reading the wrong line certifies the exact drift it guards.
    body = lock(solana: "0.5.3", decoy_dependency: ">= 9.9.9")
    _out, _err, code = run_check(body, { "turf_monster" => lock(solana: "0.5.7") })

    assert_equal 1, code,
      "reading the DEPENDENCIES range (>= 9.9.9) instead of the resolved 0.5.3 would pass here"
  end

  def test_a_lock_with_no_resolved_specs_is_a_broken_read_not_an_absence
    # A file that is not a lock (or a lock whose format moved) yields zero matches
    # for EVERY gem. Treated as "the consumer does not bundle it" that skips
    # silently forever, which is this codebase's most-found defect shape.
    _out, err, code = run_check(lock, { "turf_monster" => "not a lockfile at all\n" })
    assert_equal 65, code
    assert_includes err, "no resolved spec lines at all"
  end

  def test_a_consumer_that_bundles_no_tracked_gem_is_a_skip_not_a_failure
    # The BASE half of the split working as designed — mcritchie_industries
    # mounts this engine and bundles no solana-studio. The lane runs this check
    # per consumer, so a failure here would redden a lane about nothing.
    out, _err, code = run_check(lock, { "mcritchie_industries" => lock(solana: nil) })
    assert_equal 0, code
    assert_includes out, "bundles no solana-studio"
  end

  def test_an_engine_lock_missing_the_tracked_gem_fails_loudly
    # Not a skip: the tracked list would then be guarding nothing while still
    # reporting success.
    _out, err, code = run_check(lock(solana: nil), { "turf_monster" => lock(solana: "0.5.7") })
    assert_equal 1, code
    assert_includes err, "resolves no solana-studio at all"
  end

  def test_an_unreadable_lock_is_named_rather_than_skipped
    Dir.mktmpdir do |dir|
      engine = File.join(dir, "engine.lock")
      File.write(engine, lock)
      _out, err, status = Open3.capture3(
        "ruby", SCRIPT, engine, "turf_monster=#{File.join(dir, 'nope.lock')}"
      )
      assert_equal 65, status.exitstatus
      assert_includes err, "cannot read"
    end
  end

  def test_usage_errors_are_distinguishable_from_a_drift_failure
    _out, err, status = Open3.capture3("ruby", SCRIPT)
    assert_equal 64, status.exitstatus, "usage must not share an exit code with a real finding"
    assert_includes err, "usage:"

    Dir.mktmpdir do |dir|
      engine = File.join(dir, "engine.lock")
      File.write(engine, lock)
      _out, err2, status2 = Open3.capture3("ruby", SCRIPT, engine, "no-equals-sign")
      assert_equal 64, status2.exitstatus
      assert_includes err2, "<label>=<path>"
    end
  end

  # --- the wiring -----------------------------------------------------------

  def test_the_tracked_list_is_not_empty
    # Anti-vacuous floor, in step with bin/suite-guard's. An empty list makes
    # every run pass while comparing nothing.
    source = File.read(SCRIPT)
    tracked = source[/^TRACKED = %w\[([^\]]*)\]/, 1].to_s.split
    refute_empty tracked, "the gate must track at least one gem or it guards nothing"
    assert_includes tracked, "solana-studio",
      "solana-studio is the gem the style guide RENDERS and the suite asserts on"
  end

  def test_consumer_ci_actually_runs_the_gate
    # Without this the script is prose. It is the workflow, not this repo's
    # suite, that can compare two repos' locks — so the wiring IS the feature.
    workflow = YAML.safe_load_file(WORKFLOW, aliases: true)
    steps = workflow.dig("jobs", "consumer-tests", "steps")
    step = steps.find { |s| s["run"].to_s.include?("bin/gem-drift-check") }
    refute_nil step, "consumer-ci.yml must run bin/gem-drift-check or the gate never fires"

    run = step["run"]
    assert_includes run, "studio/Gemfile.lock",
      "the engine side must be the engine checkout's lock (checked out at studio/)"
    assert_includes run, "${{ matrix.consumer }}/Gemfile.lock",
      "the consumer side must be the consumer checkout's own lock"

    # The paths above are only right if the checkouts still land there. Read that
    # from the SAME workflow rather than trusting the comment.
    engine_checkout = steps.find { |s| s["name"] == "Checkout engine" }
    assert_equal "studio", engine_checkout.dig("with", "path"),
      "the gate's engine path tracks the engine checkout path"
    consumer_checkout = steps.find { |s| s["name"].to_s.start_with?("Checkout ${{ matrix.consumer }}") }
    assert_equal "${{ matrix.consumer }}", consumer_checkout.dig("with", "path"),
      "the gate's consumer path tracks the consumer checkout path"

    # It must run AFTER the consumer bundle install, or it reads a lock the lane
    # has not resolved against this engine commit yet.
    bundle_at = steps.index { |s| s["run"].to_s.include?("bundle install") }
    gate_at   = steps.index { |s| s["run"].to_s.include?("bin/gem-drift-check") }
    refute_nil bundle_at
    assert_operator gate_at, :>, bundle_at,
      "the gate must run after the consumer's bundle install"
  end
end
