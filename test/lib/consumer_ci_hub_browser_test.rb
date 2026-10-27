# frozen_string_literal: true

# Guard for consumer-ci.yml's `hub-browser` job and its helper, bin/hub-e2e-subset.
#
# WHY. Engine PR #485 broke 41 hub Playwright tests ("Failed to resolve module specifier
# canvas-confetti") while every consumer Rails suite in consumer-ci.yml stayed green: no
# lane here opened a host's page in a browser. The `hub-browser` job now runs a listed
# subset of the hub's specs against this engine tree. A lane like that fails quietly in
# two ways, and this file pins both shut:
#
#   · it can run FEWER specs than it lists (a listed spec quarantined, skipped, renamed)
#     and Playwright still exits 0, so the helper audits the JSON receipt;
#   · it can drift off the engine tree (the path-gem swap dropped, the list unread, the
#     audit made conditional on success), so the wiring is read from the real workflow.
#
# Run directly:
#   ruby -Itest test/lib/consumer_ci_hub_browser_test.rb
#
# One tier here (backend shape):
#   [unit] the helper's list, missing-file and receipt arithmetic, run as a subprocess
#          against fixtures, and the job's wiring read from the shipped workflow.
# The [integration] tier is the PR's own consumer-ci run of the job.

require "bundler/setup"
require "minitest/autorun"
require "yaml"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

