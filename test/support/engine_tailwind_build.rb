# frozen_string_literal: true

require "tmpdir"
require "open3"
require "set"
require "securerandom"
require "fileutils"
require "tailwindcss/ruby"

# The consumer-style Tailwind v4 build of the engine, CSS-first: Tailwind core,
# then host.css, which brings engine.css (the theme and the component layer),
# the @source scan of the engine's own directories, and the motion layer
# (engine-motion.css). It is exactly the input a host's
# `@import "../builds/tailwind/studio_engine"` line resolves to
# (Studio::TailwindEntry). There is no `@config` and no JS preset any more.
#
# Shared by every test that must decide whether a class PAINTS, not whether it
# is spelled. It depends on nothing but the tailwindcss-ruby binary, so it loads
# under test_helper and the dummy app alike.
module EngineTailwindBuild
  ROOT        = File.expand_path("../..", __dir__)
  TAILWIND_DIR = File.join(ROOT, "app/assets/tailwind/studio_engine")
  ENGINE_CSS  = File.join(TAILWIND_DIR, "engine.css")
  THEME_CSS   = File.join(TAILWIND_DIR, "theme.css")
  MOTION_CSS  = File.join(TAILWIND_DIR, "engine-motion.css")
  HOST_CSS    = File.join(TAILWIND_DIR, "host.css")
  MOTION_IMPORT = '@import "./engine-motion.css";'

  module_function

  # The compiled CSS for a host-shaped build plus a probe that names `tokens`.
  #
  # source(none) on core stops Tailwind's automatic detection, which would scan
  # the working directory (this repo, docs and tests included). The engine's
  # OWN @source lines still apply, exactly as in a host, so the build carries
  # every class the engine emits plus the probe's.
  #
  # motion: false compiles host.css with its motion import removed, so a
  # caller can still ask which classes ONLY the motion layer defines.
  # sources: false removes host.css's @source lines, so the build carries
  # only what the probe names: the way to ask "what do these tokens add?".
  # engine_css: compiles a variant of host.css instead (see #with_variant).
  def compile(tokens, motion: true, sources: true, engine_css: nil)
    unless motion && sources
      transform = lambda do |css|
        css = strip_line(css, MOTION_IMPORT) unless motion
        css = strip_sources(css) unless sources
        css
      end
      return with_variant(transform) { |path| compile(tokens, engine_css: path) }
    end

    Dir.mktmpdir("studio-engine-tw") do |dir|
      probe = File.join(dir, "probe.html")
      File.write(probe, %(<div class="#{tokens.join(' ')}"></div>\n))
      File.write(File.join(dir, "input.css"),
                 "@import 'tailwindcss' source(none);\n@source '#{probe}';\n@import '#{engine_css || HOST_CSS}';\n")
      build(dir)
    end
  end

  # Builds `input` (a whole entry stylesheet) in a scratch directory.
  def compile_entry(input)
    Dir.mktmpdir("studio-engine-tw") do |dir|
      File.write(File.join(dir, "input.css"), input)
      build(dir)
    end
  end

  # Yields the path of a copy of host.css rewritten by `transform`, written
  # BESIDE the real file so every relative @import and @source in it resolves
  # exactly as in the original, and removed afterwards.
  def with_variant(transform)
    copy = File.join(TAILWIND_DIR, "host-variant-#{Process.pid}-#{SecureRandom.hex(4)}.css")
    File.write(copy, transform.call(File.read(HOST_CSS)))
    yield copy
  ensure
    FileUtils.rm_f(copy) if copy
  end

  # `css` without `line`, refusing to run when the line is not there, so a
  # control can never pass by removing nothing.
  def strip_line(css, line)
    raise ArgumentError, "host.css carries no #{line.inspect}" unless css.include?(line)

    css.sub(line, "")
  end

  # `css` with every @source line (sources and exclusions) removed.
  def strip_sources(css)
    css.lines.reject { |l| l.start_with?("@source") }.join
  end

  def build(dir)
    out = File.join(dir, "out.css")
    _stdout, stderr, status = Open3.capture3(Tailwindcss::Ruby.executable,
                                             "-i", File.join(dir, "input.css"), "-o", out)
    raise "tailwind build failed:\n#{stderr}" unless status.success?

    File.read(out)
  end

  # ── what the engine emits ───────────────────────────────────────────────

  # Every directory whose files put a class on a page. The rest of app/
  # (controllers, models, jobs, mailers, services) and lib/ write no markup:
  # their class-shaped strings are hash keys and comment prose.
  # app/assets/javascripts is not one: since the engine's scripts became ES
  # modules (app/javascript) it holds the vendored third-party builds and
  # studio/session.js, which emits no class (UNSCANNED_DIRS, asserted).
  EMITTING_DIRS = %w[app/views app/components app/helpers app/javascript].freeze

  # Third-party bundles vendored into the module tree. Not engine markup, and
  # host.css excludes them.
  VENDORED = %w[
    app/javascript/studio/vendor/stimulus.js
  ].freeze

  # Directories host.css does not scan because nothing in them puts a class on
  # a page. A claim, so ComponentTailwindSourceTest measures it.
  UNSCANNED_DIRS = %w[app/assets/javascripts].freeze
  UNSCANNED_VENDORED = %w[
    app/assets/javascripts/studio/alpine.js
    app/assets/javascripts/studio/canvas_confetti.js
    app/assets/javascripts/studio/leaflet.js
    app/assets/javascripts/studio/sortable.js
  ].freeze

  # The classes an unscanned directory's own (non-vendored) files would emit.
  def unscanned_classes(dir)
    files = Dir[File.join(ROOT, dir, "**/*.{erb,html,rb,js}")].reject { |f| UNSCANNED_VENDORED.include?(f.delete_prefix("#{ROOT}/")) }
    tokens = files.flat_map { |f| tokens_in(f) }.uniq
    floor = classes_in_css(compile([], sources: false))
    [files, classes_in_css(compile(tokens, sources: false)) - floor]
  end

  def emitting_files(dir)
    Dir[File.join(ROOT, dir, "**/*.{erb,html,rb,js}")].reject { |f| VENDORED.include?(f.delete_prefix("#{ROOT}/")) }.sort
  end

  # Class-shaped words in every quoted string of a file (attribute values,
  # Ruby and JS literals, template strings), read by THIS harness rather than by
  # Tailwind's scanner, so the scanner's coverage is checked against an
  # independent reading. ERB tags and interpolations are cut out first, so a
  # fragment of an assembled name ("bg-") never reads as a class. Generous on
  # purpose: a word that is not a utility simply compiles to nothing.
  def tokens_in(path)
    source = File.read(path).gsub(/<%.*?%>/m, " ")
    source.scan(/"([^"\n]*)"|'([^'\n]*)'|`([^`]*)`/).flatten.compact
          .flat_map { |s| s.gsub(/\$\{[^}]*\}|#\{[^}]*\}/, " ").split(/[\s{},]+/) }
          .map { |t| t.sub(/\A['"(]+/, "").sub(/['":;)]+\z/, "") }
          .select { |t| t.match?(/\A!?-?[a-z0-9@\[][\w\[\]\/:.%#()!@-]*\z/) && !t.end_with?("-") }
          .uniq
  end

  # dir => the utility classes its files name: the tokens that compile as
  # Tailwind classes in a build whose host.css has NO @source lines, so the
  # answer comes from the tokens alone, never from the scan under test.
  def emitted_classes
    @emitted_classes ||= begin
      tokens = EMITTING_DIRS.to_h { |dir| [dir, emitting_files(dir).flat_map { |f| tokens_in(f) }.uniq] }
      floor = classes_in_css(compile([], sources: false))
      tokens.transform_values { |list| classes_in_css(compile(list, sources: false)) - floor }
    end
  end

  # The host.css lines that add a source (not the `@source not` exclusions).
  def source_lines
    File.read(HOST_CSS).lines.grep(/\A@source "/).map(&:strip)
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
