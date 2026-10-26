# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"
require "tmpdir"
require "open3"
require "tailwindcss/ruby"

# [integration] The user nav's phone behaviour is built from responsive
# utilities that nothing else in the engine used before engine-navbar-phone-polish
# (md:not-sr-only and md:max-w-40). A utility only ships if a consumer's Tailwind
# build emits it, so compile the way a consumer does — engine.css imported, its
# own @source lines the only route to the views — and require each one, with its declaration,
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

  # The opt-in navbar settings after 0.113.0 (Studio.navbar_phone_name,
  # Studio.navbar_z_tier, Studio.navbar_header_bars) ask for arbitrary-value
  # utilities and engine.css rules no default render uses, so a consumer build
  # has to emit them from the engine's views alone.
  def test_a_consumer_build_emits_the_opt_in_navbar_utilities_and_rules
    css = compile_consumer_style_build

    { '.max-w-\\[4\\.5rem\\]' => "max-width: 4.5rem",
      '.min-\\[400px\\]\\:max-w-\\[6rem\\]' => "max-width: 6rem",
      '.z-\\[var\\(--z-nav\\)\\]' => "z-index: var(--z-nav)" }.each do |selector, declaration|
      rule = css[/#{Regexp.escape(selector)} \{[^}]*\}/m]
      refute_nil rule, "#{selector} was not emitted by a consumer-shaped build"
      assert_includes rule, declaration
    end
    assert_includes css, "@keyframes nav-name-fade"
    assert_includes css, "@keyframes nav-tl-header-bars"
    assert_match(/\[data-nav-name-phone\] *> *\[data-nav-name\]/, css)
  end

  private

  # A host-shaped build with NO host content: the engine's views reach it only
  # through engine.css's own @source lines.
  def compile_consumer_style_build
    EngineTailwindBuild.compile([])
  end
end