class ConsumerCiHubBrowserTest < Minitest::Test
  ROOT     = File.expand_path("../..", __dir__)
  SCRIPT   = File.join(ROOT, "bin/hub-e2e-subset")
  LIST     = File.join(ROOT, ".github/hub-e2e-subset.txt")
  WORKFLOW = File.join(ROOT, ".github/workflows/consumer-ci.yml")

  def run_script(*args)
    out, err, status = Open3.capture3("ruby", SCRIPT, *args)
    [out, err, status.success?]
  end

  def listed = File.readlines(LIST, chomp: true).map { |l| l.sub(/#.*/, "").strip }.reject(&:empty?)

  # A Playwright JSON report in the shape the json reporter writes: a suite per file
  # (named relative to testDir), nested describe suites, specs, tests, results.
  def report(files)
    {
      "suites" => files.map do |file, statuses|
        {
          "title" => file, "file" => file,
          "specs" => [],
          "suites" => [{
            "title" => "describe",
            "specs" => statuses.map.with_index do |st, i|
              { "title" => "t#{i}", "tests" => [{ "results" => st.nil? ? [] : [{ "status" => st }] }] }
            end
          }]
        }
      end
    }
  end

  def with_list(entries)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "list.txt")
      File.write(path, "# header\n\n" + entries.map { |e| "#{e}  # why\n" }.join)
      yield dir, path
    end
  end

  def audit(entries, files)
    with_list(entries) do |dir, list|
      rep = File.join(dir, "r.json")
      File.write(rep, JSON.dump(report(files)))
      run_script("audit", list, rep)
    end
  end

  # ==== the list ======================================================================

  def test_unit_the_list_names_hub_specs_once_each
    refute_empty listed, ".github/hub-e2e-subset.txt names no spec; the job would run nothing"
    assert_operator listed.length, :>=, 10, "the subset shrank below the layouts it exists to cover"
    assert_empty listed.reject { |l| l.match?(%r{\Ae2e/[a-z0-9_/]+\.spec\.js\z}) },
                 "every entry is a hub-relative e2e/<name>.spec.js path"
    assert_equal listed.uniq, listed, "a spec is listed twice"
  end

  # ==== paths ========================================================================

  def test_unit_paths_prints_the_list_when_the_hub_has_every_file
    with_list(%w[e2e/a.spec.js e2e/b.spec.js]) do |dir, list|
      FileUtils.mkdir_p(File.join(dir, "hub/e2e"))
      %w[a b].each { |n| File.write(File.join(dir, "hub/e2e/#{n}.spec.js"), "") }
      out, _err, ok = run_script("paths", list, File.join(dir, "hub"))
      assert ok
      assert_equal %w[e2e/a.spec.js e2e/b.spec.js], out.split("\n"), "comments and blanks are stripped"
    end
  end

  def test_unit_paths_fails_naming_a_spec_the_hub_no_longer_has
    with_list(%w[e2e/a.spec.js e2e/gone.spec.js]) do |dir, list|
      FileUtils.mkdir_p(File.join(dir, "hub/e2e"))
      File.write(File.join(dir, "hub/e2e/a.spec.js"), "")
      out, err, ok = run_script("paths", list, File.join(dir, "hub"))
      refute ok, "a renamed hub spec must fail the job, not shrink the set"
      assert_includes err, "e2e/gone.spec.js"
      assert_empty out, "nothing is handed to Playwright when the list is wrong"
    end
  end

  # ==== audit ========================================================================

  def test_unit_audit_is_green_when_every_listed_file_ran
    _out, err, ok = audit(%w[e2e/a.spec.js e2e/b.spec.js],
                          "a.spec.js" => %w[passed failed], "b.spec.js" => %w[passed], "other.spec.js" => %w[passed])
    assert ok, "a FAILED test still ran; Playwright's exit code owns pass/fail, the audit owns coverage. #{err}"
  end

  def test_unit_audit_is_red_when_a_listed_file_is_absent_from_the_receipt
    _out, err, ok = audit(%w[e2e/a.spec.js e2e/b.spec.js], "a.spec.js" => %w[passed])
    refute ok
    assert_includes err, "e2e/b.spec.js executed no test"
  end

  def test_unit_audit_is_red_when_a_listed_file_skipped_everything
    _out, err, ok = audit(%w[e2e/a.spec.js], "a.spec.js" => %w[skipped skipped])
    refute ok, "an all-skipped spec exits 0 in Playwright and covers nothing"
    assert_includes err, "executed no test (2 skipped)"
  end

  def test_unit_audit_is_red_when_a_listed_file_skipped_one
    _out, err, ok = audit(%w[e2e/a.spec.js], "a.spec.js" => ["passed", "skipped", nil])
    refute ok
    assert_includes err, "skipped 2 test(s)", "a test with no result never ran either"
  end

  def test_unit_audit_is_red_when_there_is_no_receipt
    with_list(%w[e2e/a.spec.js]) do |dir, list|
      _out, err, ok = run_script("audit", list, File.join(dir, "missing.json"))
      refute ok
      assert_includes err, "no receipt"
    end
  end

  # ==== triage (the E2E_LANE line) ===================================================

  # A receipt whose tests carry Playwright's own test-level verdict ("expected",
  # "unexpected", "flaky", "skipped"), as the json reporter writes it.
  def verdict_report(files, errors = [])
    {
      "errors" => errors,
      "suites" => files.map do |file, verdicts|
        { "title" => file, "file" => file, "specs" => [],
          "suites" => [{ "title" => "describe",
                         "specs" => verdicts.map.with_index do |v, i|
                           { "title" => "t#{i}", "tests" => [{ "status" => v, "results" => [{ "status" => { "unexpected" => "failed", "skipped" => "skipped" }.fetch(v, "passed") }] }] }
                         end }] }
      end
    }
  end

  def triage(entries, report: nil, hub_files: entries)
    with_list(entries) do |dir, list|
      hub = File.join(dir, "hub")
      hub_files.each do |rel|
        FileUtils.mkdir_p(File.dirname(File.join(hub, rel)))
        File.write(File.join(hub, rel), "")
      end
      FileUtils.mkdir_p(hub)
      rep = File.join(dir, "r.json")
      File.write(rep, report.is_a?(String) ? report : JSON.dump(report)) if report
      out, err, ok = run_script("triage", list, rep, hub)
      assert ok, "triage reports, it never gates: #{err}"
      assert_equal 1, out.lines.length, "the triage is ONE line: #{out}"
      out.strip
    end
  end

  def test_unit_triage_names_the_lane_and_every_failing_spec_file
    line = triage(%w[e2e/a.spec.js e2e/b.spec.js e2e/c.spec.js],
                  report: verdict_report("a.spec.js" => %w[expected unexpected], "b.spec.js" => %w[expected],
                                         "c.spec.js" => %w[unexpected unexpected]))
    assert line.start_with?("::error::E2E_LANE hub-browser RED"), line
    assert_includes line, "2 failing spec file(s): e2e/a.spec.js, e2e/c.spec.js"
    refute_includes line, "b.spec.js", "a green spec is not named"
  end

  def test_unit_triage_does_not_name_a_flaky_spec_that_passed_on_retry
    line = triage(%w[e2e/a.spec.js e2e/b.spec.js],
                  report: verdict_report("a.spec.js" => %w[flaky], "b.spec.js" => %w[unexpected]))
    assert_includes line, "1 failing spec file(s): e2e/b.spec.js"
  end

  def test_unit_triage_names_a_listed_spec_the_hub_renamed
    line = triage(%w[e2e/a.spec.js e2e/renamed.spec.js], hub_files: %w[e2e/a.spec.js])
    assert_includes line, "E2E_LANE hub-browser RED"
    assert_includes line, "missing from the hub checkout (renamed or deleted): e2e/renamed.spec.js"
  end

  def test_unit_triage_says_when_there_is_no_receipt
    assert_includes triage(%w[e2e/a.spec.js]), "no receipt"
  end

  def test_unit_triage_names_errors_outside_any_test
    line = triage(%w[e2e/a.spec.js],
                  report: verdict_report({ "a.spec.js" => %w[expected] },
                                         [{ "message" => "Error: Timed out waiting 120000ms from config.webServer.\nmore" }]))
    assert_includes line, "1 Playwright error(s) outside any test"
    assert_includes line, "config.webServer"
  end

  def test_unit_triage_names_what_the_coverage_audit_flagged
    line = triage(%w[e2e/a.spec.js e2e/b.spec.js],
                  report: verdict_report("a.spec.js" => %w[expected], "b.spec.js" => %w[skipped]))
    assert_includes line, "ran no test or skipped some: e2e/b.spec.js"
  end

  def test_unit_triage_survives_a_receipt_that_is_not_json
    assert_includes triage(%w[e2e/a.spec.js], report: "{ truncated"), "is not JSON"
  end

  # ==== the job's wiring =============================================================

  def job = YAML.safe_load_file(WORKFLOW, aliases: true).dig("jobs", "hub-browser")
  def steps = job.fetch("steps")
  def step(name_part) = steps.find { |s| s["name"].to_s.include?(name_part) } || flunk("no step named like #{name_part.inspect}")
  def index(name_part) = steps.index(step(name_part))

  def test_unit_the_job_runs_the_hub_on_this_engine_tree
    refute_nil job, "consumer-ci.yml lost its hub-browser job"
    assert_includes Array(job["needs"]), "consumer-refs"
    hub = steps.find { |s| s.dig("with", "repository") == "McRitchie-Studio/mcritchie-studio" }
    assert_includes hub.dig("with", "ref").to_s, "needs.consumer-refs.outputs.shas",
                    "the hub must be the same commit the Rails shards run"
    swap = step("Gemfile at this engine")
    assert_includes swap["run"], %(gem "studio-engine", path: "../studio"),
                    "without the path swap the job tests the hub's locked gem, not this tree"
    assert_includes step("engine's migrations")["run"], "db:schema:dump",
                    "the webServer's db:test:prepare reloads db/schema.rb; undumped, the engine's tables vanish"
  end

  def test_unit_the_run_takes_exactly_the_resolved_list
    resolve = step("Resolve the hub spec subset")["run"]
    assert_includes resolve, "hub-e2e-subset paths studio/.github/hub-e2e-subset.txt"
    assert_operator index("Resolve the hub spec subset"), :<, index("Install system packages"),
                    "the list resolves before the slow setup, so a renamed spec fails in seconds"

    run = step("Run the hub browser subset")["run"]
    assert_includes run, "$(cat ../hub-e2e-subset.list)"
    assert_includes run, "--grep-invert @quarantine"
    assert_match(/--reporter=\S*json/, run, "the json reporter writes the receipt the audit reads")
    assert_includes step("Run the hub browser subset").dig("env", "PLAYWRIGHT_JSON_OUTPUT_NAME").to_s, "hub-e2e-report.json"
    refute_match(/--(grep|shard|last-failed|only-changed)\b(?!-invert)/, run,
                 "a flag that shrinks the set would hide the specs the list names")
  end

  def test_unit_the_audit_runs_on_red_runs_too
    audit = step("Audit the receipt")
    assert_includes audit["if"].to_s, "always()",
                    "on success() alone a red run skips the audit, and a run that skipped specs AND failed reads the same as one that failed"
    assert_includes audit["run"], "hub-e2e-subset audit studio/.github/hub-e2e-subset.txt hub-e2e-report.json"
  end

  def test_unit_a_red_lane_prints_the_triage_line
    triage = step("E2E_LANE triage")
    cond = triage["if"].to_s
    assert_includes cond, "failure()", "on success() alone the triage step never runs on the red it exists for"
    %w[subset playwright audit].each do |id|
      assert_includes cond, "steps.#{id}.outcome == 'failure'", "a red at step #{id} must print the line"
      assert_equal 1, steps.count { |s| s["id"] == id }, "the triage condition names step id #{id}"
    end
    assert_includes triage["run"],
                    "hub-e2e-subset triage studio/.github/hub-e2e-subset.txt hub-e2e-report.json mcritchie_studio"
    assert_operator index("E2E_LANE triage"), :>, index("Audit the receipt"), "triage reads the audit's verdict too"
  end
end
