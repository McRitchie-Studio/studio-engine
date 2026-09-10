# frozen_string_literal: true

require "tmpdir"
require "open3"
require "set"
require "tailwindcss/ruby"

# The consumer-style Tailwind v4 build of the engine vocabulary: Tailwind core,
# the shared preset via @config, engine.css, and optionally the opt-in
# engine-motion.css, in the order every consuming app imports them
# (test/integration/tailwind_probe_build_test.rb is the precedent).
#
# Shared by the tests that must decide whether a class PAINTS, not whether it is
# spelled: test/views/engine_class_vocabulary_test.rb and
# test/integration/sign_in_overlay_blur_test.rb. It depends on nothing but the
# tailwindcss-ruby binary, so it loads under test_helper and the dummy app alike.
module EngineTailwindBuild
  ROOT       = File.expand_path("../..", __dir__)
  PRESET     = File.join(ROOT, "tailwind/studio.tailwind.config.js")
  ENGINE_CSS = File.join(ROOT, "app/assets/tailwind/studio_engine/engine.css")
  MOTION_CSS = File.join(ROOT, "app/assets/tailwind/studio_engine/engine-motion.css")

  module_function

  # The compiled CSS for a probe that names exactly `tokens`.
  #
  # source(none) makes the probe the ONLY source. Without it, Tailwind v4's
  # automatic source detection scans the working directory, which is this repo:
  # an empty probe then compiled to 75 KB carrying every utility the engine's
  # views, docs and tests mention. No verdict of the vocabulary guard changed
  # (a phantom class compiles nowhere), but a build meant to answer "what do
  # these tokens add?" could not answer it.
  def compile(tokens, motion:)
    Dir.mktmpdir("studio-engine-vocab") do |dir|
      File.write(File.join(dir, "probe.html"), %(<div class="#{tokens.join(' ')}"></div>\n))
      File.write(File.join(dir, "tailwind.config.js"),
                 "const studio = require('#{PRESET}')\n" \
                 "module.exports = { darkMode: 'class', content: ['#{dir}/probe.html'], theme: studio.theme }\n")
      input = +"@import 'tailwindcss' source(none);\n@config '#{dir}/tailwind.config.js';\n@import '#{ENGINE_CSS}';\n"
      input << "@import '#{MOTION_CSS}';\n" if motion
      File.write(File.join(dir, "input.css"), input)

      out = File.join(dir, "out.css")
      _stdout, stderr, status = Open3.capture3(Tailwindcss::Ruby.executable,
                                               "-i", File.join(dir, "input.css"), "-o", out)
      raise "tailwind build failed:\n#{stderr}" unless status.success?

      File.read(out)
    end
  end

  # Class names a stylesheet defines — escapes decoded (`hover\:x`, `\32 xl`).
  # A superset by construction (a decimal like `.5rem` reads as a "class"), so it
  # can only ever over-credit a token, never falsely accuse one.
  def classes_in_css(css)
    css.gsub(%r{/\*.*?\*/}m, "")
       .scan(/\.((?:\\[0-9a-fA-F]{1,6}\s?|\\.|[A-Za-z0-9_-])+)/)
       .flatten
       .to_set { |raw| raw.gsub(/\\([0-9a-fA-F]{1,6})\s?/) { [::Regexp.last_match(1).hex].pack("U") }.gsub(/\\(.)/, '\1') }
  end
end
