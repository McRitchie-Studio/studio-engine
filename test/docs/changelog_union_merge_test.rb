# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "changelog_structure_test"

# [integration] `merge=union` on CHANGELOG.md, against real git (no network). The merges
# run over this repo's own .gitattributes and CHANGELOG.md, and the verdict on each result
# is ChangelogStructureTest's own rules. `roll` writes the shape `bin/release prepare`
# writes (Release::Changelog.roll in mcritchie-studio, tested there).
class ChangelogUnionMergeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil }.freeze
  EMPTY_BUCKET = /(^## Unreleased\n).*?(?=^## )/m

  def base = @base ||= File.read(File.join(ROOT, "CHANGELOG.md")).sub(EMPTY_BUCKET, "\\1\n")

  def entry(text, subsection, bullet)
    text.sub("## Unreleased\n\n", "## Unreleased\n\n### #{subsection}\n\n- #{bullet}\n\n")
  end

  def roll(text, version = "9999.0.0")
    text.sub("## Unreleased\n\n", "## Unreleased\n\n## #{version} — 2026-11-04\n\n")
  end

  def unreleased_bucket(text) = text[/^## Unreleased\n(.*?)^## /m, 1]

  def git(dir, *args)
    Open3.capture2e(GIT_ENV, "git", "-C", dir, *args)
  end

  def git!(dir, *args)
    out, status = git(dir, *args)
    assert status.success?, "git #{args.join(' ')} failed:\n#{out}"
    out
  end

  # `accepted` at `ancestor`, a branch that wrote `branch`, then `accepted` writes
  # `upstream` and merges the branch. Returns [clean?, the merged file].
  def merge(ancestor:, upstream:, branch:, attributes: File.read(File.join(ROOT, ".gitattributes")))
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CHANGELOG.md")
      Open3.capture2e(GIT_ENV, "git", "init", "--quiet", "-b", "accepted", dir)
      git!(dir, "config", "user.email", "test@example.com")
      git!(dir, "config", "user.name", "Test")
      git!(dir, "config", "commit.gpgsign", "false")
      File.write(File.join(dir, ".gitattributes"), attributes)
      File.write(path, ancestor)
      git!(dir, "add", ".")
      git!(dir, "commit", "--quiet", "-m", "base")

      git!(dir, "checkout", "--quiet", "-b", "feat")
      File.write(path, branch)
      git!(dir, "commit", "--quiet", "-am", "feat")

      git!(dir, "checkout", "--quiet", "accepted")
      File.write(path, upstream)
      git!(dir, "commit", "--quiet", "-am", "upstream")

      _, status = git(dir, "merge", "--no-edit", "feat")
      [status.success?, File.read(path)]
    end
  end

  def assert_shape(text)
    ChangelogStructureTest::SHAPE_RULES.each do |rule|
      guard = ChangelogStructureTest.new(rule.to_s)
      guard.read_changelog(text)
      guard.public_send(rule)
    end
  end

  def test_the_repo_merges_its_changelog_with_union
    out, status = git(ROOT, "check-attr", "merge", "--", "CHANGELOG.md")
    assert status.success?, out
    assert_equal "CHANGELOG.md: merge: union\n", out
  end

  # THE CONTROL. Without the attribute this same pair conflicts, so the tests below are
  # measuring the attribute and not a merge that was always clean.
  def test_control_two_prs_conflict_without_the_attribute
    clean, = merge(ancestor: base, upstream: entry(base, "Added", "first PR"),
                   branch: entry(base, "Added", "second PR"), attributes: "")

    refute clean
  end

  def test_two_prs_in_one_subsection_merge_clean_and_keep_both_entries
    clean, merged = merge(ancestor: base, upstream: entry(base, "Added", "first PR"),
                          branch: entry(base, "Added", "second PR"))

    assert clean
    refute_match(/^[<=>]{7}/, merged)
    assert_equal "\n### Added\n\n- first PR\n- second PR\n\n", unreleased_bucket(merged)
    assert_shape merged
  end

  def test_two_prs_in_different_subsections_merge_clean_and_keep_both_entries
    clean, merged = merge(ancestor: base, upstream: entry(base, "Added", "first PR"),
                          branch: entry(base, "Fixed", "second PR"))

    assert clean
    bucket = unreleased_bucket(merged)
    ["### Added", "- first PR", "### Fixed", "- second PR"].each { |line| assert_includes bucket, line }
    assert_shape merged
  end

  # The roll moves whatever union left in the bucket, and leaves the bucket empty.
  def test_a_union_merged_bucket_rolls_whole
    clean, merged = merge(ancestor: base, upstream: entry(base, "Added", "first PR"),
                          branch: entry(base, "Fixed", "second PR"))
    assert clean

    rolled = roll(merged)

    assert_equal "\n", unreleased_bucket(rolled)
    section = rolled[/^## 9999\.0\.0 — 2026-11-04\n(.*?)^## /m, 1]
    ["- first PR", "- second PR"].each { |line| assert_includes section, line }
    assert_shape rolled
  end

  # THE COST OF UNION. A branch forked before a roll no longer conflicts when it merges
  # after one: its entry lands beneath the rolled heading. The structure guard goes red.
  def test_a_new_subsection_merged_across_a_roll_reddens_the_structure_guard
    clean, merged = merge(ancestor: base, upstream: roll(base), branch: entry(base, "Fixed", "stale branch"))

    assert clean, "union should have merged this; it is why the guard exists"
    assert_equal "\n", unreleased_bucket(merged)
    failure = assert_raises(Minitest::Assertion) { assert_shape merged }
    assert_match(/a merge across a roll/, failure.message)
  end

  def test_the_real_file_passes_the_new_rule_with_its_bucket_empty
    assert_shape base
  end
end
