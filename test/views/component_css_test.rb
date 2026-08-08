# frozen_string_literal: true

require "test_helper"
require "action_view"

# The engine's partials emit .card / .badge / .input-field / .empty-state /
# .btn* — classes the engine itself must DEFINE. They ship in
# app/assets/tailwind/studio_engine/engine.css, the tailwindcss-rails engines
# contract path, which consumers pull into their Tailwind build with
# `@import "../builds/tailwind/studio_engine";`.
#
# The load-bearing invariant here is POSITIVE: every component-family class an
# engine view or helper references (in a class attribute — prose comments do
# not count) is defined as an @utility in the shipped stylesheet — so a future
# partial that grows a `btn-ghost` fails this suite until the CSS ships too.
class ComponentCssTest < Minitest::Test
  CSS_PATH = File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)
  PRESET_PATH = File.expand_path("../../tailwind/studio.tailwind.config.js", __dir__)

  # Everything that can reference a component class: ERB views plus Ruby
  # helpers (a helper growing a btn-* class must not slip the invariant).
  SCAN_GLOBS = [
    File.expand_path("../../app/views/**/*.erb", __dir__),
    File.expand_path("../../app/helpers/**/*.rb", __dir__)
  ].freeze

  # The class-name families this stylesheet owns. Tokens of these shapes found
  # in a class reference in the engine's views/helpers must be @utility-defined.
  COMPONENT_FAMILY = /\A(?:card(?:-[a-z0-9-]+)?|badge|input-field|empty-state|json-debug|label-upper|studio-link-sidebar-layer|btn(?:-[a-z0-9-]+)?)\z/

  # A class REFERENCE is a class attribute — `class="..."` in ERB/HTML or
  # `class: "..."` in a Ruby options hash — never prose. Tokenizing raw file
  # text instead would trip on comments that merely mention a card-*/btn-*
  # token (proven cross-PR: a 'card-out' in another PR's comment).
  CLASS_CTX = /class(?:=|:\s*)["']([^"']*)["']/

  def css
    @css ||= File.read(CSS_PATH)
  end

  def defined_utilities
    @defined_utilities ||= css.scan(/@utility\s+([\w-]+)/).flatten.to_set
  end

  def test_stylesheet_exists_at_engines_contract_path
    assert File.exist?(CSS_PATH),
      "expected app/assets/tailwind/studio_engine/engine.css (tailwindcss-rails engines contract path)"
  end

  def test_every_component_class_used_in_engine_views_is_defined
    used = Dir.glob(SCAN_GLOBS)
              .flat_map { |f| File.read(f).scan(CLASS_CTX).flatten }
              .flat_map { |attr| attr.scan(/[\w-]+/) }
              .grep(COMPONENT_FAMILY).to_set

    refute_empty used.to_a, "expected the scan to find component classes in engine views"

    missing = used - defined_utilities
    assert_empty missing.to_a,
      "engine views/helpers use component classes the engine does not ship: #{missing.to_a.sort.join(', ')}"
  end

  def test_core_component_classes_are_defined
    %w[card card-hover badge input-field empty-state json-debug label-upper
       studio-link-sidebar-layer
       btn btn-primary btn-secondary btn-outline btn-danger btn-warning
       btn-success btn-google btn-neutral btn-sm btn-lg].each do |name|
      assert_includes defined_utilities, name, "@utility #{name} missing from engine.css"
    end
  end

  def test_buttons_are_wired_to_theme_role_vars_with_focus_visible
    btn = css[/@utility btn \{.*?\n\}/m]
    refute_nil btn, "expected an @utility btn block"
    assert_includes btn, "&:focus-visible", "btn must keep the hub's focus-visible treatment"
    assert_includes btn, "var(--color-cta)"

    assert_includes css, "background-color: var(--color-cta);"
    assert_includes css, "background-color: var(--color-cta-hover);"
    assert_includes css, "background-color: var(--color-danger);"
  end

  def test_every_theme_var_referenced_is_emitted_in_both_modes
    resolver = Studio::ThemeResolver.new
    palette = resolver.primary_palette_vars.keys

    referenced = css.scan(/var\((--color-[\w-]+)\)/).flatten.to_set
    refute_empty referenced.to_a, "expected engine.css to reference theme CSS vars"

    # Per mode, not the union: a var emitted only in dark mode would satisfy a
    # union check while rendering invisible in light mode. The palette vars are
    # emitted alongside BOTH mode blocks (see ThemeResolver#to_css).
    { "dark" => resolver.dark_mode_vars.keys,
      "light" => resolver.light_mode_vars.keys }.each do |mode, keys|
      unknown = referenced - (keys + palette).to_set
      assert_empty unknown.to_a,
        "engine.css references theme vars not emitted in #{mode} mode: #{unknown.to_a.sort.join(', ')}"
    end
  end

  def test_preset_defines_2xs_and_3xs_font_sizes
    preset = File.read(PRESET_PATH)
    assert_match(/fontSize:\s*\{[^}]*'2xs':\s*'0\.6875rem'/m, preset, "preset must define text-2xs (11px)")
    assert_match(/fontSize:\s*\{[^}]*'3xs':\s*'0\.625rem'/m, preset, "preset must define text-3xs (10px)")
  end

  def test_gem_packages_the_stylesheet
    spec = Gem::Specification.load(File.expand_path("../../studio-engine.gemspec", __dir__))
    assert_includes spec.files, "app/assets/tailwind/studio_engine/engine.css",
      "gemspec files must package the component stylesheet"
  end

  # -- Partials render with the shipped classes -----------------------------

  def test_badge_partial_renders_shipped_badge_class
    html = view.render(partial: "components/badge", locals: { text: "Live", scheme: "success" })

    assert_includes html, 'class="badge '
    assert_includes defined_utilities, "badge"
    assert_includes html, ">Live<"
  end

  def test_empty_state_partial_renders_shipped_empty_state_class
    html = view.render(partial: "components/empty_state", locals: { message: "Nothing here", detail: "Yet" })

    assert_includes html, 'class="empty-state"'
    assert_includes defined_utilities, "empty-state"
    assert_includes html, "Nothing here"
  end

  def test_input_partial_renders_shipped_input_field_class
    record = Struct.new(:email).new("shannon@example.com")
    form = ActionView::Helpers::FormBuilder.new(:user, record, view, {})
    html = view.render(partial: "components/input", locals: { form: form, field: :email, label: "Email" })

    assert_includes html, 'class="input-field"'
    assert_includes defined_utilities, "input-field"
    assert_includes html, 'value="shannon@example.com"'
  end

  def test_card_partial_renders_shipped_card_class
    html = view.render(layout: "components/card", locals: { padding: "p-4" }) { "Card body" }

    assert_includes html, 'class="card p-4"'
    assert_includes defined_utilities, "card"
    assert_includes html, "Card body"
  end

  # btn-secondary and btn-neutral are TOKEN-DRIVEN so consumers retune them via
  # --btn-* custom properties instead of forking the @utility (which is additive
  # in Tailwind v4). The defaults must keep the theme-role fallbacks so a consumer
  # that sets no tokens is visually unchanged (and the theme-var test still holds).
  def test_secondary_and_neutral_variants_are_token_overridable_with_role_defaults
    secondary = css[/@utility btn-secondary \{.*?\n\}/m]
    refute_nil secondary, "expected an @utility btn-secondary block"
    assert_includes secondary, "var(--btn-secondary-bg, var(--color-success))",
      "btn-secondary base must be token-overridable, defaulting to the success role"
    assert_includes secondary, "var(--btn-secondary-bg-hover,",
      "btn-secondary hover fill must be token-overridable"
    assert_includes secondary, "var(--btn-secondary-hover-filter, brightness(0.9))",
      "btn-secondary hover filter must be token-overridable, defaulting to brightness(0.9)"

    neutral = css[/@utility btn-neutral \{.*?\n\}/m]
    refute_nil neutral, "expected an @utility btn-neutral block"
    assert_includes neutral, "var(--btn-neutral-bg, var(--color-surface-alt))",
      "btn-neutral base must be token-overridable, defaulting to the surface-alt role"
    assert_includes neutral, "var(--btn-neutral-bg-hover, var(--color-surface))",
      "btn-neutral hover fill must be token-overridable, defaulting to the surface role"
    assert_includes neutral, "var(--btn-neutral-hover-filter, none)",
      "btn-neutral hover filter must be token-overridable, defaulting to none"
  end

  private

  def view
    @view ||= ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
  end
end
