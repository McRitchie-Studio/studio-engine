# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"

# [unit] No engine code may write the legacy rgba(var(--x-rgb), A) colour form.
#
# THE BUG. Studio::ThemeResolver#primary_palette_vars emits every RGB-triple
# custom property as a SPACE-separated list: `--color-primary-500-rgb: 142 130 254`.
# The legacy comma form `rgba(var(--color-primary-500-rgb), 0.12)` substitutes to
# `rgba(142 130 254, 0.12)`, which mixes the space and comma syntaxes and is
# INVALID. A browser reports nothing: the declaration is invalid at computed-value
# time, so the property falls back to its initial value and paints NOTHING.
#
# Two engine surfaces shipped it, on main and accepted alike, in every consumer:
#   - layouts/studio/_flash.html.erb — `.dark .toast-blur-glow`, the tinted halo a
#     toast opts into with blurShadow: true. Dark mode got no halo at all.
#   - studio/modals/blocks/_success_card.html.erb — the tinted backing of the
#     branded Solana explorer link (tx_solana: true), blank in both themes.
# turf-monster found the same form in its own glows (turf PR 752, task
# legacy-rgba-glows-never-render); this is the engine half.
#
# MEASURED, not inferred (task engine-legacy-rgba-backgrounds). A static page
# loading the consumer-style compiled Tailwind build, the resolver's real theme
# vars, the flash partial's own <style> block and the RENDERED success card, read
# in headless Chromium: before the fix the dark glow and the explorer link both
# computed `background-color: rgba(0, 0, 0, 0)`; after it, the glow computed
# `rgba(142, 130, 254, 0.12)` and the link `rgba(142, 130, 254, 0.06)`. A control
# element with the slash form painted on the same page throughout.
#
# THE FIX is the slash form `rgb(var(--x-rgb) / A)`, which is valid for a space
# list and is what engine-motion.css and the Tailwind preset already write.
#
# WHY THE LEGACY FORM IS REFUSED OUTRIGHT rather than only where a var happens to
# be a space list: every triple the engine defines IS one, and the last test below
# pins that premise. A comma triple would have to be introduced on purpose, so the
# refusal costs nothing and needs no var-by-var resolution to stay honest.
#
# WHAT IS SCANNED. Every code file the GEM SHIPS (the gemspec's own file list, so a
# new directory is covered the day it is packaged), read WHOLE rather than line by
# line so a declaration wrapped across lines is still seen; the Studio::UiPrimitives
# *_CSS strings as Ruby evaluates them; and a real consumer-style Tailwind build of
# engine.css + engine-motion.css + the preset's alpha utilities. The build cannot
# see an inline style="" or a <style> block in a view, which is where both shipped
# offenders lived, so the source scan is the half that would have caught them.
#
# A BLIND SPOT, stated plainly. A colour string assembled at runtime from pieces
# (`'rgba(' + v + ', .5)'` in JS, interpolation in Ruby) is not visible to a text
# scan. None exists in the engine today.
class LegacyRgbaVarGuardTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)

  # `rgb(` or `rgba(`, then `var(--name)` — optionally with a fallback, which may
  # itself hold ONE level of parentheses (`var(--a, var(--b))`) — then a COMMA. The
  # slash form puts `/` there and a bare `rgb(var(--x))` puts `)`, so only the
  # legacy form matches. `\s` spans newlines, so a wrapped declaration matches too.
  LEGACY_FORM = /rgba?\(\s*var\(\s*--[\w-]+(?:\s*,(?:[^()]|\([^()]*\))*)?\s*\)\s*,/

  CODE_EXTENSIONS = %w[.css .erb .js .mjs .rb].freeze

  # Utilities built from the preset's `rgb(var(--…-rgb) / <alpha-value>)` colour
  # templates, so the compiled scan covers what the preset generates, not only the
  # hand-written component CSS.
  PRESET_ALPHA_PROBES = %w[
    bg-primary/50 bg-primary-500/15 border-primary/30 border-primary-700/40
    text-primary/80 ring-primary/20 shadow-primary/40 from-primary/60
  ].freeze

  def self.shipped_code_files
    @shipped_code_files ||= Dir.chdir(ROOT) do
      Gem::Specification.load(File.join(ROOT, "studio-engine.gemspec"))
                        .files.select { |f| CODE_EXTENSIONS.include?(File.extname(f)) }.sort
    end
  end

  def self.compiled_css
    @compiled_css ||= EngineTailwindBuild.compile(PRESET_ALPHA_PROBES, motion: true)
  end

  def test_the_detector_bites_the_legacy_form_and_passes_the_slash_form
    legacy = [
      "background: rgba(var(--color-primary-500-rgb), 0.12);",            # the shipped flash line
      'style="background: rgba(var(--color-primary-500-rgb), 0.06);"',   # the shipped success-card line
      "box-shadow:0 0 6px rgba(var(--color-primary-500-rgb),.3)",         # as a minifier writes it
      "background: rgba( var( --color-primary-rgb ), 0.12 );",
      "color: rgb(var(--color-primary-rgb), 0.5)",
      "color: rgba(var(--glow-rgb, 1 2 3), 0.5)",
      "color: rgba(var(--success-glow-rgb, var(--color-primary-800-rgb)), 0.4)",
      "box-shadow: 0 0 6px rgba(\n    var(--color-primary-rgb),\n    0.3\n  );"
    ]
    legacy.each { |line| assert_match LEGACY_FORM, line, "detector missed: #{line.inspect}" }

    modern = [
      "background: rgb(var(--color-primary-500-rgb) / 0.12);",
      "box-shadow:0 0 6px rgb(var(--color-primary-500-rgb)/.3)",
      "outline: 3px solid rgb(var(--color-primary-rgb));",
      "color: rgba(var(--color-primary-rgb) / 0.5)",
      "border-color: rgb(var(--level-mint-rgb, 6 214 160) / 0.85);",
      "box-shadow: 0 0 40px rgb(var(--success-glow-rgb, var(--color-primary-800-rgb)) / 0.7)",
      "--bg-from: var(--hold-bg-from, rgb(var(--color-primary-400-rgb)));",
      'rgba(#{r},#{g},#{b},#{opacity})', # Studio::ColorScale.with_opacity's literal
      "the legacy rgba(var(...), A) form is silently dropped" # engine-motion.css's own warning prose
    ]
    modern.each { |line| assert_no_match LEGACY_FORM, line, "detector false positive: #{line.inspect}" }
  end

  def test_no_shipped_engine_code_file_writes_the_legacy_form
    files = self.class.shipped_code_files
    # Floor, not a count: the gemspec packaged 280 code files when this was written.
    assert_operator files.size, :>, 200, "the gemspec scan found too few files to mean anything"
    %w[app/views/layouts/studio/_flash.html.erb app/views/studio/modals/blocks/_success_card.html.erb
       app/assets/tailwind/studio_engine/engine-motion.css lib/studio/ui_primitives.rb].each do |known|
      assert_includes files, known, "the scan no longer reads #{known}, a file this guard exists for"
    end

    offenders = files.flat_map do |path|
      source = File.read(File.join(ROOT, path))
      hits = []
      source.scan(LEGACY_FORM) do
        at = Regexp.last_match.begin(0)
        line = source[0, at].count("\n") + 1
        hits << "#{path}:#{line}: #{source.lines[line - 1].strip}"
      end
      hits
    end

    assert_empty offenders, <<~MSG
      Legacy rgba(var(--x), A) in shipped engine code. The engine's RGB-triple vars are
      space-separated lists, which make that form invalid: the declaration drops and
      paints nothing, with no error anywhere. Write rgb(var(--x-rgb) / A) instead:
      #{offenders.join("\n")}
    MSG
  end

  def test_the_ui_primitive_css_strings_write_no_legacy_form
    constants = Studio::UiPrimitives.constants.grep(/_CSS\z/)
    assert_not_empty constants, "Studio::UiPrimitives exposes no *_CSS strings; this scan reads nothing"

    offenders = constants.select { |c| Studio::UiPrimitives.const_get(c).to_s.match?(LEGACY_FORM) }
    assert_empty offenders, "Studio::UiPrimitives CSS carries legacy rgba(var(--x), A): #{offenders.inspect}"
  end

  def test_the_compiled_consumer_build_writes_no_legacy_form
    css = self.class.compiled_css
    # Proof the build carries what it is being checked for, so an empty or broken
    # build cannot pass: the motion layer's slash-form glows, and a preset utility.
    assert_includes css, "rgb(var(--color-primary-500-rgb) / 0.15)",
      "the compiled build is missing engine-motion.css's slash-form glows"
    assert_match(/\.bg-primary\\\/50\b/, css, "the compiled build is missing the preset's alpha utilities")

    offenders = []
    css.scan(LEGACY_FORM) do
      at = Regexp.last_match.begin(0)
      offenders << "offset #{at}: #{css[[at - 60, 0].max, 140]}"
    end
    assert_empty offenders, <<~MSG
      The consumer-style Tailwind build of the engine carries legacy rgba(var(--x), A),
      which a browser silently DROPS for a space-separated RGB var. Rewrite each as
      rgb(var(--x-rgb) / A):
      #{offenders.join("\n")}
    MSG
  end

  def test_every_rgb_triple_var_the_engine_defines_is_a_space_separated_list
    # The premise the refusal above rests on. If this ever fails, a comma triple has
    # entered the engine, and the refusal needs rethinking rather than a bypass.
    palettes = [{}, { primary: "#4BAF50" }, { primary: "#2E7D32", dark: "#0B0F19", light: "#FFFFFF" }]
    theme_css = palettes.map { |colors| Studio::ThemeResolver.new(colors).to_css }.join("\n")
    sources = self.class.shipped_code_files.map { |p| File.read(File.join(ROOT, p)) }
    definitions = ([theme_css, self.class.compiled_css] + sources).join("\n")
                                                                   .scan(/(--[\w-]+-rgb)\s*:\s*([^;}"]+)/)

    assert_operator definitions.count { |name, _| name.start_with?("--color-primary-") }, :>=, 11 * palettes.size,
      "expected the resolver's primary palette triples; the scan is not reading them"

    commas = definitions.reject do |_name, value|
      value = value.strip
      value.match?(/\A\d{1,3} \d{1,3} \d{1,3}\z/) || value.start_with?("var(")
    end
    assert_empty commas.uniq, "RGB-triple vars that are not a space-separated list: #{commas.uniq.inspect}"
  end
end
