# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"

# [unit] No engine view, component, helper or script ASSEMBLES a Tailwind class
# at render time.
#
# Tailwind compiles only the class names it can read in source. engine.css's
# @source lines read every file that emits a class, but a name built from
# pieces (`bg-<%= tone %>/15`, `min-w-[#{width}px]`, `btn-${variant}`) is not in
# any file, so it compiled only in a host whose own markup or safelist happened
# to spell the same name. That is what the hosts' ~240-class safelists papered
# over. This guard refuses the shape; spell each variant whole in a literal map
# (modals/blocks/_card_header) or use an inline style (admin_model_table).
#
# What counts: a word glued to an ERB output tag or a Ruby / JS interpolation
# whose stem is a Tailwind or engine utility family. The stem is decided by
# Tailwind itself: it is a utility family if any common value under it compiles
# (bg-primary, btn-sm, min-w-[1px], ...). A plain class (knowledge-chip-<%= level %>,
# level-badge-<%= n %>) is always in the stylesheet, so assembling one is fine.
class DynamicTailwindClassGuardTest < ActiveSupport::TestCase
  B = EngineTailwindBuild

  INTERP = /(?:<%=|#\{|\$\{)/
  # stem-<interp>  and  stem-[...<interp>
  GLUED     = /(?<![\w\-:\[\]\/.!$#{}])((?:[a-z0-9]+:)*-?[a-z][a-z0-9-]*?)-(?=#{INTERP.source})/
  ARBITRARY = /(?<![\w\-:\[\]\/.!])((?:[a-z0-9]+:)*-?[a-z][a-z0-9-]*?)-\[[^\]\s"']*#{INTERP.source}/

  VALUES = %w[primary mint red-500 4 2 sm lg xs full auto primary/15 [1px]].freeze

  def self.stems_in(source)
    source.scan(GLUED).flatten.map { |s| s.split(":").last.delete_prefix("-") } +
      source.scan(ARBITRARY).flatten.map { |s| s.split(":").last.delete_prefix("-") }
  end

  # stem => true when Tailwind (with the engine's theme and @utility set, and
  # none of its sources) compiles any common value under it.
  def self.utility_stem?(stem)
    @utility_stem ||= {}
    @utility_stem.fetch(stem) do
      @floor ||= B.classes_in_css(B.compile([], sources: false))
      probes = VALUES.map { |v| "#{stem}-#{v}" }
      @utility_stem[stem] = (B.classes_in_css(B.compile(probes, sources: false)) - @floor).any?
    end
  end

  def test_the_detector_reads_the_assembled_shapes
    assert_equal %w[bg text], self.class.stems_in(%(class="bg-<%= tone %>/15 text-<%= tone %>"))
    assert_equal %w[border-t], self.class.stems_in(%(class="border-t-<%= color %>"))
    assert_equal %w[btn], self.class.stems_in(%(%(<button class="btn btn-\#{name}">)))
    assert_equal %w[ring], self.class.stems_in("el.classList.add(`ring-${tone}`)")
    assert_equal %w[min-w], self.class.stems_in(%(class: "w-full min-w-[\#{min_width}px]"))
    assert_equal %w[bg], self.class.stems_in(%(class="hover:bg-<%= tone %>"))
    assert_empty self.class.stems_in(%(style="--fizz-c-\#{i}:red"))
    assert_empty self.class.stems_in(%(properties.push([`--color-${role}-fill`])))
  end

  def test_the_stem_test_tells_a_utility_from_a_plain_class
    %w[bg text border-t ring btn min-w].each { |stem| assert self.class.utility_stem?(stem), "#{stem} should read as a utility family" }
    %w[knowledge-chip knowledge-status level-badge models ftr-lockup].each do |stem|
      refute self.class.utility_stem?(stem), "#{stem} should read as a plain class or an id"
    end
  end

  def test_no_emitting_file_assembles_a_tailwind_class
    files = B::EMITTING_DIRS.flat_map { |dir| B.emitting_files(dir) }
    assert_operator files.size, :>, 200, "the scan read too few files to mean anything"

    offenders = files.flat_map do |path|
      File.read(path).each_line.with_index(1).flat_map do |line, number|
        self.class.stems_in(line).select { |stem| self.class.utility_stem?(stem) }
                                 .map { |stem| "#{path.delete_prefix("#{B::ROOT}/")}:#{number}: #{stem}-… in #{line.strip[0, 120]}" }
      end
    end

    assert_empty offenders, <<~MSG
      These assemble a Tailwind class at render time, so no @source scan can see it and
      it compiles only in a host that spells the same name itself. Spell each variant
      whole in a literal map, or use an inline style:
      #{offenders.join("\n")}
    MSG
  end
end
