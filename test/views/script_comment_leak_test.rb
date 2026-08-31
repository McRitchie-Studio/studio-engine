# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "tmpdir"
require "fileutils"

# [unit] No JavaScript comment inside an engine view's <script> may carry an ERB
# sequence.
#
# THE SURFACE THIS ADDS. test/views/erb_comment_leak_test.rb guards the ERB
# comment form in these same files. It does not look inside <script> blocks, and
# that is where the engine keeps its browser programs: studio/modals/_host,
# studio/solana/_phantom_deeplink, layouts/studio/_head and the modal blocks all
# ship substantial JavaScript with substantial comments. Measured at
# origin/accepted on 2026-08-31, those blocks hold 1_239 comments and 73_913
# bytes of comment body that NO guard read. A green run of the ERB guard on a
# diff made of them meant "not looked at", not "no leak" — the reviewer note that
# raised this task said exactly that.
#
# WHY THESE COMMENTS ARE THE LIKELY ONES TO CARRY A TAG. They document the
# rendering seam, so quoting a tag while explaining one is the natural thing to
# write.
#
# THE MECHANISM IS NOT THE SAME AS THE ERB COMMENT ONE, AND IT IS WORSE.
# A tag quoted inside an ERB comment is inert: the comment swallows it. A tag
# quoted inside a JAVASCRIPT comment is not inside anything as far as ERB is
# concerned — the JS comment is ordinary template text — so ERB opens a tag right
# there and RUNS it. A complete tag evaluates (a docstring silently calling code,
# or a NameError at render). An incomplete one swallows every byte up to the next
# close sequence anywhere later in the file, deleting working JavaScript with no
# syntax error to show for it. Wrapping the line in an HTML comment does not help:
# ERB runs inside those too.
#
# WHAT IT ASKS OF AUTHORS is what the ERB guard asks — describe the tag in words.
# Prose about the hazard stays legal; only the literal characters are refused.
# The escape form is refused with them: it renders a raw tag into every consuming
# app's page, which is the string other guards in this ecosystem scan for.
#
# READING THE INPUT IS HALF THE JOB. A scan that finds nothing and a scan that
# read nothing look identical, and the naive version of this one was the second:
# anchoring script blocks on raw source let an ERB comment's PROSE mention of a
# script tag open the block, so studio/_board_assets.html.erb reported 19_512
# bytes of markup as JavaScript and never saw its real program on its own terms.
# The fix is to anchor on a copy with ERB tags and HTML comments blanked out
# (length preserved, so offsets and line numbers still land), and the assertions
# below check the INPUT — what the walker extracted, how much of the tree it
# reached — not only the verdict.
class ScriptCommentLeakTest < ActiveSupport::TestCase
  ERB_OPEN = "<%"
  ERB_CLOSE = "%>"
  ERB_TAG = /<%.*?%>/m
  HTML_COMMENT = /<!--.*?-->/m
  SCRIPT_OPEN = /<script\b[^>]*>/i
  SCRIPT_CLOSE = %r{</script>}i
  QUOTES = ['"', "'", "`"].freeze

  # Anti-vacuous floors. Measured at origin/accepted on 2026-08-31: 33 script
  # blocks, 1_239 comments, 73_913 bytes of comment body over 169 view files.
  # Set at roughly 60% of each, so moving a program out to an asset file has room
  # while a walker that quietly stopped walking goes red.
  MIN_SCRIPT_BLOCKS = 20
  MIN_COMMENTS = 700
  MIN_COMMENT_BYTES = 40_000

  # A `/` opens a REGEX only where a value may begin. Everywhere else it divides.
  # Getting this wrong reads `/["']\/\//` as a comment and reports code as prose.
  TAIL_WINDOW = 16
  REGEX_MAY_FOLLOW_CHAR = "(,=:[!&|?{};+-*%~^<>\n".chars.freeze
  REGEX_MAY_FOLLOW_WORD = %w[
    return typeof instanceof in of new delete void case do else yield await
  ].freeze

  # Kinds that mean the walker could not read a span reliably. They are reported
  # as findings on purpose: an unreadable span is a blind spot, and a blind spot
  # that reports green is the whole failure this file exists to end.
  UNREADABLE = %i[unterminated_erb unterminated_block unterminated_literal].freeze

  def self.view_root = Pathname.new(File.expand_path("../../app/views", __dir__))

  def views(root = self.class.view_root)
    Dir.glob(File.join(root, "**", "*.erb")).sort
  end

  def rel(path, root) = path.to_s.delete_prefix("#{root}/")

  # ---------------------------------------------------------------- anchoring

  # ERB tags and HTML comments blanked to spaces, LENGTH PRESERVED. Every offset
  # taken from this copy still indexes the original source, and newlines survive
  # so reported line numbers stay honest.
  def mask_non_markup(src)
    [ERB_TAG, HTML_COMMENT].reduce(src.dup) do |acc, pattern|
      acc.gsub(pattern) { |hit| hit.gsub(/[^\n]/, " ") }
    end
  end

  # [[inner_begin, inner_end], ...] as offsets into the ORIGINAL source.
  #
  # Anchoring on the masked copy is the point. Nine views name a script tag in
  # prose inside an ERB or HTML comment, and on raw source the first of those
  # opens a block that runs until the real program's closing tag.
  def script_blocks(src)
    masked = mask_non_markup(src)
    blocks = []
    pos = 0

    while (opener = SCRIPT_OPEN.match(masked, pos))
      close_at = masked.index(SCRIPT_CLOSE, opener.end(0))
      break if close_at.nil?

      blocks << [opener.end(0), close_at]
      pos = close_at + "</script>".length
    end

    blocks
  end

  # ---------------------------------------------------------------- the walker

  # One script block walked as JavaScript. Returns [[kind, body, offset], ...].
  #
  # The states that matter are the ones that can HIDE a comment opener — a string
  # ("https://example.com" is not a comment), a template literal, a regex. ERB
  # tags are opaque in CODE position, because an ERB tag's quotes and slashes are
  # Ruby, not JavaScript, and letting them steer this walk is how a walker loses
  # its place for the rest of a file. Inside a COMMENT they are the thing being
  # hunted, so there they are left exactly as written.
  def js_comments(js)
    found = []
    tail = +""
    index = 0
    length = js.length

    while index < length
      pair = js[index, 2]

      if pair == ERB_OPEN
        stop = js.index(ERB_CLOSE, index + 2)
        if stop.nil?
          found << [:unterminated_erb, js[index, 120], index]
          index += 2
        else
          index = stop + 2
        end
        tail = push_tail(tail, " ")
      elsif pair == "//"
        stop = js.index("\n", index) || length
        found << [:line, js[(index + 2)...stop], index]
        index = stop
      elsif pair == "/*"
        stop = js.index("*/", index + 2)
        if stop.nil?
          found << [:unterminated_block, js[(index + 2)..] || "", index]
          index = length
        else
          found << [:block, js[(index + 2)...stop], index]
          index = stop + 2
        end
      elsif QUOTES.include?(js[index])
        stop, closed = skip_literal(js, index)
        found << [:unterminated_literal, js[index, 120], index] unless closed
        index = stop
        tail = push_tail(tail, "x")
      elsif js[index] == "/" && regex_may_start?(tail)
        index = skip_regex(js, index)
        tail = push_tail(tail, "x")
      else
        tail = push_tail(tail, js[index])
        index += 1
      end
    end

    found
  end

  # Past a string or template literal, and whether it CLOSED.
  #
  # A quoted string resyncs at its own line end, so the worst a broken one costs
  # is the rest of that line. A template literal has no line end to resync on: one
  # that never closes swallows every comment after it for the rest of the block,
  # and reports a clean file. That is the exact shape of "a scan that read
  # nothing", so it is returned as unreadable rather than absorbed.
  #
  # ERB tags are NOT skipped here, and that is a measured choice rather than an
  # oversight. Skipping them changed nothing: the walker returned the identical
  # 4_011 comments with and without across studio-engine, mcritchie-studio and
  # turf-monster on 2026-08-31, and zero literals ran away in any of them. No
  # fixture kills the branch either, because reaching it needs an ERB tag holding
  # an odd number of one quote character, which is not valid Ruby. A branch no
  # test can kill is a branch the next author deletes without knowing what it
  # guarded, so the runaway REPORT carries that risk instead.
  def skip_literal(js, start)
    quote = js[start]
    index = start + 1
    length = js.length

    while index < length
      if js[index] == "\\"
        index += 2
      elsif js[index] == quote
        return [index + 1, true]
      elsif js[index] == "\n" && quote != "`"
        return [index, true] # resynced at the line end, which bounds the damage
      else
        index += 1
      end
    end

    [length, false]
  end

  # Past a regex literal. A `/` inside a character class does not close it. If no
  # close arrives on the line it was not a regex, so step one character and let
  # the walk continue rather than swallowing the rest of the block.
  def skip_regex(js, start)
    index = start + 1
    length = js.length
    in_class = false

    while index < length
      char = js[index]
      if char == "\\"
        index += 2
      elsif char == "["
        in_class = true
        index += 1
      elsif char == "]"
        in_class = false
        index += 1
      elsif char == "/" && !in_class
        return index + 1
      elsif char == "\n"
        return start + 1
      else
        index += 1
      end
    end

    start + 1
  end

  def regex_may_start?(tail)
    trimmed = tail.rstrip
    return true if trimmed.empty?
    return true if REGEX_MAY_FOLLOW_CHAR.include?(trimmed[-1])

    REGEX_MAY_FOLLOW_WORD.include?(trimmed[/[A-Za-z_$][A-Za-z0-9_$]*\z/].to_s)
  end

  def push_tail(tail, char)
    grown = tail + char
    grown[-TAIL_WINDOW..] || grown
  end

  # ----------------------------------------------------------------- the scan

  # [[relative_path, line, kind, body], ...] for every JS comment in the tree.
  def script_comments(root = self.class.view_root)
    views(root).flat_map do |path|
      src = File.read(path)
      script_blocks(src).flat_map do |from, to|
        js_comments(src[from...to]).map do |kind, body, offset|
          [rel(path, root), src[0...(from + offset)].count("\n") + 1, kind, body]
        end
      end
    end
  end

  def leaking_script_comments(root = self.class.view_root)
    script_comments(root).filter_map do |path, line, kind, body|
      next "#{path}:#{line}" if UNREADABLE.include?(kind)
      next unless body.include?(ERB_OPEN) || body.include?(ERB_CLOSE)

      "#{path}:#{line}"
    end.sort
  end

  # ------------------------------------------------------------- the verdict

  test "no script comment in an engine view carries an ERB sequence" do
    found = leaking_script_comments

    assert_empty found,
                 "these JavaScript comments live inside a <script> in an engine view and carry " \
                 "an ERB open or close sequence. ERB does not know the line is a comment: a " \
                 "complete tag there is EXECUTED at render, and an incomplete one swallows the " \
                 "JavaScript after it up to the next close sequence in the file. An HTML comment " \
                 "does not help — ERB runs inside those too. Describe the tag in words:\n  " \
                 "#{found.join("\n  ")}"
  end

  # GUARD THE GUARD. Everything below asserts on what the walker READ, not only on
  # what it concluded, because a walker that stopped reading reports a clean tree.

  test "the scan actually reads the engine's inline JavaScript" do
    blocks = views.sum { |path| script_blocks(File.read(path)).length }
    comments = script_comments
    bytes = comments.sum { |_path, _line, _kind, body| body.length }

    assert_operator blocks, :>=, MIN_SCRIPT_BLOCKS,
                    "only #{blocks} script block(s) found under #{self.class.view_root} — this " \
                    "guard is reading almost none of the JavaScript it exists to guard"
    assert_operator comments.length, :>=, MIN_COMMENTS,
                    "only #{comments.length} JavaScript comment(s) extracted — the walker is " \
                    "losing its place, not finding a clean tree"
    assert_operator bytes, :>=, MIN_COMMENT_BYTES,
                    "only #{bytes} bytes of comment body extracted — a walker that reads a " \
                    "fraction of the text reports green for the same reason an empty one does"
  end

  test "every script block the scan finds is a real one" do
    root = self.class.view_root
    mismatched = views.filter_map do |path|
      src = File.read(path)
      blocks = script_blocks(src).length
      closers = src.scan(SCRIPT_CLOSE).length
      next if blocks == closers

      "#{rel(path, root)}: #{blocks} block(s) opened for #{closers} closing tag(s)"
    end

    assert_empty mismatched,
                 "the block finder disagrees with the closing tags actually present. Too few " \
                 "means whole programs go unread; too many means markup is being walked as " \
                 "JavaScript:\n  #{mismatched.join("\n  ")}"
  end

  test "the walker returns comment bodies and nothing else" do
    js = <<~'JS'
      var url = "https://example.com/a"; // trailing note
      // a plain line
      /* a block
         over two lines */
      var slashes = /\/\//g;
      var tpl = `inline // not a comment`;
      var div = total / count / 2;
    JS

    assert_equal [
      " trailing note",
      " a plain line",
      " a block\n   over two lines ",
    ], js_comments(js).map { |_kind, body, _offset| body },
                 "the walker must return every comment body and NO code. A double slash inside " \
                 "a URL, a regex or a template literal is not a comment, and reporting one as " \
                 "prose is how this scan would cry wolf on working code"
  end

  test "a literal that never closes is reported, not read past" do
    kinds = js_comments("var t = `never closed;\nvar u = 1; // unreachable\n")
            .map { |kind, _body, _offset| kind }

    assert_includes kinds, :unterminated_literal,
                    "a template literal with no closing backtick swallows every comment after " \
                    "it — there is no line end to resync on. Absorbing that in silence is a scan " \
                    "that read nothing while reporting a clean file"
    refute_includes kinds, :line,
                    "the comment IS swallowed, which is the point. What must not happen is the " \
                    "walker losing it without saying so"
  end

  test "an unterminated ERB open inside a script is reported, not skipped past" do
    kinds = js_comments("var a = 1; <%= never_closed\nvar b = 2;\n").map { |kind, _b, _o| kind }

    assert_includes kinds, :unterminated_erb,
                    "an ERB tag with no close swallows every byte after it up to the next close " \
                    "sequence in the FILE. Reading past it in silence is the blind spot"
  end

  test "the block finder is not anchored by a script tag named in prose" do
    with_probe_tree do |root|
      src = File.read(File.join(root, "probe/_ok_prose.html.erb"))
      blocks = script_blocks(src)

      assert_equal 1, blocks.size
      assert_equal "\n  var real = 1; // fine\n", src[blocks[0][0]...blocks[0][1]],
                   "the block anchored on the prose mention above the real program, so 'the ERB " \
                   "comment above it' was walked as JavaScript. Measured on " \
                   "studio/_board_assets.html.erb: 19_512 bytes of markup read as a program"
    end
  end

  test "the scan catches every leak shape and leaves ordinary scripts alone" do
    with_probe_tree do |root|
      found = leaking_script_comments(root)

      assert_includes found.join, "_leak_line.html.erb",
                      "a line comment quoting an ERB tag is the shape this guard exists for"
      assert_includes found.join, "_leak_close_only.html.erb",
                      "a block comment quoting only a CLOSE sequence is the same defect, and the " \
                      "ERB guard is blind to it because no ERB comment is involved"
      assert_includes found.join, "_leak_open_only.html.erb",
                      "a body carrying only an OPEN is the worst of them: ERB starts a tag there " \
                      "and swallows JavaScript up to the next close sequence in the file"
      assert_includes found.join, "_leak_escaped.html.erb",
                      "the escape form renders a raw tag into every consuming app's page. It is " \
                      "refused with the rest: describe the tag in words"
      assert_includes found.join, "_leak_unreadable.html.erb",
                      "a span the walker cannot read must be reported, not passed over. Silence " \
                      "there is the green-that-means-nothing this guard exists to end"
      assert_equal 5, found.size,
                   "an ordinary script was flagged. The next step would be an allowlist, and an " \
                   "allowlisted guard is how a rule stops guarding. Got: #{found.inspect}"
    end
  end

  test "a comment may still describe the hazard in words" do
    with_probe_tree do |root|
      refute_includes leaking_script_comments(root).join, "_ok_words.html.erb",
                      "a guard that bans discussing the problem makes the fix undocumentable"
    end
  end

  private

  def with_probe_tree
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "probe"))

      # The leak shapes, separated by WHICH sequence the body carries. A probe that
      # happens to carry both still passes a rule that checks for only one of them,
      # and that is how a half-disabled rule reads as green.
      File.write(File.join(dir, "probe/_leak_line.html.erb"),
                 "<script>\n  // renders below the <%= yield %> call\n  var a = 1;\n</script>\n")
      File.write(File.join(dir, "probe/_leak_close_only.html.erb"),
                 "<script>\n  /* the tag ends at its %> and the rest runs */\n  var b = 2;\n</script>\n")
      File.write(File.join(dir, "probe/_leak_open_only.html.erb"),
                 "<script>\n  /* never write <% in one of these */\n  var c = 3;\n</script>\n")
      File.write(File.join(dir, "probe/_leak_escaped.html.erb"),
                 "<script>\n  // see <%%= render \"studio/modals/host\" %> below\n</script>\n")
      # A span the walker cannot read is a blind spot, and a blind spot that reports
      # green is the failure this whole file exists to end. This body carries NO ERB
      # sequence, so only the unreadable-span rule catches it.
      File.write(File.join(dir, "probe/_leak_unreadable.html.erb"),
                 "<script>\n  /* a block comment that never closes\n  var d = 4;\n</script>\n")

      # Prose about the hazard, which must stay legal.
      File.write(File.join(dir, "probe/_ok_words.html.erb"),
                 "<script>\n  // an ERB comment ends at its first close marker, so a quoted tag\n" \
                 "  // truncates it and the tail renders as visible text.\n  var c = 3;\n</script>\n")

      # The literals that hide a comment opener. None of these is a comment.
      File.write(File.join(dir, "probe/_ok_literals.html.erb"),
                 "<script>\n  var u = \"https://example.com/<%= id %>\";\n" \
                 "  var r = /[\"']\\/\\//g;\n  var t = `a // b`;\n  var d = x / y / z;\n</script>\n")

      # The measured anchoring case: a script tag named in prose ABOVE the program.
      File.write(File.join(dir, "probe/_ok_prose.html.erb"),
                 "<%# ships at page level because a <script> inside the component never runs %>\n" \
                 "<!-- and an HTML comment naming <script> too -->\n" \
                 "<script>\n  var real = 1; // fine\n</script>\n")

      yield dir
    end
  end
end
