# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require_relative "local_path_test"

# [unit] The engine's ES modules answer like the Ruby they mirror, and their
# node:test files pass.
#
# Two checks, both through node (required in this suite; engine-ci.yml sets it
# up for bin/release-check):
#   1. studio/local_path's isLocalPath agrees with Studio::LocalPath.local? on
#      every row of StudioLocalPathTest, so the browser and the server refuse
#      the same return paths.
#   2. every test/javascript/*.test.mjs passes. This is how the node:test files
#      run in the engine's lane: bin/suite-guard gates this Ruby file, so a
#      failing module test reddens bin/release-check.
class StudioLocalPathJsParityTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  MODULE = File.join(ROOT, "app/javascript/studio/local_path.js")

  def test_the_browser_rule_matches_the_server_rule_row_for_row
    rows = StudioLocalPathTest::LOCAL + StudioLocalPathTest::REJECTED.keys
    script = <<~JS
      const { readFileSync } = await import("node:fs")
      const source = readFileSync(#{MODULE.to_json}, "utf8")
      const { isLocalPath } = await import("data:text/javascript," + encodeURIComponent(source))
      const rows = JSON.parse(readFileSync(0, "utf8"))
      process.stdout.write(JSON.stringify(rows.map((row) => isLocalPath(row))))
    JS
    out, err, status = Open3.capture3("node", "--input-type=module", "-e", script, stdin_data: rows.to_json)
    assert status.success?, "node failed: #{err}"

    JSON.parse(out).zip(rows).each do |browser, path|
      assert_equal Studio::LocalPath.local?(path), browser,
                   "#{path.inspect}: the browser and the server disagree"
    end
  end

  def test_the_node_test_files_pass
    files = Dir[File.join(ROOT, "test/javascript/*.test.mjs")].sort
    refute_empty files, "no node:test files under test/javascript"

    out, status = Open3.capture2e("node", "--test", *files)
    assert status.success?, "node --test failed:\n#{out}"
    assert_match(/^# pass [1-9]/, out, "node --test ran no passing test:\n#{out}")
    assert_match(/^# fail 0$/, out)
  end
end
