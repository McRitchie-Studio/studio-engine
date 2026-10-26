# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"

# [integration] The deprecated JS preset and the CSS-first theme compile the
# SAME utilities, for the one release both exist.
#
# Hosts adopt the CSS-first layer on their own cards. Until each does, it still
# builds with `@config` and tailwind/studio.tailwind.config.js, now ON TOP of the
# engine's @theme (engine.css imports theme.css). So the two definitions must
# agree, or a host's colours move the day it bumps the gem, before it adopts.
# This test goes when the shim goes.
class TailwindPresetParityTest < Minitest::Test
  B = EngineTailwindBuild
  PRESET = File.join(B::ROOT, "tailwind/studio.tailwind.config.js")

  # Every token the preset defines, in each utility family that reads it, bare
  # and with an opacity modifier, plus the ones neither must mint.
  def self.tokens
    colours = %w[page surface surface-alt inset mint navy violet primary mist lavender slate charcoal midnight ember gold magenta] +
              (%w[mint navy violet primary].product(%w[50 100 200 300 400 500 600 700 800 900]).map { |c, s| "#{c}-#{s}" })
    utility = %w[bg text border ring].product(colours).map { |u, c| "#{u}-#{c}" }
    utility + utility.map { |u| "#{u}/40" } + %w[
      text-heading text-body text-secondary text-muted text-danger-ink text-warning-ink text-success-ink text-primary-ink
      bg-success bg-warning bg-danger bg-danger/10 border-subtle border-strong border-success border-warning border-danger
      text-danger text-warning text-success bg-heading text-subtle font-sans font-mono font-serif text-2xs text-3xs
      dark:bg-surface dark:text-heading
    ]
  end

  def utilities(css)
    css[/@layer utilities \{.*\z/m].to_s.gsub(" / 1)", ")")
  end

  def compile_probe(head)
    Dir.mktmpdir("studio-engine-parity") do |dir|
      probe = File.join(dir, "probe.html")
      File.write(probe, %(<div class="#{self.class.tokens.join(' ')}"></div>\n))
      B.compile_entry("@import 'tailwindcss' source(none);\n#{head.call(dir, probe)}")
    end
  end

  def preset_head(dir, probe)
    File.write(File.join(dir, "tailwind.config.js"),
               "const studio = require('#{PRESET}')\n" \
               "module.exports = { darkMode: 'class', content: ['#{probe}'], theme: studio.theme }\n")
    "@config '#{dir}/tailwind.config.js';\n"
  end

  def test_the_preset_and_theme_css_compile_identical_utilities
    preset = compile_probe(->(dir, probe) { preset_head(dir, probe) })
    theme  = compile_probe(->(_dir, probe) { "@import '#{B::THEME_CSS}';\n@source '#{probe}';\n" })

    assert_operator B.classes_in_css(theme).size, :>, 300, "the probe compiled too little to compare"
    assert_equal utilities(preset), utilities(theme)
  end

  # A host mid-migration: its own `@config` with the shim, then the engine's
  # import, which now carries @theme, the sources and the motion layer. It must
  # build, and lose nothing the CSS-first build has.
  def test_a_host_still_on_config_builds_on_top_of_the_css_first_engine
    both = compile_probe(->(dir, probe) { "#{preset_head(dir, probe)}@import '#{B::ENGINE_CSS}';\n" })
    css_first = B.compile(self.class.tokens)

    missing = B.classes_in_css(css_first) - B.classes_in_css(both)
    assert_empty missing, "a host still on @config loses classes: #{missing.to_a.sort.first(20).inspect}"
  end
end
