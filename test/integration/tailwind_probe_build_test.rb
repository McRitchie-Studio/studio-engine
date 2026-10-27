# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"

# [unit] The engine's Tailwind layer is CSS-first, and a host's ONE line,
# `@import "../builds/tailwind/studio_engine"`, is the whole adoption.
#
# Compiles the engine exactly as a host's build resolves that line (Tailwind
# core, then host.css, which brings engine.css and theme.css, its own @source scan and
# engine-motion.css) and asserts:
#   - the component classes RESOLVE to theme-var-wired CSS (an @apply typo or a
#     token rename fails here, not in a consumer's build);
#   - the design tokens that used to live in the JS preset compile from @theme,
#     including the tokens that must NOT compile (a bare text-<role>);
#   - the motion layer arrives through the same import;
#   - every @source line is load-bearing: drop one and the classes only that
#     directory emits disappear (the mutation), so the scan cannot quietly
#     shrink back to what a host happens to use.
class TailwindProbeBuildTest < Minitest::Test
  B = EngineTailwindBuild

  PROBE_CLASSES = %w[
    card card-hover badge input-field empty-state json-debug label-upper
    btn btn-primary btn-secondary btn-outline btn-danger btn-warning
    btn-success btn-google btn-neutral btn-sm btn-lg text-2xs text-3xs
  ].freeze

  def self.probe_css = @probe_css ||= B.compile(PROBE_CLASSES)

  # The tokens the retired preset defined, each with the declaration it must
  # still compile to.
  THEME_TOKENS = {
    "bg-surface" => "background-color: var(--color-surface)",
    "bg-surface-alt" => "background-color: var(--color-surface-alt)",
    "bg-inset" => "background-color: var(--color-inset)",
    "bg-page" => "background-color: var(--color-page)",
    "text-heading" => "color: var(--color-text)",
    "text-body" => "color: var(--color-text-body)",
    "text-secondary" => "color: var(--color-text-secondary)",
    "text-muted" => "color: var(--color-text-muted)",
    "text-danger-ink" => "color: var(--color-danger-ink)",
    "text-primary-ink" => "color: var(--color-primary-ink)",
    "bg-primary" => "background-color: rgb(var(--color-primary-rgb))",
    "bg-primary-500" => "background-color: rgb(var(--color-primary-500-rgb))",
    "border-subtle" => "border-color: var(--color-border)",
    "border-strong" => "border-color: var(--color-border-strong)",
    "bg-danger" => "background-color: var(--color-danger)",
    "border-warning" => "border-color: var(--color-warning)",
    "bg-mint" => "background-color: #06D6A0",
    "text-violet-700" => "color: #6558E0",
    "bg-navy-500" => "background-color: #1A1535",
    "text-gold" => "color: #FFD166",
    "font-sans" => "font-family: Montserrat, system-ui, sans-serif"
  }.freeze

  # Deliberately uncompilable: a bare role colour as text fails AA, and the
  # role fills are background and border only.
  NEVER_COMPILE = %w[text-danger text-warning text-success bg-heading text-subtle font-serif].freeze

  def test_consumer_style_build_emits_component_classes_wired_to_theme_vars
    out_css = self.class.probe_css

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

  def test_the_theme_tokens_compile_from_css_with_no_config
    css = B.compile(THEME_TOKENS.keys + NEVER_COMPILE)
    classes = B.classes_in_css(css)

    THEME_TOKENS.each do |name, declaration|
      rule = css[/^\s*\.#{Regexp.escape(name)} \{[^}]*\}/]
      assert rule, ".#{name} did not compile from theme.css"
      assert_includes rule, declaration, ".#{name} compiled to the wrong value"
    end
    assert_empty NEVER_COMPILE.select { |name| classes.include?(name) },
                 "theme.css minted a utility the preset deliberately never did"
  end

  # `inline reference`: the runtime tokens are studio_theme_css_tag's to
  # declare. A plain @theme would put `--color-surface: var(--color-surface)`, a
  # self-reference, on :root in every host.
  def test_the_theme_declares_no_runtime_token_on_root
    refute_match(/--color-surface:\s*var\(--color-surface\)/, self.class.probe_css)
    refute_match(/--color-primary:\s*rgb\(var\(--color-primary-rgb\)\)/, self.class.probe_css)
  end

  def test_dark_mode_is_the_class_strategy
    css = B.compile(%w[dark:bg-surface])

    assert_match(/\.dark\\:bg-surface \{\s*&:is\(\.dark \*\)/, css, "dark: must key off a .dark ancestor, as darkMode: 'class' did")
  end

  def test_the_motion_layer_arrives_through_the_same_import
    css = self.class.probe_css

    %w[.spinner .progress-meter .studio-border-glow .hold-btn .level-badge-10].each do |selector|
      assert_includes css, "#{selector} {", "#{selector} (engine-motion.css) did not reach a host through host.css"
    end
  end

  # THE MUTATION. Each @source line, removed from a copy of host.css, must
  # take with it classes only its directory emits. These three directories
  # carry classes no other line reaches today, so each line is provably what
  # brings them. helpers/ shares every class it emits with views/ at the
  # moment, so dropping its line changes no build; the
  # structural mutation in ComponentTailwindSourceTest
  # (#test_every_emitting_directory_has_a_source_line) holds it instead.
  MUST_BITE = %w[app/views app/components app/javascript].freeze

  def test_dropping_an_source_line_drops_the_classes_only_it_reaches
    emitted = B.emitted_classes
    full = B.classes_in_css(B.compile([]))

    MUST_BITE.each do |dir|
      line = %(@source "#{relative_to_host_css(dir)}";)
      assert_includes B.source_lines, line, "host.css lost its #{dir} source line"

      only_here = emitted[dir] - emitted.except(dir).values.reduce(Set.new, :|)
      refute_empty only_here, "#{dir} emits no class another directory does not; re-point MUST_BITE"

      without = B.with_variant(->(css) { B.strip_line(css, line) }) { |path| B.classes_in_css(B.compile([], engine_css: path)) }
      # Not necessarily all of them: a class can also reach the build from a
      # comment or heredoc elsewhere, which Tailwind reads and this harness
      # does not. One is enough to prove the line is what carries it.
      lost = only_here & (full - without)
      refute_empty lost, "dropping #{line} lost none of the #{only_here.size} classes only #{dir} emits"
    end
  end

  # engine.css on its own stays NARROW: a build that imports it by path (the
  # hub's client kit, held to 100 KB) compiles the classes it names and no more:
  # no engine @source scan, no motion layer. Both ride host.css instead.
  def test_engine_css_alone_carries_no_sources_and_no_motion
    css = B.compile_entry("@import 'tailwindcss' source(none);\n@import '#{B::ENGINE_CSS}';\n")
    classes = B.classes_in_css(css)

    refute_includes css, ".spinner {", "engine.css pulled in the motion layer"
    view_only = B.emitted_classes["app/views"].to_a.grep(/\Agrid-cols-7\z|\Amin-h-\[60vh\]\z/)
    refute_empty view_only, "re-point this probe at classes the engine views still emit"
    assert_empty view_only & classes.to_a, "engine.css scanned the engine's views"
    refute_match(/^@source/, File.read(B::ENGINE_CSS), "engine.css carries an @source line")
  end

  # The engine reads no JS preset and runs no bundler from Node. The preset
  # file itself survives one release as a deprecated shim for hosts still on
  # `@config` (tailwind_preset_parity_test.rb), but nothing the engine ships
  # imports it, and no shipped code resolves the gem by shelling out.
  def test_the_engine_reads_no_js_preset_and_runs_no_shell_out
    root = B::ROOT
    spec = Dir.chdir(root) { Gem::Specification.load(File.join(root, "studio-engine.gemspec")) }
    code = spec.files.select { |f| %w[.css .js .rb .erb].include?(File.extname(f)) }
    assert_operator code.size, :>, 200, "the gemspec scan found too few files to mean anything"

    offenders = code.select do |f|
      src = File.read(File.join(root, f))
      (File.extname(f) == ".css" && src.match?(/^\s*@config\b/)) || src.include?("bundle show") || src.include?("execSync")
    end
    assert_empty offenders, "shipped code still carries an @config line or a bundler shell-out"

    importers = code.select { |f| File.read(File.join(root, f)).match?(/require\(.*studio\.tailwind\.config/) }
    assert_empty importers, "engine code requires the deprecated JS preset"
  end

  private

  def relative_to_host_css(dir)
    Pathname(File.join(B::ROOT, dir)).relative_path_from(Pathname(File.dirname(B::HOST_CSS))).to_s
  end
end
