# frozen_string_literal: true

# bin/lib/changelog_fragments.rb — ONE FILE PER CHANGE, compiled at release.
#
# WHY. Every engine PR used to add its entry at the top of `## Unreleased` in
# CHANGELOG.md. Measured 2026-11-06: 39 of the last 40 merged engine PRs edited that
# file, and 15 of the 40 needed a merge-forward commit before they could merge.
# `.gitattributes` sets `merge=union` on CHANGELOG.md, but GitHub's mergeability check
# does not run custom merge drivers, so every pair of open PRs still read as DIRTY.
# (Audit: .agents/epics/audits/refactor-review-2026-11-06/lane-devops.md.)
#
# So a PR now adds a new file, `changelog.d/<slug>.<kind>.md`, and never touches
# CHANGELOG.md. Two PRs add two different paths, and two different new paths cannot
# conflict. At release, `bin/changelog-compile` folds every fragment into
# `## Unreleased`, grouped under its `### <Kind>` subsection, and deletes the
# fragments. The hub's `bin/release prepare` then rolls `## Unreleased` into the
# allocated version heading exactly as before (docs/RELEASE.md).
#
# A fragment that merges AFTER a roll stays in changelog.d/ and compiles into the
# NEXT release, which is the version that ships it. The old bucket could misfile such
# an entry under the version it missed; a fragment cannot.
#
# THE FORMAT:
#
#   changelog.d/<slug>.<kind>.md
#     <slug>  lower-case letters, digits and hyphens; use the task slug
#     <kind>  added | changed | deprecated | removed | fixed | security
#     body    the entry, as Markdown list item(s) ("- **What.** Why."). No `## ` or
#             `### ` heading: the file name carries the kind, the release the version.
#
# One change with two kinds is two files (`foo.added.md` and `foo.fixed.md`).
#
# DELIBERATELY PURE except `load_dir` and `compile_dir!`, so the transform and the
# rules run as unit tests. Stdlib only.
module ChangelogFragments
  DIR = "changelog.d"

  # Keep a Changelog's order. The compiled bucket lists subsections in this order.
  KINDS = %w[Added Changed Deprecated Removed Fixed Security].freeze

  NAME = /\A(?<slug>[a-z0-9]+(?:-[a-z0-9]+)*)\.(?<kind>#{KINDS.map(&:downcase).join('|')})\.md\z/

  # Files in changelog.d/ that are not fragments and are never compiled.
  IGNORED = %w[README.md .gitkeep].freeze

  UNRELEASED = /\A\#\#[ \t]+\[?Unreleased\]?[ \t]*\z/i
  H2 = /\A\#\#[ \t]+/
  H3 = /\A\#\#\#[ \t]+(?<title>.+?)[ \t]*\z/
  FENCE = /\A {0,3}(?<run>`{3,}|~{3,})/

  Fragment = Struct.new(:name, :slug, :kind, :body, keyword_init: true)

  class Error < StandardError; end

  module_function

  # [slug, Kind] for a fragment file name, or nil.
  def parse_name(basename)
    m = NAME.match(basename) or return nil
    [m[:slug], KINDS.find { |k| k.downcase == m[:kind] }]
  end

  # The problems with one fragment's body; empty when it is well formed.
  def body_errors(name, body)
    errors = []
    errors << "#{name}: the fragment is empty" if body.strip.empty?
    outside_fences(body.lines(chomp: true)).each do |line, number|
      next unless line.match?(H2) || line.match?(/\A\#\#\#[ \t]/)

      errors << "#{name}:#{number}: a fragment carries no '## ' or '### ' heading " \
                "(the file name names the kind; the release writes the version)"
    end
    errors << "#{name}: an unterminated fenced code block" if open_fence?(body.lines(chomp: true))
    errors
  end

  # Builds Fragments from { basename => body }. Returns [fragments, errors].
  # A file that is neither a fragment nor in IGNORED is an error, so a typo such as
  # `foo.fixd.md` reddens the check instead of never compiling.
  def build(files)
    fragments = []
    errors = []
    files.keys.sort.each do |name|
      next if IGNORED.include?(name)

      slug, kind = parse_name(name)
      unless slug
        errors << "#{name}: not a fragment name — want <slug>.<kind>.md, kind one of " \
                  "#{KINDS.map(&:downcase).join(', ')}"
        next
      end
      body = files[name]
      found = body_errors(name, body)
      errors.concat(found)
      fragments << Fragment.new(name: name, slug: slug, kind: kind, body: trim(body.lines(chomp: true)).join("\n")) if found.empty?
    end
    [fragments, errors]
  end

  # CHANGELOG text with every fragment folded into `## Unreleased`. Existing bucket
  # content is kept: entries under a known `### <Kind>` stay first in that kind, any
  # text before the first subsection stays first, and an unknown subsection follows
  # the known ones. Fragments within a kind are in file-name order.
  #
  # Raises Error when the file has no single, leading `## Unreleased` to fold into.
  def compile(text, fragments)
    lines = text.lines(chomp: true)
    starts = outside_fences(lines).select { |line, _| line.match?(H2) }.map { |_, n| n - 1 }
    buckets = starts.select { |i| lines[i].match?(UNRELEASED) }
    raise Error, "CHANGELOG.md has no '## Unreleased' heading to compile into" if buckets.empty?
    raise Error, "CHANGELOG.md has #{buckets.size} '## Unreleased' headings; want exactly one" if buckets.size > 1

    head = buckets.first
    raise Error, "'## Unreleased' is not the first '## ' heading in CHANGELOG.md" unless head == starts.first

    stop = starts.find { |i| i > head } || lines.size
    bucket = rebuild_bucket(lines[(head + 1)...stop], fragments)
    tail = lines[stop..] || []
    out = lines[0..head] + [""] + bucket
    out += [""] unless bucket.empty? || tail.empty?
    out += tail
    "#{out.join("\n")}\n"
  end

  # The compiled `## Unreleased` section alone (for a dry run).
  def unreleased_section(text)
    lines = text.lines(chomp: true)
    starts = outside_fences(lines).select { |line, _| line.match?(H2) }.map { |_, n| n - 1 }
    head = starts.find { |i| lines[i].match?(UNRELEASED) } or return ""
    stop = starts.find { |i| i > head } || lines.size
    "#{trim(lines[head...stop]).join("\n")}\n"
  end

  def rebuild_bucket(body, fragments)
    preamble, sections = split_subsections(body)
    known = KINDS.filter_map do |kind|
      own = sections.find { |title, _| title.casecmp?(kind) }
      entries = own ? [own[1]] : []
      entries += fragments.select { |f| f.kind == kind }.map { |f| f.body.lines(chomp: true) }
      next if entries.all?(&:empty?)

      ["### #{kind}", ""] + entries.reject(&:empty?).flatten
    end
    unknown = sections.reject { |title, _| KINDS.any? { |k| title.casecmp?(k) } }
                      .map { |title, lines| ["### #{title}", ""] + lines }
    blocks = [preamble].reject(&:empty?) + known + unknown
    blocks.each_with_index.flat_map { |block, i| i.zero? ? block : [""] + block }
  end

  # [preamble lines, [[title, lines], ...]] for a bucket body, cut on `### ` outside
  # fences. Every piece is trimmed of blank edge lines.
  def split_subsections(body)
    cuts = outside_fences(body).filter_map { |line, n| (m = H3.match(line)) && [n - 1, m[:title]] }
    preamble = trim(body[0...(cuts.first&.first || body.size)])
    sections = cuts.each_with_index.map do |(at, title), i|
      stop = cuts[i + 1]&.first || body.size
      [title, trim(body[(at + 1)...stop])]
    end
    [preamble, sections]
  end

  # [[line, 1-based number], ...] for the lines that sit outside fenced code blocks.
  def outside_fences(lines)
    fence = nil
    lines.each_with_index.filter_map do |line, i|
      if (m = FENCE.match(line))
        run = m[:run]
        if fence.nil?
          fence = run
          next
        elsif run[0] == fence[0] && run.size >= fence.size && line.strip == run
          fence = nil
          next
        end
      end
      [line, i + 1] if fence.nil?
    end
  end

  def open_fence?(lines)
    fence = nil
    lines.each do |line|
      m = FENCE.match(line) or next
      if fence.nil?
        fence = m[:run]
      elsif m[:run][0] == fence[0] && m[:run].size >= fence.size && line.strip == m[:run]
        fence = nil
      end
    end
    !fence.nil?
  end

  def trim(lines)
    lines = lines.drop_while { |l| l.strip.empty? }
    lines = lines.reverse.drop_while { |l| l.strip.empty? }.reverse
    lines
  end

  # ---- THE PR CHECK ---------------------------------------------------------

  # Paths the gem ships (studio-engine.gemspec `spec.files`). A change here is a
  # change a consumer can see, so it carries a fragment.
  SHIPPED = %r{\A(?:lib|app|config|db)/|\Astudio-engine\.gemspec\z}

  # The release's version commit owns CHANGELOG.md: it compiles and rolls it.
  VERSION_FILE = "lib/studio/version.rb"

  # The problems with a PR, from its name-status changes ([[status, path], ...] as
  # `git diff --name-status` prints them) and CHANGELOG.md on each side. Empty when
  # the PR may merge.
  def pr_errors(changes, base_changelog:, head_changelog:)
    paths = changes.map(&:last)
    return [] if paths.include?(VERSION_FILE)

    errors = []
    added = bucket_additions(base_changelog.to_s, head_changelog.to_s)
    unless added.empty?
      errors << "CHANGELOG.md: this PR adds #{added.size} line(s) under '## Unreleased' " \
                "(first: #{added.first.strip[0, 80].inspect}). Move the entry to " \
                "#{DIR}/<slug>.<kind>.md; the release compiles it (docs/RELEASE.md)"
    end
    fragment = changes.any? { |status, path| !status.start_with?("D") && fragment_path?(path) }
    if paths.any? { |p| p.match?(SHIPPED) } && !fragment
      errors << "this PR changes what the gem ships (#{paths.grep(SHIPPED).first}) and adds no " \
                "#{DIR}/<slug>.<kind>.md fragment. Add one; see #{DIR}/README.md"
    end
    errors
  end

  def fragment_path?(path)
    dir, name = File.split(path)
    dir == DIR && !parse_name(name).nil?
  end

  # Non-blank lines in head's `## Unreleased` body that base's does not have
  # (counted, so a duplicated line counts once more).
  def bucket_additions(base, head)
    left = Hash.new(0)
    bucket_body(base).each { |l| left[l] += 1 }
    bucket_body(head).reject { |l| l.strip.empty? }.select do |l|
      next true if left[l].zero?

      left[l] -= 1
      false
    end
  end

  def bucket_body(text)
    lines = unreleased_section(text).lines(chomp: true)
    lines.drop(1)
  end

  # ---- IO -------------------------------------------------------------------

  # { basename => body } for changelog.d/ under root ({} when the folder is absent).
  def load_dir(root)
    dir = File.join(root, DIR)
    return {} unless File.directory?(dir)

    Dir.children(dir).select { |n| File.file?(File.join(dir, n)) }
       .to_h { |n| [n, File.read(File.join(dir, n), encoding: "UTF-8")] }
  end

  # Compiles changelog.d/ into CHANGELOG.md under root. Returns a Result. Writes and
  # deletes nothing when dry_run is set or when any fragment is invalid.
  Result = Struct.new(:fragments, :errors, :text, :written, keyword_init: true)

  def compile_dir!(root, dry_run: false)
    fragments, errors = build(load_dir(root))
    path = File.join(root, "CHANGELOG.md")
    return Result.new(fragments: fragments, errors: errors, text: nil, written: false) unless errors.empty?
    return Result.new(fragments: [], errors: [], text: nil, written: false) if fragments.empty?

    text = compile(File.read(path, encoding: "UTF-8"), fragments)
    return Result.new(fragments: fragments, errors: [], text: text, written: false) if dry_run

    File.write(path, text)
    fragments.each { |f| File.delete(File.join(root, DIR, f.name)) }
    Result.new(fragments: fragments, errors: [], text: text, written: true)
  end
end
