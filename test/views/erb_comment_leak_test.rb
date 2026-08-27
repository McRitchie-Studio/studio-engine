# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "tmpdir"
require "fileutils"

# [unit] No ERB comment in an engine view may terminate early and leak its tail.
#
# THE DEFECT. An ERB comment `<%#  %>` ends at the FIRST close sequence inside
# it. A comment that quotes an ERB tag therefore stops there, and everything
# after it renders into the page as visible prose. Nothing about the source looks
# wrong; the page simply grows a sentence.
#
# WHY THE ENGINE NEEDS THIS MORE THAN A CONSUMER DOES. These views ship to EVERY
# consuming app. One leaked comment here renders that prose in all of them at
# once, and none of them can fix it locally.
#
# PORTED from turf-monster's test/lib/erb_comment_percent_test.rb, which carries
# the measured rationale for both signatures, rather than reinvented — the hub's
# own ci.yml states the lesson this repeats: "a lane that CONSTITUTES a verdict
# must be enrolled on the day it is wired, or the next lane repeats the bug one
# file over." It repeated one REPO over: on the night turf's second signature
# shipped, it caught its own author writing exactly this leak into a turf view.
#
# MEASURED before shipping: both signatures return ZERO candidates across the
# engine's 164 view files today, so this lands green and needs no allowlist. An
# earlier attempt at the narrow rule in turf was defeated by 3 false positives
# and an allowlist; this shape has none.
class ErbCommentLeakTest < ActiveSupport::TestCase
  COMMENT = /<%#(.*?)%>/m
  ERB_OPEN = "<%"
  ORPHAN_CLOSE = "%>"

  def self.view_root = Pathname.new(File.expand_path("../../app/views", __dir__))

  def views(root = self.class.view_root)
    Dir.glob(File.join(root, "**", "*.erb"))
  end

  def rel(path, root) = path.delete_prefix("#{root}/")

  # SIGNATURE 1 — the comment quotes an ERB OPEN tag.
  def quoting_comments(root = self.class.view_root)
    views(root).flat_map do |path|
      src = File.read(path)
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        next unless match[1].include?(ERB_OPEN)

        "#{rel(path, root)}:#{src[0...match.begin(0)].count("\n") + 1}"
      end
    end.sort
  end

  # SIGNATURE 2 — the comment quotes only a CLOSE sequence, so no open tag is
  # involved and signature 1 is blind to it. The tell is an ORPHAN `%>` sitting
  # between this comment's close and the next ERB open: the author's own second
  # close, the mark of one comment the parser turned into two.
  def leaking_comments(root = self.class.view_root)
    views(root).flat_map do |path|
      src = File.read(path)
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        rest = src[match.end(0)..] || ""
        next_open = rest.index(ERB_OPEN)
        segment = next_open ? rest[0...next_open] : rest
        next unless segment.include?(ORPHAN_CLOSE)

        "#{rel(path, root)}:#{src[0...match.begin(0)].count("\n") + 1}"
      end
    end.sort
  end

  test "no engine view comment quotes an ERB tag" do
    found = quoting_comments
    assert_empty found,
                 "these ERB comments contain an ERB open tag, so the comment TERMINATES on it and " \
                 "the rest of the prose renders into every consuming app as visible text. " \
                 "Describe the tag in words, or use an HTML comment:\n  #{found.join("\n  ")}"
  end

  test "no engine view comment terminates early and leaks its tail" do
    found = leaking_comments
    assert_empty found,
                 "these ERB comments quote a CLOSE sequence, so the comment ends there and the " \
                 "rest of the sentence renders as visible text. No ERB open is involved, which is " \
                 "why the first assertion cannot see it:\n  #{found.join("\n  ")}"
  end

  # GUARD THE GUARDS. Without these the assertions above are green lights that
  # can never turn red — a matcher that stopped matching reads as a clean tree,
  # which is the failure mode this whole file exists to prevent one level down.

  test "the scan recognises an ERB tag quoted inside a comment" do
    with_probe_tree do |root|
      assert_includes quoting_comments(root).join, "_leak_open.html.erb",
                      "the matcher no longer sees the very thing it exists to catch"
      refute_includes quoting_comments(root).join, "_ok.html.erb",
                      "an ordinary comment was reported — this guard would cry wolf"
    end
  end

  test "the scan recognises a comment that quotes only the close sequence" do
    with_probe_tree do |root|
      assert_includes leaking_comments(root).join, "_leak_close.html.erb"
      refute_includes leaking_comments(root).join, "_ok.html.erb",
                      "a plain percent in prose was reported as a leak"
    end
  end

  test "the guard actually reads the engine's views" do
    assert_operator views.length, :>=, 100,
                    "only #{views.length} view(s) under #{self.class.view_root} — this guard is " \
                    "covering almost nothing"
  end

  private

  def with_probe_tree
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "probe"))
      File.write(File.join(dir, "probe/_leak_open.html.erb"),
                 "<div>\n  <%# quoting <%= yield %> breaks this comment %>\n</div>\n")
      # The reviewer's own case: documenting the rule leaks the explanation.
      File.write(File.join(dir, "probe/_leak_close.html.erb"),
                 "<div>\n  <%# a comment ends at the first close sequence, which is %> and " \
                 "everything after renders %>\n</div>\n")
      File.write(File.join(dir, "probe/_ok.html.erb"),
                 "<div>\n  <%# an ordinary comment %>\n  <p>50% wide</p>\n</div>\n")
      yield dir
    end
  end
end
