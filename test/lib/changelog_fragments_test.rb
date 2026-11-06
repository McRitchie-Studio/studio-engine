# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../../bin/lib/changelog_fragments"
require_relative "../docs/changelog_structure_test"

# Guard for changelog fragments (bin/lib/changelog_fragments.rb, bin/changelog-compile,
# bin/changelog-check). Two tiers (library shape):
#
#   [unit]        the name rule, the body rules, the compile transform and the PR rules,
#                 run as pure functions over fixtures.
#   [integration] real git, no network: two PRs that each add a fragment merge with no
#                 merge driver (the case GitHub's mergeability check sees), the compiler
#                 rewrites a real tree and deletes what it compiled, and the PR check runs
#                 end to end over real commits.
#
# Run directly:
#   ruby -Itest test/lib/changelog_fragments_test.rb
class ChangelogFragmentsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil }.freeze
  F = ChangelogFragments

  CHANGELOG = <<~MD
    # Changelog

    Preamble.

    ## Unreleased

    ## 1.2.0 — 2026-11-01

    ### Fixed

    - Old fix.
  MD

  def frags(files)
    fragments, errors = F.build(files)
    assert_empty errors
    fragments
  end

  # ---- [unit] names and bodies ----------------------------------------------

  def test_unit_parse_name_reads_slug_and_kind
    assert_equal %w[my-task Added], F.parse_name("my-task.added.md")
    assert_equal %w[x1 Security], F.parse_name("x1.security.md")
    assert_nil F.parse_name("my-task.fixd.md")
    assert_nil F.parse_name("My-Task.added.md")
    assert_nil F.parse_name("my-task.added.txt")
    assert_nil F.parse_name("my--task.added.md")
  end

  def test_unit_build_ignores_the_readme_and_refuses_a_stray_name
    fragments, errors = F.build("README.md" => "# Notes\n\n## Why\n", "a.fixd.md" => "- x\n", "b.fixed.md" => "- y\n")
    assert_equal ["b.fixed.md"], fragments.map(&:name)
    assert_equal 1, errors.size
    assert_match(/a\.fixd\.md: not a fragment name/, errors.first)
  end

  def test_unit_build_refuses_an_empty_body_and_a_heading
    _, errors = F.build("a.added.md" => "\n  \n", "b.added.md" => "### Added\n\n- y\n", "c.added.md" => "## 1.0.0\n- z\n")
    assert_equal 3, errors.size
    assert_match(/a\.added\.md: the fragment is empty/, errors[0])
    assert_match(/b\.added\.md:1: a fragment carries no/, errors[1])
    assert_match(/c\.added\.md:1: a fragment carries no/, errors[2])
  end

  def test_unit_a_heading_inside_a_fence_is_body_text
    body = "- Writes:\n\n  ```text\n  ## Unreleased\n  ```\n"
    fragments = frags("a.added.md" => body)
    assert_equal 1, fragments.size
    _, errors = F.build("b.added.md" => "- x\n\n```\n## open\n")
    assert(errors.any? { |e| e.include?("unterminated fenced code block") }, errors.inspect)
  end

  # ---- [unit] compile ---------------------------------------------------------

  def test_unit_compile_orders_subsections_by_kind_not_by_name
    out = F.compile(CHANGELOG, frags("aaa.fixed.md" => "- A fix.\n", "zzz.added.md" => "- A feature.\n",
                                     "mmm.deprecated.md" => "- A deprecation.\n"))
    bucket = F.unreleased_section(out)
    assert_equal <<~MD, bucket
      ## Unreleased

      ### Added

      - A feature.

      ### Deprecated

      - A deprecation.

      ### Fixed

      - A fix.
    MD
    assert_includes out, "- A fix.\n\n## 1.2.0 — 2026-11-01\n\n### Fixed\n\n- Old fix.\n"
  end

  def test_unit_compile_keeps_file_name_order_within_a_kind
    out = F.compile(CHANGELOG, frags("b-task.changed.md" => "- Second.\n", "a-task.changed.md" => "- First.\n"))
    assert_includes out, "### Changed\n\n- First.\n- Second.\n"
  end

  def test_unit_compile_merges_into_an_existing_bucket
    text = CHANGELOG.sub("## Unreleased\n", "## Unreleased\n\nA note.\n\n### Notes\n\n- Odd.\n\n### Changed\n\n- Hand entry.\n")
    out = F.compile(text, frags("x.changed.md" => "- Fragment.\n", "y.added.md" => "- New.\n"))
    assert_equal <<~MD, F.unreleased_section(out)
      ## Unreleased

      A note.

      ### Added

      - New.

      ### Changed

      - Hand entry.
      - Fragment.

      ### Notes

      - Odd.
    MD
  end

  def test_unit_compile_does_not_cut_on_a_heading_inside_a_fence
    text = CHANGELOG.sub("## Unreleased\n", "## Unreleased\n\n### Changed\n\n- Shows:\n\n  ```text\n  ### Added\n  ## 9.9.9\n  ```\n")
    out = F.compile(text, frags("x.changed.md" => "- Fragment.\n"))
    assert_includes out, "  ### Added\n  ## 9.9.9\n  ```\n- Fragment.\n\n## 1.2.0"
    refute_match(/^### Added$/, out)
  end

  def test_unit_compile_with_a_last_section_bucket
    out = F.compile("# Changelog\n\n## Unreleased\n", frags("x.fixed.md" => "- Fix.\n"))
    assert_equal "# Changelog\n\n## Unreleased\n\n### Fixed\n\n- Fix.\n", out
  end

  def test_unit_compile_refuses_a_file_it_cannot_fold_into
    one = frags("x.fixed.md" => "- Fix.\n")
    assert_raises(F::Error) { F.compile("# Changelog\n\n## 1.0.0 — 2026-01-01\n", one) }
    assert_raises(F::Error) { F.compile("## Unreleased\n\n## Unreleased\n", one) }
    assert_raises(F::Error) { F.compile("## 1.0.0 — 2026-01-01\n\n## Unreleased\n", one) }
  end

  # The compiled real file still passes every rule the structure guard holds it to.
  def test_unit_compiled_real_changelog_keeps_its_shape
    text = File.read(File.join(ROOT, "CHANGELOG.md"))
    out = F.compile(text, frags("a.added.md" => "- One.\n", "b.fixed.md" => "- Two.\n  More.\n"))
    ChangelogStructureTest::SHAPE_RULES.each do |rule|
      guard = ChangelogStructureTest.new(rule.to_s)
      guard.read_changelog(out)
      guard.public_send(rule)
    end
    assert_equal text.lines.size + 9, out.lines.size, "only the two subsections and their spacer are new"
  end

  # Every file in the repo's own changelog.d/ is a valid fragment or the README.
  def test_unit_the_repo_fragments_are_well_formed
    files = F.load_dir(ROOT)
    assert_includes files.keys, "README.md", "changelog.d/README.md documents the format"
    _, errors = F.build(files)
    assert_empty errors
  end

  # ---- [unit] the PR rules ----------------------------------------------------

  def pr(changes, head: CHANGELOG, base: CHANGELOG)
    F.pr_errors(changes, base_changelog: base, head_changelog: head)
  end

  def test_unit_pr_shipping_code_needs_a_fragment
    assert_equal 1, pr([%w[M app/views/studio/_x.html.erb]]).size
    assert_match(/adds no changelog\.d/, pr([%w[M lib/studio.rb]]).first)
    assert_empty pr([%w[M lib/studio.rb], %w[A changelog.d/t.fixed.md]])
    assert_empty pr([%w[M studio-engine.gemspec], %w[M changelog.d/t.fixed.md]])
    assert_equal 1, pr([%w[M lib/studio.rb], %w[D changelog.d/t.fixed.md]]).size, "a deleted fragment is not one"
    assert_equal 1, pr([%w[M lib/studio.rb], %w[A changelog.d/README.md]]).size, "the README is not a fragment"
  end

  def test_unit_pr_that_ships_nothing_needs_no_fragment
    assert_empty pr([%w[M test/lib/x_test.rb], %w[M docs/RELEASE.md], %w[M Gemfile.lock], %w[M bin/release-check]])
  end

  def test_unit_pr_adding_to_unreleased_is_refused
    head = CHANGELOG.sub("## Unreleased\n", "## Unreleased\n\n### Fixed\n\n- Hand entry.\n")
    errors = pr([%w[M CHANGELOG.md], %w[A changelog.d/t.fixed.md]], head: head)
    assert_equal 1, errors.size
    assert_match(/adds 2 line\(s\) under '## Unreleased'/, errors.first)
  end

  def test_unit_pr_moving_lines_out_of_unreleased_is_allowed
    base = CHANGELOG.sub("## Unreleased\n", "## Unreleased\n\n### Fixed\n\n- Stranded.\n")
    assert_empty pr([%w[M CHANGELOG.md]], base: base)
  end

  def test_unit_the_release_version_commit_is_exempt
    head = CHANGELOG.sub("## Unreleased\n", "## Unreleased\n\n### Fixed\n\n- Compiled.\n")
    assert_empty pr([%w[M lib/studio/version.rb], %w[M CHANGELOG.md], %w[D changelog.d/t.fixed.md]], head: head)
  end

  # ---- [integration] real git -------------------------------------------------

  def git(dir, *args) = Open3.capture2e(GIT_ENV, "git", "-C", dir, *args)

  def git!(dir, *args)
    out, status = git(dir, *args)
    assert status.success?, "git #{args.join(' ')} failed:\n#{out}"
    out
  end

  def repo
    Dir.mktmpdir do |dir|
      Open3.capture2e(GIT_ENV, "git", "init", "--quiet", "-b", "accepted", dir)
      git!(dir, "config", "user.email", "test@example.com")
      git!(dir, "config", "user.name", "Test")
      git!(dir, "config", "commit.gpgsign", "false")
      FileUtils.mkdir_p(File.join(dir, "changelog.d"))
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "CHANGELOG.md"), CHANGELOG)
      File.write(File.join(dir, "changelog.d/README.md"), "# Fragments\n")
      File.write(File.join(dir, "lib/a.rb"), "A = 1\n")
      git!(dir, "add", ".")
      git!(dir, "commit", "--quiet", "-m", "base")
      yield dir
    end
  end

  def commit_on(dir, branch, files, from: "accepted")
    git!(dir, "checkout", "--quiet", "-B", branch, from)
    files.each { |path, body| File.write(File.join(dir, path), body) }
    git!(dir, "add", ".")
    git!(dir, "commit", "--quiet", "-m", branch)
  end

  # Without any merge driver (GitHub's view): two fragment PRs merge clean; the old
  # way, two Unreleased edits, conflicts. The second half proves the first can fail.
  def test_integration_two_fragment_prs_merge_without_conflict
    repo do |dir|
      File.write(File.join(dir, ".git/info/attributes"), "* merge=text\n")
      commit_on(dir, "one", { "changelog.d/one.added.md" => "- One.\n" })
      commit_on(dir, "two", { "changelog.d/two.fixed.md" => "- Two.\n" })
      _, status = git(dir, "merge-tree", "--write-tree", "one", "two")
      assert status.success?, "two fragment PRs must merge clean"

      commit_on(dir, "old-one", { "CHANGELOG.md" => CHANGELOG.sub("## Unreleased\n", "## Unreleased\n\n### Added\n\n- One.\n") })
      commit_on(dir, "old-two", { "CHANGELOG.md" => CHANGELOG.sub("## Unreleased\n", "## Unreleased\n\n### Fixed\n\n- Two.\n") })
      out, status = git(dir, "merge-tree", "--write-tree", "old-one", "old-two")
      refute status.success?, "control: two Unreleased edits should conflict without union\n#{out}"
    end
  end

  def run_bin(name, *args)
    Open3.capture3(GIT_ENV, RbConfig.ruby, File.join(ROOT, "bin", name), *args)
  end

  def test_integration_compile_rewrites_the_tree_and_deletes_the_fragments
    repo do |dir|
      File.write(File.join(dir, "changelog.d/x.fixed.md"), "- Fix.\n")
      File.write(File.join(dir, "changelog.d/y.added.md"), "- Add.\n")

      out, err, status = run_bin("changelog-compile", "--dry-run", "--root", dir)
      assert status.success?, err
      assert_includes out, "DRY RUN — would compile 2 fragment(s)"
      assert_includes out, "## Unreleased\n\n### Added\n\n- Add.\n\n### Fixed\n\n- Fix.\n"
      assert_equal CHANGELOG, File.read(File.join(dir, "CHANGELOG.md")), "a dry run writes nothing"
      assert File.exist?(File.join(dir, "changelog.d/x.fixed.md"))

      _, err, status = run_bin("changelog-compile", "--root", dir)
      assert status.success?, err
      assert_equal ["README.md"], Dir.children(File.join(dir, "changelog.d"))
      assert_includes File.read(File.join(dir, "CHANGELOG.md")), "### Fixed\n\n- Fix.\n\n## 1.2.0"

      out, _, status = run_bin("changelog-compile", "--root", dir)
      assert status.success?
      assert_includes out, "nothing to compile"
    end
  end

  def test_integration_compile_writes_nothing_on_a_bad_fragment
    repo do |dir|
      File.write(File.join(dir, "changelog.d/x.fixed.md"), "- Fix.\n")
      File.write(File.join(dir, "changelog.d/y.fixd.md"), "- Typo.\n")
      _, err, status = run_bin("changelog-compile", "--root", dir)
      assert_equal 1, status.exitstatus
      assert_includes err, "y.fixd.md: not a fragment name"
      assert_equal CHANGELOG, File.read(File.join(dir, "CHANGELOG.md"))
      assert File.exist?(File.join(dir, "changelog.d/x.fixed.md"))
    end
  end

  def test_integration_check_over_real_commits
    repo do |dir|
      commit_on(dir, "good", { "lib/a.rb" => "A = 2\n", "changelog.d/good.changed.md" => "- Good.\n" })
      out, err, status = run_bin("changelog-check", "--root", dir, "--base", "accepted", "--head", "good")
      assert status.success?, err
      assert_includes out, "changelog-check: ok"

      commit_on(dir, "bare", { "lib/a.rb" => "A = 3\n" })
      _, err, status = run_bin("changelog-check", "--root", dir, "--base", "accepted", "--head", "bare")
      assert_equal 1, status.exitstatus
      assert_includes err, "adds no changelog.d/<slug>.<kind>.md fragment"

      commit_on(dir, "bad", { "changelog.d/bad.added.md" => "### Added\n- x\n" })
      _, err, status = run_bin("changelog-check", "--root", dir, "--base", "accepted", "--head", "bad")
      assert_equal 1, status.exitstatus
      assert_includes err, "bad.added.md:1: a fragment carries no"

      _, err, status = run_bin("changelog-check", "--root", dir, "--base", "nope", "--head", "bad")
      assert_equal 64, status.exitstatus, err
    end
  end
end
