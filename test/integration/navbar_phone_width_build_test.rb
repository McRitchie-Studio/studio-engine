# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "tailwindcss/ruby"

# [integration] The header's phone-width fix, compiled the way a CONSUMER
# compiles it — a real Tailwind v4 build whose content glob is the ENGINE'S OWN
# VIEWS, which is the arrangement every consuming app's config/tailwind.config.js
# actually uses:
#
#     content: ['./app/views/**/*.{erb,html}', …, `${studioPath}/app/views/**/*.{erb,html}`]
#
# WHY THIS TIER EXISTS, AND WHY A MARKUP TEST IS NOT ENOUGH. The fix in
# layouts/_navbar is half inline CSS (the two width caps, which ship verbatim
# inside the partial's own <style> element and cannot fail to arrive) and half
# TAILWIND UTILITIES — min-w-0 on four elements and truncate on two. A utility
# only exists in a consumer's stylesheet if that consumer's build SAW it used.
# The engine is a gem: its ERB is not in any app's default glob, it is there
# only because every consumer opts in with that studioPath line. If a consumer
# ever drops it — or if Tailwind stops matching a class inside an ERB attribute
# — `min-w-0` silently resolves to nothing, the min-width: auto floor comes
# straight back, and the app name spills across the header again.
#
# The markup tier (test/views/navbar_phone_width_test.rb) asserts the classes
# are WRITTEN. This asserts they COMPILE. Neither implies the other, and the
# failure mode of the second is invisible in the first: the HTML is byte
# identical either way.
#
# Scanning the real app/views rather than a hand-written probe file is the whole
# point. A probe listing the class names would prove Tailwind can emit
# `.min-w-0` — which was never in doubt — and would stay green on the day the
# navbar stopped asking for it.
class NavbarPhoneWidthBuildTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  NAVBAR = File.join(ROOT, "app", "views", "layouts", "_navbar.html.erb")

  # The utilities the header's shrink behaviour is built out of. Each one is
  # load-bearing: min-w-0 defeats the flex `min-width: auto` floor, and truncate
  # is what the app name does INSTEAD of overflowing once that floor is gone.
  REQUIRED_UTILITIES = {
    "min-w-0" => "min-width: 0",
    "truncate" => "text-overflow: ellipsis"
  }.freeze

  def test_the_navbar_still_asks_for_the_utilities_this_test_compiles
    # The guard on the guard. Everything below compiles app/views and looks for
    # utilities in the output — but Tailwind emits a utility because SOMETHING
    # in the glob used it, and app/views is a large glob. If the navbar itself
    # stopped carrying these, another partial would keep the compiled assertions
    # green over a header that had lost the fix.
    # CLASS ATTRIBUTES ONLY. The partial's ERB comments explain the min-w-0
    # chain in prose, so a bare scan of the file counts the explanation as
    # evidence of the thing it explains — 7 matches for 4 real elements. Counted
    # wrong on the first run of this very test.
    # BOTH SPELLINGS. The logo link is a `link_to ..., class: "..."` Ruby
    # keyword, not an HTML attribute, so an attribute-only scan finds 3 of the
    # 4 and reports the chain broken while it is intact. Measured, on the second
    # run of this test.
    classes = File.read(NAVBAR).scan(/class(?:=|: )"([^"]*)"/).flatten.join(" ")

    assert_equal 4, classes.scan(/\bmin-w-0\b/).length,
      "the navbar's min-w-0 chain is four elements deep (row item, inner flex, " \
      "logo link, h1) — a different count means the chain changed and the " \
      "compiled assertions below are no longer about this header"
    assert_equal 2, classes.scan(/\btruncate\b/).length,
      "both app-name spans truncate"
  end

  def test_a_consumer_build_scanning_engine_views_emits_the_shrink_utilities
    out_css = compile_consumer_style_build

    REQUIRED_UTILITIES.each do |utility, declaration|
      assert_match(/^\s*\.#{Regexp.escape(utility)} \{/, out_css,
        ".#{utility} was not emitted by a build whose glob is the engine's own " \
        "views. Every consuming app reaches the engine's partials through that " \
        "same glob, so the header ships with no fix in any of them.")
      assert_includes out_css, declaration,
        ".#{utility} compiled without #{declaration}"
    end
  end

  def test_the_inline_width_caps_ship_in_the_partial_not_the_stylesheet
    # The other half, and the reason it was written as inline CSS rather than as
    # arbitrary Tailwind variants: the caps are inside the partial's own <style>
    # element, so they arrive with the markup and depend on no build at all.
    # This pins that division — a later hand moving them into a utility would be
    # making them dependent on the glob this file exists to distrust.
    source = File.read(NAVBAR)

    assert_includes source, ".user-nav-col { width: min(14rem, 46vw); }"
    assert_includes source, ".user-nav-fit { max-width: min(14rem, 46vw); }"

    refute_match(/class="[^"]*\bmax-\[/, source,
      "the width caps must not become arbitrary-value utilities — those need " \
      "the consumer glob the inline <style> deliberately does not need")
  end

  private

  def compile_consumer_style_build
    Dir.mktmpdir("studio-engine-navbar-width") do |dir|
      File.write(File.join(dir, "tailwind.config.js"), <<~JS)
        const studio = require('#{ROOT}/tailwind/studio.tailwind.config.js')
        module.exports = {
          content: ['#{ROOT}/app/views/**/*.{erb,html}'],
          theme: studio.theme
        }
      JS

      File.write(File.join(dir, "input.css"), <<~CSS)
        @import 'tailwindcss';
        @config '#{dir}/tailwind.config.js';
        @import '#{ROOT}/app/assets/tailwind/studio_engine/engine.css';
      CSS

      out_path = File.join(dir, "out.css")
      _stdout, stderr, status = Open3.capture3(
        Tailwindcss::Ruby.executable,
        "-i", File.join(dir, "input.css"), "-o", out_path
      )
      assert status.success?, "tailwind build failed:\n#{stderr}"
      File.read(out_path)
    end
  end
end
