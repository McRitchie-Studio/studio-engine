# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "set"
require "tailwindcss/ruby"

# [unit] An engine view may name only classes the ENGINE can define.
#
# THE DEFECT THIS PINS. Three engine partials — studio/modals/blocks/_birthday,
# studio/modals/blocks/_leveling_activity and studio/modals/onboarding/_first_name
# — rendered `class="cta-spinner"`. The engine defines `cta-spinner` NOWHERE: it
# is a HOST utility, living in turf-monster's app/assets/tailwind/application.css.
# It looked right in turf by coincidence and was an unstyled EMPTY SPAN in every
# other consumer — McRitchie Studio renders _first_name today, and its "Saving…"
# button carried a spinner that painted nothing. No error. No log line. A render
# test sees the string either way; nothing noticed until someone looked.
#
# That is the engine depending on its consumer, backwards — the shipped-gem form
# of the two-forks disease the modal defork exists to cure.
#
# HOW THIS DECIDES "DEFINED". Not by a list of class names someone keeps up to
# date: by COMPILING. Every class token the engine's views name is fed through a
# real consumer-style Tailwind v4 build — core, the shared preset via @config,
# engine.css, and the opt-in engine-motion.css, the same ingredients and order
# every consuming app uses (test/integration/tailwind_probe_build_test.rb is the
# precedent) — and a token counts as defined only if the compiled CSS carries a
# selector for it. Engine-owned plain CSS joins the vocabulary too: the
# stylesheets under app/assets/stylesheets, every <style> block in an engine
# view, and the Studio::UiPrimitives *_CSS strings. A token none of those define
# compiles to nothing in any consumer that has not happened to define it itself.
#
# WHAT IS NOT CHECKED, stated so it is not mistaken for coverage. A class built
# from ERB or JS at render time (`bg-<%= tone %>`, `'text-' + x`) cannot be judged
# from source; such tokens are DROPPED and counted, never guessed at. `:class`
# bindings are read only for quoted literals that are object KEYS or ternary
# BRANCHES — a comparison operand (`mode === 'custom'`) is data, not a class.
#
# THE ALLOW-LISTS ARE DECISIONS, NOT SKIPS. A token that is legitimately
# undefined goes on a list, with its reason, so it moves only when someone moves
# it deliberately. Each list is policed in BOTH directions: an entry whose token
# is now defined, or no longer used, fails as stale — so the open-defect lists
# can only shrink, and a fix cannot leave its own entry behind.
class EngineClassVocabularyTest < ActiveSupport::TestCase
  ROOT       = File.expand_path("../..", __dir__)
  VIEWS      = File.join(ROOT, "app/views")
  PRESET     = File.join(ROOT, "tailwind/studio.tailwind.config.js")
  ENGINE_CSS = File.join(ROOT, "app/assets/tailwind/studio_engine/engine.css")
  MOTION_CSS = File.join(ROOT, "app/assets/tailwind/studio_engine/engine-motion.css")
  PLAIN_CSS  = File.join(ROOT, "app/assets/stylesheets/**/*.css")

  # Stands in for any ERB tag, so a token it touches is recognisably dynamic.
  ERB = "ERBxERB"

  # ── names that carry no CSS BY DESIGN ──────────────────────────────────────
  # Hooks for JS, tests and structure. Styling them would be the mistake.
  HOOKS = {
    "nav-spinner-icon"     => "JS hook: layouts/studio/_head.html.erb drives it by querySelectorAll, inline styles",
    "nav-toggle-icon"      => "JS hook: layouts/studio/_head.html.erb drives it by querySelectorAll, inline styles",
    "geo-grid-countries"   => "test hook: e2e/geo_settings.spec.js locates the grid by it",
    "geo-grid-states"      => "test hook: the states twin of geo-grid-countries",
    "is-scrolled"          => "state marker bound beside real utilities in layouts/_navbar (shadow-lg border-b ...)",
    "studio-avatar-badge"  => "structural wrapper; its child .studio-avatar-badge-icon carries the styling",
    "studio-board"         => "board primitive namespace; layout comes from the utilities on the same element",
    "studio-board-column"  => "board primitive namespace",
    "studio-board-grid"    => "board primitive namespace",
    "studio-board-group"   => "board primitive namespace",
    "studio-board-header"  => "board primitive namespace",
    "studio-board-kickoff" => "board primitive namespace",
    "studio-board-toasts"  => "board primitive namespace",
    "stage-count"          => "board column count pill; styled by the utilities beside it"
  }.freeze

  # ── OPEN DEFECTS: host-only utilities an engine view still names ─────────────
  # The cta-spinner class of bug, found by this guard on its first run. Each is
  # defined ONLY in turf-monster, so it paints nothing anywhere else. Listed so
  # the guard can go green on the fix it was written for without pretending
  # these are fine. Fixing one means deciding, per name, what the engine should
  # own — not copying turf's CSS — and then deleting its entry here.
  KNOWN_HOST_ONLY = {
    "email-reject"     => "OPEN DEFECT: studio/modals/shared/_email_field; turf @utility email-reject " \
                          "(application.css:302), a shake + border fade the engine has no equivalent of",
    "backdrop-overlay" => "OPEN DEFECT: sessions/new; turf @utility backdrop-overlay (application.css:274). " \
                          "mcritchie-industries renders this engine view and lacks it, so the SSO overlay has " \
                          "no blur. Expressible in engine terms: backdrop-blur-[2px] backdrop-brightness-[.7] " \
                          "bg-primary-900/20"
  }.freeze

  # ── OPEN DEFECTS: theme-role colour utilities the preset never registers ─────
  # The preset registers `danger-ink` under textColor only, and no `danger` or
  # `warning` colour at all, so these compile to nothing in every consumer that
  # does not register them itself (turf registers `warning`; McRitchie Studio,
  # which renders these admin pages, registers neither).
  KNOWN_PHANTOM = {
    "text-danger"       => "OPEN DEFECT: studio/emails/show — use text-danger-ink",
    "hover:text-danger" => "OPEN DEFECT: components/_avatar_cropper — use hover:text-danger-ink",
    "text-warning"      => "OPEN DEFECT: schema/index, studio/emails/orphan — no warning text colour exists",
    "bg-warning/10"     => "OPEN DEFECT: studio/emails/orphan — no warning colour exists",
    "border-warning/30" => "OPEN DEFECT: studio/emails/orphan — no warning colour exists",
    "placeholder-muted" => "OPEN DEFECT: error_logs/index, schema/index — muted is a textColor only"
  }.freeze

  ALLOWED = HOOKS.merge(KNOWN_HOST_ONLY).merge(KNOWN_PHANTOM).freeze

  # ── views that depend on the OPT-IN motion layer ───────────────────────────
  # engine-motion.css does NOT auto-bundle (see its header): a consumer adopts it
  # with one @import, and turf-monster and McRitchie Studio do, while
  # mcritchie-industries and acquisition-studio do NOT. So a view on this list
  # renders its motion classes — .spinner included — unstyled in a consumer that
  # never opted in. That is not a defect today (neither non-adopter renders any
  # of these), but it IS a dependency, and it was invisible. Adding a view here
  # is the decision that its consumers must opt in. The style guide (style/) is
  # exempt: it is the showcase for this layer by design.
  OPT_IN_DEPENDENTS = %w[
    studio/_fizz_layer.html.erb
    studio/_hold_button.html.erb
    studio/modals/auth/_resend_footer.html.erb
    studio/modals/blocks/_birthday.html.erb
    studio/modals/blocks/_card_header.html.erb
    studio/modals/blocks/_cta_redirect.html.erb
    studio/modals/blocks/_leveling_activity.html.erb
    studio/modals/blocks/_seeds_bar.html.erb
    studio/modals/onboarding/_first_name.html.erb
    studio/modals/shared/_email_field.html.erb
  ].freeze

  # ── reading the views ──────────────────────────────────────────────────────

  # Comments are prose, not markup — and several partials discuss the very
  # classes this file hunts. ERB tags become a marker so an interpolated token is
  # recognisable, and so an ERB string containing `"` cannot end an attribute
  # early (the trap documented in modal_error_lines_announce_test.rb).
  def self.neutralise(src) = src.gsub(/<%#.*?%>/m, "").gsub(/<%.*?%>/m, ERB)

  # `class="..."` — the lookbehind keeps `:class` and `x-bind:class` out, since
  # those hold JS expressions, not class lists.
  def self.static_tokens(markup)
    markup.scan(/(?<![:\w-])class\s*=\s*"([^"]*)"/m).flatten.flat_map { |v| v.split(/\s+/) }
  end

  # `:class` / `x-bind:class` — quoted literals that are object KEYS or ternary
  # BRANCHES. A literal compared against (`=== 'custom'`) or concatenated
  # (`'text-' + tone`) is not a class and is skipped.
  def self.bound_tokens(markup)
    markup.scan(/(?:x-bind)?:class\s*=\s*"([^"]*)"/m).flatten.flat_map do |expr|
      found = []
      expr.scan(/'([^']*)'/) do
        m = Regexp.last_match
        before = expr[0...m.begin(0)].rstrip
        after  = expr[m.end(0)..].lstrip
        next if before.end_with?("=", "+") || after.start_with?("+", "=", "!")

        found.concat(m[1].split(/\s+/))
      end
      found
    end
  end

  def self.tokens_in(source)
    markup = neutralise(source)
    (static_tokens(markup) + bound_tokens(markup)).reject(&:empty?)
  end

  def self.view_paths = Dir.glob(File.join(VIEWS, "**", "*.erb")).sort
  def self.relative(path) = path.delete_prefix("#{VIEWS}/")

  # { token => Set[view] } for every STATIC token, plus the dynamic ones dropped.
  def self.scan
    @scan ||= begin
      by_token = Hash.new { |h, k| h[k] = Set.new }
      dynamic = Set.new
      view_paths.each do |path|
        tokens_in(File.read(path)).each do |t|
          t.include?(ERB) ? dynamic << t : by_token[t] << relative(path)
        end
      end
      [by_token, dynamic]
    end
  end

  # ── the vocabulary ─────────────────────────────────────────────────────────

  # Class names a stylesheet defines — escapes decoded (`hover\:x`, `\32 xl`).
  # A superset by construction (a decimal like `.5rem` reads as a "class"), so it
  # can only ever over-credit a token, never falsely accuse one.
  def self.classes_in_css(css)
    css.gsub(%r{/\*.*?\*/}m, "")
       .scan(/\.((?:\\[0-9a-fA-F]{1,6}\s?|\\.|[A-Za-z0-9_-])+)/)
       .flatten
       .to_set { |raw| raw.gsub(/\\([0-9a-fA-F]{1,6})\s?/) { [::Regexp.last_match(1).hex].pack("U") }.gsub(/\\(.)/, '\1') }
  end

  def self.compile(tokens, motion:)
    Dir.mktmpdir("studio-engine-vocab") do |dir|
      File.write(File.join(dir, "probe.html"), %(<div class="#{tokens.join(' ')}"></div>\n))
      File.write(File.join(dir, "tailwind.config.js"),
                 "const studio = require('#{PRESET}')\n" \
                 "module.exports = { darkMode: 'class', content: ['#{dir}/probe.html'], theme: studio.theme }\n")
      input = +"@import 'tailwindcss';\n@config '#{dir}/tailwind.config.js';\n@import '#{ENGINE_CSS}';\n"
      input << "@import '#{MOTION_CSS}';\n" if motion
      File.write(File.join(dir, "input.css"), input)

      out = File.join(dir, "out.css")
      _stdout, stderr, status = Open3.capture3(Tailwindcss::Ruby.executable,
                                               "-i", File.join(dir, "input.css"), "-o", out)
      raise "tailwind build failed:\n#{stderr}" unless status.success?

      File.read(out)
    end
  end

  def self.owned_plain_css
    sheets = Dir.glob(PLAIN_CSS).map { |f| File.read(f) }
    blocks = view_paths.flat_map { |f| neutralise(File.read(f)).scan(%r{<style\b[^>]*>(.*?)</style>}m).flatten }
    prims  = Studio::UiPrimitives.constants.grep(/_CSS\z/).map { |c| Studio::UiPrimitives.const_get(c).to_s }
    (sheets + blocks + prims).map { |css| classes_in_css(css) }.reduce(Set.new, :|)
  end

  # Compiled once per run — two real Tailwind builds, about a second.
  def self.vocabulary
    @vocabulary ||= begin
      tokens = scan.first.keys.sort
      plain = owned_plain_css
      { full: classes_in_css(compile(tokens, motion: true)) | plain,
        base: classes_in_css(compile(tokens, motion: false)) | plain,
        plain: plain }
    end
  end

  def by_token = self.class.scan.first
  def full     = self.class.vocabulary[:full]
  def base     = self.class.vocabulary[:base]

  def undefined_tokens = by_token.keys.reject { |t| full.include?(t) }.sort

  def where(token) = by_token[token].to_a.sort.first(4).join(", ")

  # ── the claim ──────────────────────────────────────────────────────────────

  def test_every_class_an_engine_view_names_is_one_the_engine_defines
    offenders = (undefined_tokens - ALLOWED.keys).to_h { |t| [t, where(t)] }

    assert_empty offenders,
                 "these classes are named by engine views and defined NOWHERE the engine ships — " \
                 "not Tailwind core, not the shared preset, not engine.css or engine-motion.css, " \
                 "not any engine-owned stylesheet or <style> block: #{offenders.inspect}. In every " \
                 "consumer that does not happen to define them, they paint NOTHING, silently — " \
                 "that is how cta-spinner shipped. Use engine vocabulary (the .spinner primitive " \
                 "tunes through --spinner-* custom properties), or, if a name is a JS/test hook " \
                 "that deliberately carries no CSS, add it to HOOKS with the reason."
  end

  # ── the allow-lists stay honest ────────────────────────────────────────────

  # A fix must take its own entry with it, or the list becomes a place where
  # defects are forgotten rather than tracked.
  def test_no_allow_list_entry_is_stale
    now_defined = ALLOWED.keys.select { |t| full.include?(t) }
    unused      = ALLOWED.keys.reject { |t| by_token.key?(t) }

    assert_empty now_defined,
                 "#{now_defined.inspect} are allow-listed as undefined but the engine now DEFINES " \
                 "them — delete the entries, the defect is fixed"
    assert_empty unused,
                 "#{unused.inspect} are allow-listed but no engine view names them any more — " \
                 "delete the entries"
  end

  def test_the_lists_do_not_overlap
    overlap = [HOOKS, KNOWN_HOST_ONLY, KNOWN_PHANTOM].map(&:keys).combination(2).flat_map { |a, b| a & b }

    assert_empty overlap, "#{overlap.inspect} are on more than one list — a name has exactly one reason"
  end

  # ── the opt-in layer is a declared dependency ─────────────────────────────

  def test_every_view_that_depends_on_the_opt_in_motion_layer_is_declared
    motion_only = by_token.keys.select { |t| full.include?(t) && !base.include?(t) }
    dependents  = motion_only.flat_map { |t| by_token[t].to_a }
                             .reject { |v| v.start_with?("style/") }
                             .uniq.sort

    assert_empty dependents - OPT_IN_DEPENDENTS,
                 "these views now name classes that exist ONLY in the opt-in engine-motion.css layer: " \
                 "#{(dependents - OPT_IN_DEPENDENTS).inspect}. A consumer that never imported that " \
                 "layer (mcritchie-industries, acquisition-studio) renders them unstyled. If that " \
                 "dependency is intended, add the view to OPT_IN_DEPENDENTS."
    assert_empty OPT_IN_DEPENDENTS - dependents,
                 "#{(OPT_IN_DEPENDENTS - dependents).inspect} no longer depend on the motion layer — " \
                 "delete them from OPT_IN_DEPENDENTS"
  end

  # ── the guard's own integrity ──────────────────────────────────────────────

  # THE FLOORS. A scanner that goes quiet passes having proved nothing — a
  # renamed directory, a regex that stops matching, a build that emits nothing.
  def test_the_guard_reads_what_it_claims_to
    by_token, dynamic = self.class.scan

    assert_operator self.class.view_paths.length, :>=, 150, "only #{self.class.view_paths.length} views scanned"
    assert_operator by_token.length, :>=, 500, "only #{by_token.length} distinct static class tokens parsed"
    assert_operator full.length, :>=, 700, "the compiled vocabulary holds only #{full.length} classes"
    assert_operator dynamic.length, :<=, 40,
                    "#{dynamic.length} tokens were dropped as ERB-interpolated — a jump means the " \
                    "neutraliser is eating static classes"
  end

  # Every source of the vocabulary must actually contribute, or the guard would
  # accuse a class the engine really does define. The compiled sources only emit
  # what the probe NAMES, so their witnesses must be named by a view; the plain
  # CSS sources are read whole, so theirs need not be (sticky-data-table is
  # applied by script, never written in a class attribute).
  def test_every_vocabulary_source_contributes
    {
      "flex"                     => ["Tailwind core", true],
      "text-heading"             => ["the shared preset (textColor)", true],
      "btn-primary"              => ["engine.css", true],
      "spinner"                  => ["engine-motion.css", true],
      "studio-avatar-badge-icon" => ["a <style> block in an engine view", false],
      "studio-emoji-swap-base"   => ["Studio::UiPrimitives", false],
      "sticky-data-table"        => ["app/assets/stylesheets", false]
    }.each do |token, (source, named)|
      if named
        assert by_token.key?(token), "no engine view names #{token} any more — pick another witness for #{source}"
      end
      assert full.include?(token), "#{token} is not in the vocabulary — #{source} is not being read"
    end
    refute base.include?("spinner"), "the base build contains .spinner — the opt-in layer leaked into it"
  end

  # THE CONTROL: the half a passing guard cannot show about itself. cta-spinner
  # is named in engine-motion.css's own header prose, and the vocabulary must
  # still not count it — so this also proves CSS comments are not read as rules.
  def test_the_class_that_shipped_is_undefined_in_the_engine_vocabulary
    refute full.include?("cta-spinner"),
           "cta-spinner is in the engine's vocabulary — either the engine now defines it (then " \
           "this guard's premise changed) or a comment is being parsed as a rule"
    refute full.include?("definitely-not-a-class-anywhere")
  end

  def test_the_scanner_reads_both_binding_forms_and_nothing_else
    markup = <<~ERB
      <%# class="from-a-comment" %>
      <span class="spinner cta-spinner" aria-hidden="true"></span>
      <p :class="{ 'email-reject': rejecting, 'opacity-50': busy }"></p>
      <p :class="open ? 'block' : 'hidden'"></p>
      <p :class="mode === 'custom' ? 'ring-2' : ''"></p>
      <p :class="'text-' + tone"></p>
      <p class="bg-<%= tone %>/15 rounded"></p>
    ERB
    tokens = self.class.tokens_in(markup)

    assert_equal %w[spinner cta-spinner email-reject opacity-50 block hidden ring-2 rounded].sort,
                 tokens.reject { |t| t.include?(ERB) }.sort
    assert tokens.any? { |t| t.include?(ERB) }, "an ERB-interpolated token must be seen, then dropped"
  end
end
