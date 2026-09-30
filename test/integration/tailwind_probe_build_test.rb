# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "tailwindcss/ruby"

# Compiles the shipped component stylesheet through a REAL consumer-style
# Tailwind v4 build — preset spread via @config, engine.css pulled in via
# @import, exactly the shape every consumer app uses — and asserts the classes
# RESOLVE to theme-var-wired CSS. The name-level tests in component_css_test
# prove the right class names exist; this proves they compile: an @apply typo
# or a preset token rename fails here, not in a consumer's build.
class TailwindProbeBuildTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  PROBE_CLASSES = %w[
    card card-hover badge input-field empty-state json-debug label-upper
    btn btn-primary btn-secondary btn-outline btn-danger btn-warning
    btn-success btn-google btn-neutral btn-sm btn-lg text-2xs text-3xs
  ].freeze

  def test_consumer_style_build_emits_component_classes_wired_to_theme_vars
    out_css = compile_probe

    PROBE_CLASSES.each do |name|
      assert_match(/^\s*\.#{Regexp.escape(name)} \{/, out_css,
        ".#{name} missing from the compiled consumer build")
    end

    # Theme wiring survives compilation: the CTA role reaches the buttons...
    assert_includes out_css, "background-color: var(--color-cta-fill, var(--color-cta))"
    assert_includes out_css, "background-color: var(--color-cta-hover)"
    # ...including the hub's focus-visible ring...
    assert_includes out_css, "outline: 2px solid color-mix(in srgb, var(--color-cta) 70%, transparent)"
    # ...and the surface tokens reach the cards.
    assert_includes out_css, "background-color: var(--color-surface)"

    # The type tokens emit BARE font sizes (no line-height), so swapping
    # text-[11px]/text-[10px] for them cannot shift vertical rhythm.
    assert_match(/\.text-2xs \{\s*font-size: 0\.6875rem;\s*\}/, out_css)
    assert_match(/\.text-3xs \{\s*font-size: 0\.625rem;\s*\}/, out_css)
  end

  private

  def compile_probe
    Dir.mktmpdir("studio-engine-tw-probe") do |dir|
      File.write(File.join(dir, "probe.html"),
        %(<div class="#{PROBE_CLASSES.join(' ')}"></div>\n))

      File.write(File.join(dir, "tailwind.config.js"), <<~JS)
        const studio = require('#{ROOT}/tailwind/studio.tailwind.config.js')
        module.exports = { content: ['#{dir}/probe.html'], theme: studio.theme }
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
