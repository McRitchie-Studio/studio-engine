# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../../bin/lib/e2e_spec_census"

# [unit] The census, and [integration] the two scripts that read it, run as processes
# over the real tree: bin/e2e-executed-set-check and bin/e2e-census-check.
class E2eSpecCensusTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GATE = File.join(ROOT, "bin", "e2e-executed-set-check")
  CENSUS_CHECK = File.join(ROOT, "bin", "e2e-census-check")

  def with_specs(files)
    Dir.mktmpdir do |dir|
      files.each do |name, source|
        path = File.join(dir, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
      end
      yield dir
    end
  end

  def real_total = E2eSpecCensus.count(File.join(ROOT, "e2e")).total

  # ---- the count ----------------------------------------------------------------

  def test_unit_it_counts_bare_declarations_across_nested_files
    with_specs("a.spec.js" => %(test("one", async () => {});\n  test("two", async () => {});\n),
               "nested/b.spec.js" => %(it("three", async () => {});\n),
               "helpers.js" => %(test("not a spec file", async () => {});\n)) do |dir|
      census = E2eSpecCensus.count(dir)

      assert_equal 3, census.total
      assert_equal 3, census.executed
      assert_equal 2, census.lane_files
    end
  end

  # An engine spec may break its long title onto the next line. A scan that asked for the
  # title on the `test(` line, as the hub's does, would miss it.
  def test_unit_it_counts_a_title_on_the_next_line
    assert_equal 1, E2eSpecCensus.declarations(%(test(\n  "a long title",\n  async () => {}\n);\n))
  end

  def test_unit_comments_declare_nothing
    source = <<~JS
      // test("a line comment", async () => {});
      /*
      test("a block comment", async () => {});
      */
      test("the real one", async () => {});
    JS

    assert_equal 1, E2eSpecCensus.declarations(source)
  end

  def test_unit_hooks_and_groups_are_not_specs
    source = <<~JS
      test.use({ viewport: { width: 390, height: 800 } });
      test.beforeEach(async () => {});
      test.describe("a group", () => {});
      await contest(page);
    JS

    assert_equal 0, E2eSpecCensus.declarations(source)
  end

  def test_unit_a_file_with_no_declaration_is_not_a_lane_file
    with_specs("looped.spec.js" => %(for (const w of [1, 2]) { test(`at ${w}`, async () => {}); }\n)) do |dir|
      assert_equal 0, E2eSpecCensus.count(dir).lane_files
    end
  end

  # ---- the runtime gate, as CI runs it ------------------------------------------

  def report(executed:, skipped: 0)
    tests = Array.new(executed) { |i| { "title" => "spec #{i}", "tests" => [{ "status" => "expected" }] } } +
            Array.new(skipped) { |i| { "title" => "gone #{i}", "tests" => [{ "status" => "skipped" }] } }
    { "config" => {}, "stats" => { "expected" => executed, "skipped" => skipped },
      "suites" => [{ "title" => "lab", "specs" => tests }] }
  end

  def run_gate(*reports)
    Dir.mktmpdir do |dir|
      reports.each_with_index { |doc, i| File.write(File.join(dir, "#{i}.json"), JSON.generate(doc)) }
      out, status = Open3.capture2e(RbConfig.ruby, GATE, dir)
      [status.exitstatus, out]
    end
  end

  def test_integration_the_gate_passes_a_receipt_that_matches_the_census
    code, out = run_gate(report(executed: real_total))

    assert_equal 0, code, out
    assert_match(/GREEN/, out)
    assert_match(/#{real_total} executed/, out)
  end

  def test_integration_the_gate_refuses_one_spec_fewer_than_the_census
    code, out = run_gate(report(executed: real_total - 1))

    assert_equal 1, code, out
    assert_match(/1 FEWER than the census/, out)
  end

  def test_integration_the_gate_refuses_one_spec_more_than_the_census
    code, out = run_gate(report(executed: real_total + 1))

    assert_equal 1, code, out
    assert_match(/1 MORE than the census/, out)
  end

  def test_integration_the_gate_refuses_a_skip_even_when_the_count_holds
    code, out = run_gate(report(executed: real_total, skipped: 1))

    assert_equal 1, code, out
    assert_match(/SKIPPED AT RUNTIME/, out)
  end

  def test_integration_the_gate_refuses_no_receipt_at_all
    code, out = run_gate

    assert_equal 1, code, out
    assert_match(/no Playwright JSON reports/, out)
  end

  # ---- the author's cross-check -------------------------------------------------

  def run_census_check(listing:, exit_code: 0)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "playwright")
      File.write(bin, "#!/bin/sh\nprintf '%s\\n' #{listing.inspect}\nexit #{exit_code}\n")
      File.chmod(0o755, bin)
      out, status = Open3.capture2e({ "E2E_CENSUS_PLAYWRIGHT_BIN" => bin }, RbConfig.ruby, CENSUS_CHECK)
      [status.exitstatus, out]
    end
  end

  def test_integration_the_check_is_green_when_playwright_lists_the_census
    code, out = run_census_check(listing: "Total: #{real_total} tests in 75 files")

    assert_equal 0, code, out
    assert_match(/E2E CENSUS: GREEN/, out)
  end

  def test_integration_the_check_is_red_on_a_spec_written_in_a_loop
    code, out = run_census_check(listing: "Total: #{real_total + 1} tests in 75 files")

    assert_equal 1, code, out
    assert_match(/E2E CENSUS: RED/, out)
    assert_match(/inside a loop/, out)
  end

  def test_integration_a_check_it_could_not_run_says_so
    code, out = run_census_check(listing: "SyntaxError in e2e/a.spec.js", exit_code: 1)

    assert_equal 0, code, out
    assert_match(/NOT CHECKED/, out)
    assert_match(/#{real_total} spec\(s\)/, out)
  end
end
