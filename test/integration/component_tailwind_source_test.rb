# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "tailwindcss/ruby"

# [integration] A host's Tailwind build compiles the engine's component classes
# with no host edit.
#
# Studio::BadgeComponent keeps its colour classes in Ruby
# (app/components/studio/badge_component.rb), and every host's tailwind config
# scans only the engine's app/views. engine.css carries `@source` for
# app/components, so a host that imports engine.css (all of them) compiles the
# component's classes anyway. The probe builds the way a host does, with a
# content list that names no engine file at all, and looks for the tone classes
# that appear nowhere in the engine's views.
#
# The control builds a copy of engine.css with the @source line removed and
# shows the same classes are then missing, so the test fails if the line goes.
class ComponentTailwindSourceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  ENGINE_CSS = File.join(ROOT, "app/assets/tailwind/studio_engine/engine.css")
  SOURCE_LINE = '@source "../../../components";'

  # Classes the badge component emits that no engine view mentions, so only the
  # @source line can bring them into the build.
  def component_only_classes
    unless defined?(Studio::BadgeComponent)
      require "view_component"
      require_relative "../../app/components/studio/badge_component"
    end
    classes = Studio::BadgeComponent::TONES.values.flat_map(&:split).uniq
    views = Dir[File.join(ROOT, "app/views/**/*.erb")].map { |path| File.read(path) }.join("\n")
    classes.reject { |name| views.include?(name) }
  end

  def test_the_component_classes_compile_through_engine_css
    names = component_only_classes
    refute_empty names, "every tone class also appears in an engine view, so this probe proves nothing"

    css = compile(ENGINE_CSS)
    names.each do |name|
      assert_includes css, ".#{escape(name)}", "#{name} is missing from a host-shaped build"
    end
  end

  def test_control_without_the_source_line_the_classes_are_missing
    names = component_only_classes
    source = File.read(ENGINE_CSS)
    assert_includes source, SOURCE_LINE

    # Beside the real file, so the @source path and every other relative path
    # in the copy resolve exactly as they do in the original.
    copy = File.join(File.dirname(ENGINE_CSS), "engine-control-#{Process.pid}.css")
    File.write(copy, source.sub(SOURCE_LINE, ""))
    begin
      css = compile(copy)
    ensure
      FileUtils.rm_f(copy)
    end
    names.each do |name|
      refute_includes css, ".#{escape(name)}", "#{name} compiled without the @source line; the probe is not isolating it"
    end
  end

  private

  def escape(name)
    name.gsub("/", "\\/")
  end

  def compile(engine_css)
    Dir.mktmpdir("studio-engine-tw-components") do |dir|
      File.write(File.join(dir, "probe.html"), %(<div class="card"></div>\n))
      File.write(File.join(dir, "tailwind.config.js"), <<~JS)
        const studio = require('#{ROOT}/tailwind/studio.tailwind.config.js')
        module.exports = { content: ['#{dir}/probe.html'], theme: studio.theme }
      JS
      File.write(File.join(dir, "input.css"), <<~CSS)
        @import 'tailwindcss' source(none);
        @config '#{dir}/tailwind.config.js';
        @import '#{engine_css}';
      CSS

      out_path = File.join(dir, "out.css")
      _stdout, stderr, status = Open3.capture3(
        Tailwindcss::Ruby.executable, "-i", File.join(dir, "input.css"), "-o", out_path
      )
      assert status.success?, "tailwind build failed:\n#{stderr}"
      File.read(out_path)
    end
  end
end
