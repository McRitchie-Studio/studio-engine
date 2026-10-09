require "bundler/setup"

require "minitest/autorun"
require "tmpdir"
require "fileutils"

# [unit] No engine view carries an inline script, except the ones listed below
# by path.
#
# The engine's browser behaviour lives in ES modules under app/javascript/studio,
# loaded by the importmap: a module is cached, testable under node, nonced by its
# loader, and not re-evaluated on every Turbo visit. An inline script is none of
# those, and a consumer's Content-Security-Policy has to allow 'unsafe-inline'
# for it. So a view that grows one fails here.
#
# WHAT COUNTS. In the template's own markup: a script tag with a body, or with no
# src. In its Ruby: a helper that renders one (javascript_tag, tag.script,
# content_tag :script). What does not: an ERB comment, a string in the
# template's Ruby that merely mentions the tag, a script tag that only names a
# src, and the importmap's own loaders (javascript_importmap_tags,
# javascript_import_module_tag, javascript_include_tag).
#
# THE ALLOW-LIST IS A DEBT REGISTER, AND IT ONLY SHRINKS. Each entry names the
# task that owns the script and how many the file carries. The list is checked
# both ways:
#
#   - a view with a script that is not listed fails;
#   - a listed view whose scripts are gone, or that no longer exists, fails too,
#     so a stale entry cannot stay behind to cover a script added later;
#   - a listed view carrying a different number of scripts than its entry fails,
#     so a second script cannot hide behind the first.
#
# A task that moves a script out deletes its own line in the same commit.
class NoInlineScriptTest < Minitest::Test
  VIEW_ROOT = File.expand_path("../../app/views", __dir__)

  PERMANENT = "permanent".freeze

  # path under app/views => { scripts:, owner:, why: }
  ALLOWED = {
    # The pre-paint theme script: it adds `dark` before the first paint, which no
    # deferred module can do. Nonced, and held to that below.
    "layouts/studio/_head.html.erb" => {
      scripts: 1, owner: PERMANENT,
      why: "pre-paint theme: runs before the stylesheet paints"
    },

    # hold-button-says-when-dead: inline on purpose, and nonced
    # (test/integration/head_script_nonce_test.rb holds it to that).
    "studio/_hold_button_guard.html.erb" => {
      scripts: 1, owner: "hold-button-says-when-dead",
      why: "it reports a hold button whose modules failed to load, so it must run with no module " \
           "in the boot graph loaded; e2e/hold_button_guard.spec.js fails each module and reads it"
    },

    # engine-admin-scripts-to-stimulus: left inline on purpose.
    "studio/_at_time_script.html.erb" => {
      scripts: 1, owner: "engine-admin-scripts-to-stimulus",
      why: "its first pass runs as the tag parses, before first paint, so a reader never sees the " \
           "server's clock; e2e/at_time_script.spec.js asserts the inline program"
    },
    "solana_sessions/phantom_callback.html.erb" => {
      scripts: 1, owner: "engine-admin-scripts-to-stimulus",
      why: "the wallet's return leg: it runs as the page parses, ahead of every deferred module, and " \
           "turf-monster's tests read this template's source"
    },

    # engine-modal-blocks-profile-stimulus: inline on purpose, and nonced
    # (test/integration/head_script_nonce_test.rb holds the guard to that).
    "studio/_alpine_scopes_guard.html.erb" => {
      scripts: 1, owner: "engine-modal-blocks-profile-stimulus",
      why: "it reports a profile form, birthday card or upload whose x-data factory failed to load, so " \
           "it must run with no module loaded; e2e/alpine_scopes_guard.spec.js fails each module and reads it"
    },
    "style/_modals.html.erb" => {
      scripts: 1, owner: "engine-modal-blocks-profile-stimulus",
      why: "the style guide's own nonced module import (studio/style_guide): a loader with no program, " \
           "written with tag.script because the views are also rendered where importmap's helper is absent"
    }
  }.freeze

  ERB_COMMENT = /<%#.*?%>/m
  ERB_TAG = /<%.*?%>/m
  HTML_COMMENT = /<!--.*?-->/m
  SCRIPT_TAG = %r{<script\b([^>]*)>(.*?)(</script>|\z)}mi
  SCRIPT_HELPER = /\bjavascript_tag\b|\btag\.script\b|\bcontent_tag\s*\(?\s*[:"']script\b/

  # Blanked to spaces, newlines kept, so every offset still names its line.
  def blank(text, pattern)
    text.gsub(pattern) { |match| match.gsub(/[^\n]/, " ") }
  end

  # The line of each inline script in one template's source.
  def script_lines(source)
    uncommented = blank(source, ERB_COMMENT)
    lines = []

    # Markup: every ERB tag and HTML comment blanked, so a tag name in a Ruby
    # string or a comment is not markup.
    markup = blank(blank(uncommented, ERB_TAG), HTML_COMMENT)
    markup.scan(SCRIPT_TAG) do |attributes, body, _close|
      external = attributes.match?(/\bsrc\s*=/) && body.strip.empty?
      lines << markup[0...Regexp.last_match.begin(0)].count("\n") + 1 unless external
    end

    # Ruby: a helper that renders a script element.
    uncommented.scan(ERB_TAG) do
      tag = Regexp.last_match
      lines << uncommented[0...tag.begin(0)].count("\n") + 1 if tag[0].match?(SCRIPT_HELPER)
    end

    lines.sort
  end

  # { path under root => [line, ...] } for every template with an inline script.
  def inline_scripts(root)
    Dir.glob(File.join(root, "**", "*.erb")).sort.each_with_object({}) do |path, found|
      lines = script_lines(File.read(path))
      found[path.delete_prefix("#{root}/")] = lines if lines.any?
    end
  end

  # What is wrong between the scripts found and the list that allows them.
  def problems(found, allowed)
    unlisted = (found.keys - allowed.keys).map do |path|
      "#{path}:#{found[path].join(',')} carries an inline script. Move it to a module under " \
        "app/javascript/studio (a controller in studio/stimulus's LAZY table binds it to the page)."
    end
    stale = (allowed.keys - found.keys).map do |path|
      "#{path} is on the allow-list (#{allowed[path][:owner]}) and carries no inline script. Delete its line."
    end
    miscounted = (allowed.keys & found.keys).filter_map do |path|
      next if found[path].length == allowed[path][:scripts]

      "#{path} carries #{found[path].length} inline script(s) at line(s) #{found[path].join(',')}, " \
        "and its allow-list entry (#{allowed[path][:owner]}) says #{allowed[path][:scripts]}."
    end
    unlisted + stale + miscounted
  end

  # ------------------------------------------------------------- the verdict

  def test_unit_no_engine_view_carries_an_inline_script_outside_the_allow_list
    found = inline_scripts(VIEW_ROOT)

    assert_empty problems(found, ALLOWED), "inline scripts and the allow-list disagree"
  end

  def test_unit_every_allow_list_entry_names_its_owner_and_its_reason
    ALLOWED.each do |path, entry|
      assert_match(/\A[a-z0-9]+(-[a-z0-9]+)*\z/, entry[:owner], "#{path}: the owner is a task slug, or #{PERMANENT}")
      assert_operator entry[:why].to_s.length, :>, 10, "#{path}: say why the script is inline"
      assert_operator entry[:scripts], :>=, 1, "#{path}: an entry for no script is a stale entry"
    end
  end

  # The one permanent entry is the pre-paint script, and it carries the request's
  # CSP nonce. Nothing else is permanent.
  def test_unit_the_only_permanent_script_is_the_nonced_pre_paint_tag
    permanent = ALLOWED.select { |_path, entry| entry[:owner] == PERMANENT }.keys
    assert_equal ["layouts/studio/_head.html.erb"], permanent

    head = File.read(File.join(VIEW_ROOT, permanent.first)).gsub(ERB_COMMENT, "")
    assert_match(/<%= tag\.script\(nonce: studio_script_nonce\) do %>/, head,
                 "the pre-paint script lost its nonce, or is no longer rendered by tag.script")
  end

  # ------------------------------------------------- GUARD THE GUARD: reading

  # A walker that read nothing reports a clean tree.
  def test_unit_the_scan_reads_the_engine_s_views
    views = Dir.glob(File.join(VIEW_ROOT, "**", "*.erb"))
    assert_operator views.length, :>, 150, "the scan found only #{views.length} view(s) under #{VIEW_ROOT}"

    found = inline_scripts(VIEW_ROOT)
    assert_equal [8], found["layouts/studio/_head.html.erb"], "the scan lost the pre-paint tag.script"
    assert_equal 1, found.fetch("studio/_at_time_script.html.erb", []).length, "the scan lost a script tag in markup"
  end

  # ------------------------------------------------ GUARD THE GUARD: controls

  def with_views(files)
    Dir.mktmpdir("no_inline_script") do |root|
      files.each do |path, source|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), source)
      end
      yield root
    end
  end

  # CONTROL 1: a partial with a script fails, in every spelling.
  def test_unit_control_a_partial_with_a_script_fails_the_lint
    fixtures = {
      "widgets/_literal.html.erb" => "<div></div>\n<script>\n  window.x = 1;\n</script>\n",
      "widgets/_typed.html.erb" => %(<script type="module">import "x"</script>\n),
      "widgets/_src_with_body.html.erb" => %(<script src="/a.js">window.y = 2</script>\n),
      "widgets/_helper.html.erb" => "<p></p>\n<%= javascript_tag nonce: true do %>\n  window.z = 3;\n<% end %>\n",
      "widgets/_tag_helper.html.erb" => "<%= tag.script(nonce: nonce) do %>\n  1\n<% end %>\n",
      "widgets/_content_tag.html.erb" => %(<%= content_tag(:script, "1".html_safe) %>\n),
      "widgets/_unclosed.html.erb" => "<script>\n  window.w = 4;\n"
    }

    with_views(fixtures) do |root|
      found = inline_scripts(root)

      assert_equal fixtures.keys.sort, found.keys.sort
      assert_equal [2], found["widgets/_literal.html.erb"], "the line is the script tag's own"
      assert_equal [2], found["widgets/_helper.html.erb"]
      assert_equal fixtures.length, problems(found, {}).length
      assert_match(/widgets\/_literal\.html\.erb:2 carries an inline script/, problems(found, {}).join("\n"))
    end
  end

  # ... and what is not a script does not fail.
  def test_unit_control_what_only_mentions_a_script_passes
    fixtures = {
      "widgets/_comment.html.erb" => "<%# a <script> inside this template never runs:\n    <script>alert(1)</script> %>\n<p></p>\n",
      "widgets/_ruby_string.html.erb" => %(<% note = "a <script> in the board template never runs" %>\n<p><%= note %></p>\n),
      "widgets/_html_comment.html.erb" => "<!-- <script>old()</script> -->\n<p></p>\n",
      "widgets/_external.html.erb" => %(<script defer src="https://cdn.example/lib.js"></script>\n),
      "widgets/_loaders.html.erb" => %(<%= javascript_importmap_tags %>\n<%= javascript_import_module_tag "studio/application" %>\n) +
                                      %(<%= javascript_include_tag "studio/alpine", defer: true %>\n),
      "widgets/_anchor.html.erb" => %(<template data-studio-controller="email-banner-scale"></template>\n)
    }

    with_views(fixtures) { |root| assert_equal({}, inline_scripts(root)) }
  end

  # CONTROL 2: an allow-list entry whose file no longer has a script fails.
  def test_unit_control_a_stale_allow_list_entry_fails
    fixtures = {
      "widgets/_still_inline.html.erb" => "<script>1</script>\n",
      "widgets/_converted.html.erb" => %(<template data-studio-controller="widget"></template>\n)
    }
    allowed = {
      "widgets/_still_inline.html.erb" => { scripts: 1, owner: "some-task", why: "not converted yet" },
      "widgets/_converted.html.erb" => { scripts: 1, owner: "some-task", why: "not converted yet" },
      "widgets/_deleted.html.erb" => { scripts: 1, owner: "some-task", why: "not converted yet" }
    }

    with_views(fixtures) do |root|
      found = inline_scripts(root)

      assert_equal ["widgets/_converted.html.erb is on the allow-list (some-task) and carries no inline script. Delete its line.",
                    "widgets/_deleted.html.erb is on the allow-list (some-task) and carries no inline script. Delete its line."],
                   problems(found, allowed)
      assert_empty problems(found, allowed.slice("widgets/_still_inline.html.erb")), "a live entry is not stale"
    end
  end

  # CONTROL 3: an entry does not cover a second script in its file.
  def test_unit_control_a_second_script_in_an_allowed_file_fails
    with_views("widgets/_two.html.erb" => "<script>1</script>\n<p></p>\n<script>2</script>\n") do |root|
      found = inline_scripts(root)
      allowed = { "widgets/_two.html.erb" => { scripts: 1, owner: "some-task", why: "one script was allowed" } }

      assert_equal ["widgets/_two.html.erb carries 2 inline script(s) at line(s) 1,3, and its allow-list entry (some-task) says 1."],
                   problems(found, allowed)
    end
  end
end
