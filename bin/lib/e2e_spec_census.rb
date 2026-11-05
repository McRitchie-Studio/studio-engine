# frozen_string_literal: true

# bin/lib/e2e_spec_census.rb — THE SPEC COUNT, computed from the committed e2e/ suite.
#
# The lane's arithmetic is `executed == committed specs`. That count used to be two
# hand-written numbers in config/e2e_lane.yml, which every spec add had to move. Two
# open PRs that each added a spec conflicted on them, and a botched merge once left a
# stale `total_specs`. They are computed here instead, so adding a spec moves nothing
# by hand. This is mcritchie-studio's census (its bin/lib/e2e_spec_census.rb), minus
# the quarantine, which this lane does not have. Both halves of the guard read it:
#
#   · bin/e2e-executed-set-check         the runtime gate: Playwright's own report must
#                                        show this many specs ran
#   · test/lib/e2e_lane_contract_test.rb the static guard: every committed spec is a bare
#                                        declaration, so the census is honest
#
# A SPEC is a bare `test(` or `it(` call at the start of a line. The title may sit on the
# next line, so the scan does not ask for it. The static guard refuses every modifier
# that could change which specs run, so a bare declaration is the whole set.
#
# THE GATE KEEPS THE SOURCE SCAN, ON PURPOSE. Playwright's own `--list` counts a `test(`
# written in a loop correctly, where this scan counts one, but `--list` is the RUNNER'S
# view: it honours `.only`, `testIgnore` and a narrowed `testDir`, the very ways a lane
# shrinks that the census exists to see past. So `--list` is only the author's
# cross-check (bin/e2e-census-check): where it disagrees with the scan, the gate will go
# red on CI.
#
# Stdlib only, like the gate that reads it.
module E2eSpecCensus
  SPEC_DECLARATION = /^\s*(?:test|it)\s*\(/

  # Playwright's summary line under `--list`: "Total: 267 tests in 107 files".
  LIST_TOTAL = /^Total: (?<tests>\d+) tests? in (?<files>\d+) files?$/

  # `lane_files` counts the files that declare at least one spec.
  Census = Struct.new(:total, :lane_files, keyword_init: true) do
    def executed = total
  end

  module_function

  # Comments are not code: `// test("x")` declares nothing. A string holding a
  # slash-star reads here as the start of a comment, so a spec file must not carry one
  # (e2e/booking_frame.spec.js says how it avoided a glob). The gate goes red if one does.
  def strip_comments(source)
    source.gsub(%r{/\*.*?\*/}m, "").gsub(%r{^\s*//.*$}, "")
  end

  def declarations(source)
    strip_comments(source).scan(SPEC_DECLARATION).size
  end

  def spec_files(e2e_dir)
    Dir.glob(File.join(e2e_dir, "**", "*.spec.js")).sort
  end

  def count(e2e_dir)
    counts = spec_files(e2e_dir).map { |path| declarations(File.read(path)) }
    Census.new(total: counts.sum, lane_files: counts.count(&:positive?))
  end

  # The Playwright runner for `root`: node_modules/.bin/playwright in `root` or the
  # nearest directory above it (a desk under .worktrees/ resolves the primary's, as
  # Node's own resolution does). nil when none is installed.
  def playwright_bin(root)
    dir = File.expand_path(root)
    loop do
      candidate = File.join(dir, "node_modules", ".bin", "playwright")
      return candidate if File.executable?(candidate)

      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end
  end

  # The census as Playwright lists it, or [nil, reason] when it cannot be listed.
  # Listing loads the config and the spec files, and starts no server and no browser.
  def listed(root, bin: playwright_bin(root))
    return [nil, "Playwright is not installed in or above #{root} (npm ci)"] unless bin

    require "open3"
    out, status = Open3.capture2e(bin, "test", "--list", chdir: root)
    total = out.match(LIST_TOTAL)
    unless status.success? && total
      return [nil, "`playwright test --list` did not list the suite: #{out.lines.last(3).join.strip}"]
    end

    [Census.new(total: total[:tests].to_i, lane_files: total[:files].to_i), nil]
  rescue SystemCallError => e
    [nil, "`playwright test --list` could not start: #{e.class}: #{e.message}"]
  end
end
