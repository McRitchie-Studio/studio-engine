# frozen_string_literal: true

require "test_helper"
require "pathname"
require_relative "../support/engine_tailwind_build"

# [integration] Every class the engine's views, components, helpers and
# JavaScript emit is in a host's build with no host edit and no safelist.
#
# A host's build is `@import "tailwindcss"` plus the engine's one import, and
# nothing else: no content glob naming the gem, no safelist, no `@config`. The
# engine reaches its own classes through the @source lines in engine.css. The
# expected set is read independently of Tailwind's scanner
# (EngineTailwindBuild.emitted_classes: every quoted word in those files that
# compiles as a class), so a directory the scan misses shows up as missing
# classes here rather than as an unstyled page in a host.
#
# Studio::BadgeComponent is the original case: it keeps its colour classes in
# Ruby (app/components/studio/badge_component.rb), which no host ever scanned.
class ComponentTailwindSourceTest < Minitest::Test
  B = EngineTailwindBuild
  ENGINE_DIR = Pathname(File.dirname(B::ENGINE_CSS))
  SOURCE_LINE = '@source "../../../components";'

  def self.full = @full ||= B.classes_in_css(B.compile([]))

  def test_every_class_each_directory_emits_is_in_the_build
    B.emitted_classes.each do |dir, classes|
      assert_operator classes.size, :>, 0, "#{dir} emits no class at all; the harness read nothing"
      missing = classes - self.class.full
      assert_empty missing, "#{dir} emits classes a host's build lacks, so they paint nothing: #{missing.to_a.sort.first(20).inspect}"
    end
    assert_operator B.emitted_classes["app/views"].size, :>, 300, "the views emit too few classes for this to mean anything"
  end

  # THE STRUCTURAL MUTATION. Every emitting directory is named by an @source
  # line; removing any one line from engine.css makes uncovered_dirs name it.
  def test_every_emitting_directory_has_a_source_line
    css = File.read(B::ENGINE_CSS)
    assert_empty uncovered_dirs(css), "engine.css scans no source for these emitting directories"

    lines = B.source_lines
    assert_equal B::EMITTING_DIRS.size, lines.size, "one @source line per emitting directory"
    lines.each do |line|
      refute_empty uncovered_dirs(css.sub(line, "")), "removing #{line} went unnoticed"
    end
  end

  # Exclusions stay NARROW. The hub's `@source not "../../../vendor/bundle"`
  # once dropped the engine's own sources in CI, because the gem lives under
  # vendor/bundle there. An engine exclusion names vendored third-party code
  # only, and never a directory that emits engine markup.
  def test_exclusions_name_only_vendored_third_party_code
    nots = File.read(B::ENGINE_CSS).lines.grep(/\A@source not /).map { |l| l[/"(.*)"/, 1] }
    refute_empty nots
    nots.each do |pattern|
      path = ENGINE_DIR.join(pattern).cleanpath.relative_path_from(Pathname(B::ROOT)).to_s
      refute_includes B::EMITTING_DIRS, path, "#{pattern} excludes a whole emitting directory"
      refute_match(/vendor\/bundle|\*\*/, pattern, "#{pattern} is a broad exclusion")
      expanded = Dir.glob(File.join(B::ROOT, path)).map { |f| f.delete_prefix("#{B::ROOT}/") }
      refute_empty expanded, "#{pattern} excludes nothing"
      expanded.each do |file|
        next if File.directory?(file)

        assert_includes B::VENDORED, file, "#{pattern} excludes #{file}, which is engine code"
      end
    end
  end

  # Classes the badge component emits that no engine view mentions, so only
  # the components @source line can bring them into the build.
  def component_only_classes
    unless defined?(Studio::BadgeComponent)
      require "view_component"
      require_relative "../../app/components/studio/badge_component"
    end
    classes = Studio::BadgeComponent::TONES.values.flat_map(&:split).uniq
    views = Dir[File.join(B::ROOT, "app/views/**/*.erb")].map { |path| File.read(path) }.join("\n")
    classes.reject { |name| views.include?(name) }
  end

  def test_the_component_classes_compile_through_engine_css
    names = component_only_classes
    refute_empty names, "every tone class also appears in an engine view, so this probe proves nothing"

    names.each { |name| assert_includes self.class.full, name, "#{name} is missing from a host-shaped build" }
  end

  def test_control_without_the_source_line_the_classes_are_missing
    names = component_only_classes
    css = B.with_variant(->(source) { B.strip_line(source, SOURCE_LINE) }) { |path| B.classes_in_css(B.compile([], engine_css: path)) }

    names.each do |name|
      refute_includes css, name, "#{name} compiled without the @source line; the probe is not isolating it"
    end
  end

  private

  # The emitting directories no @source line in `css` reaches.
  def uncovered_dirs(css)
    sourced = css.lines.grep(/\A@source "/).map { |l| ENGINE_DIR.join(l[/"(.*)"/, 1]).cleanpath.to_s }
    B::EMITTING_DIRS.reject do |dir|
      abs = File.join(B::ROOT, dir)
      sourced.any? { |s| abs == s || abs.start_with?("#{s}/") }
    end
  end
end
