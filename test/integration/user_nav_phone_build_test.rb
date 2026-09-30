# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "tailwindcss/ruby"

# [integration] The user nav's phone behaviour is built from responsive
# utilities that nothing else in the engine used before engine-navbar-phone-polish
# (md:not-sr-only and md:max-w-40). A utility only ships if a consumer's Tailwind
# build emits it, so compile the way a consumer does — the engine's own views as
# the glob, engine.css imported — and require each one, with its declaration,
# inside a 768px media block.
class UserNavPhoneBuildTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PARTIAL = File.join(ROOT, "app", "views", "components", "_user_nav.html.erb")

  RESPONSIVE = {
    "md\\:not-sr-only" => "position: static",
    "md\\:max-w-40" => "max-width:",
    "md\\:flex" => "display: flex"
  }.freeze

  def test_the_partial_still_asks_for_the_utilities_this_test_compiles
    classes = File.read(PARTIAL).scan(/class(?:=|: )"([^"]*)"/).flatten.join(" ")

    %w[sr-only md:not-sr-only md:max-w-40 hidden md:flex].each do |utility|
      assert_match(/(?:^|\s)#{Regexp.escape(utility)}(?:\s|$)/, classes, "#{utility} left the partial")
    end
  end

  def test_a_consumer_build_emits_the_phone_utilities
    css = compile_consumer_style_build

    assert_match(/^\s*\.sr-only \{/, css)
    RESPONSIVE.each do |selector, declaration|
      rule = css[/\.#{Regexp.escape(selector)} \{[^}]*\}/m]
      refute_nil rule, ".#{selector} was not emitted by a consumer-shaped build"
      assert_includes rule, declaration
    end
    assert_match(/@media \(width >= 48rem\)|min-width: 48rem|min-width: 768px/, css,
      "the md: variants must compile inside the 768px breakpoint")
  end

  private

  def compile_consumer_style_build
    Dir.mktmpdir("studio-engine-user-nav") do |dir|
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
      _stdout, stderr, status = Open3.capture3(Tailwindcss::Ruby.executable, "-i", File.join(dir, "input.css"), "-o", out_path)
      assert status.success?, "tailwind build failed:\n#{stderr}"
      File.read(out_path)
    end
  end
end
