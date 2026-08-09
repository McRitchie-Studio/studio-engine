# frozen_string_literal: true

require_relative "../../test_helper"

class Studio::ThemeResolverTest < Minitest::Test
  STUDIO_COLORS = {
    primary: "#8E82FE",
    dark:    "#1A1535",
    light:   "#f8fafc",
    success: "#4BAF50",
    warning: "#FF7C47",
    danger:  "#EF4444"
  }.freeze

  def setup
    @resolver = Studio::ThemeResolver.new(STUDIO_COLORS)
  end

  # ── initialize ──────────────────────────────────────────────

  def test_initialize_stores_colors
    assert_equal "#8E82FE", @resolver.colors[:primary]
    assert_equal "#1A1535", @resolver.colors[:dark]
    assert_equal "#f8fafc", @resolver.colors[:light]
  end

  def test_initialize_with_string_keys
    resolver = Studio::ThemeResolver.new("primary" => "#FF0000", "dark" => "#111111")
    assert_equal "#FF0000", resolver.colors[:primary]
    assert_equal "#111111", resolver.colors[:dark]
  end

  def test_initialize_with_empty_hash
    resolver = Studio::ThemeResolver.new({})
    assert_kind_of Hash, resolver.colors
  end

  # ── dark_mode_vars ──────────────────────────────────────────

  def test_dark_mode_vars_returns_hash
    vars = @resolver.dark_mode_vars
    assert_kind_of Hash, vars
  end

  def test_dark_mode_vars_has_all_expected_keys
    vars = @resolver.dark_mode_vars
    expected_keys = %w[
      --color-page --color-surface --color-surface-alt --color-inset
      --color-text --color-text-body --color-text-secondary --color-text-muted
      --color-border --color-border-strong --color-shadow
      --color-cta --color-cta-hover
      --color-success --color-warning --color-danger --color-accent
    ]
    expected_keys.each do |key|
      assert vars.key?(key), "Missing dark mode var: #{key}"
    end
  end

  def test_dark_mode_page_is_dark_base
    vars = @resolver.dark_mode_vars
    assert_equal "#1A1535", vars["--color-page"]
  end

  def test_dark_mode_cta_is_primary
    vars = @resolver.dark_mode_vars
    assert_equal "#8E82FE", vars["--color-cta"]
  end

  def test_dark_mode_cta_hover_is_darkened_primary
    vars = @resolver.dark_mode_vars
    expected = Studio::ColorScale.darken("#8E82FE", 0.30)
    assert_equal expected, vars["--color-cta-hover"]
  end

  def test_dark_mode_text_is_white
    vars = @resolver.dark_mode_vars
    assert_equal "#ffffff", vars["--color-text"]
  end

  def test_dark_mode_shadow_is_transparent
    vars = @resolver.dark_mode_vars
    assert_equal "transparent", vars["--color-shadow"]
  end

  def test_dark_mode_success_from_config
    vars = @resolver.dark_mode_vars
    assert_equal "#4BAF50", vars["--color-success"]
  end

  def test_dark_mode_warning_from_config
    vars = @resolver.dark_mode_vars
    assert_equal "#FF7C47", vars["--color-warning"]
  end

  def test_dark_mode_danger_from_config
    vars = @resolver.dark_mode_vars
    assert_equal "#EF4444", vars["--color-danger"]
  end

  def test_dark_mode_surface_is_lightened_dark_base
    vars = @resolver.dark_mode_vars
    expected = Studio::ColorScale.lighten("#1A1535", 0.15)
    assert_equal expected, vars["--color-surface"]
  end

  def test_dark_mode_surface_alt_is_darkened_dark_base
    vars = @resolver.dark_mode_vars
    expected = Studio::ColorScale.darken("#1A1535", 0.14)
    assert_equal expected, vars["--color-surface-alt"]
  end

  def test_dark_mode_inset_is_darkened_dark_base
    vars = @resolver.dark_mode_vars
    expected = Studio::ColorScale.darken("#1A1535", 0.43)
    assert_equal expected, vars["--color-inset"]
  end

  # ── dark_mode_vars with defaults ────────────────────────────

  def test_dark_mode_uses_defaults_when_colors_missing
    resolver = Studio::ThemeResolver.new({})
    vars = resolver.dark_mode_vars
    assert_equal "#1A1535", vars["--color-page"]
    assert_equal "#8E82FE", vars["--color-cta"]
    assert_equal "#4BAF50", vars["--color-success"]
    assert_equal "#FF7C47", vars["--color-warning"]
    assert_equal "#EF4444", vars["--color-danger"]
  end

  # ── light_mode_vars ─────────────────────────────────────────

  def test_light_mode_vars_returns_hash
    vars = @resolver.light_mode_vars
    assert_kind_of Hash, vars
  end

  def test_light_mode_vars_has_all_expected_keys
    vars = @resolver.light_mode_vars
    expected_keys = %w[
      --color-page --color-surface --color-surface-alt --color-inset
      --color-text --color-text-body --color-text-secondary --color-text-muted
      --color-border --color-border-strong --color-shadow
      --color-cta --color-cta-hover
      --color-success --color-warning --color-danger --color-accent
    ]
    expected_keys.each do |key|
      assert vars.key?(key), "Missing light mode var: #{key}"
    end
  end

  def test_light_mode_page_is_light_base
    vars = @resolver.light_mode_vars
    assert_equal "#f8fafc", vars["--color-page"]
  end

  def test_light_mode_surface_is_white
    vars = @resolver.light_mode_vars
    assert_equal "#ffffff", vars["--color-surface"]
  end

  def test_light_mode_cta_is_primary
    vars = @resolver.light_mode_vars
    assert_equal "#8E82FE", vars["--color-cta"]
  end

  def test_light_mode_text_is_dark
    vars = @resolver.light_mode_vars
    assert_equal "#0f172a", vars["--color-text"]
  end

  def test_light_mode_shadow_is_subtle
    vars = @resolver.light_mode_vars
    assert_equal "rgba(0,0,0,0.05)", vars["--color-shadow"]
  end

  def test_light_mode_uses_defaults_when_colors_missing
    resolver = Studio::ThemeResolver.new({})
    vars = resolver.light_mode_vars
    assert_equal "#f8fafc", vars["--color-page"]
    assert_equal "#8E82FE", vars["--color-cta"]
  end

  # ── primary_palette_vars ────────────────────────────────────

  def test_primary_palette_has_shade_keys
    vars = @resolver.primary_palette_vars
    [50, 100, 200, 300, 400, 500, 600, 700, 800, 900].each do |shade|
      assert vars.key?("--color-primary-#{shade}"), "Missing shade #{shade}"
    end
  end

  def test_primary_palette_has_rgb_variants
    vars = @resolver.primary_palette_vars
    [50, 100, 200, 300, 400, 500, 600, 700, 800, 900].each do |shade|
      key = "--color-primary-#{shade}-rgb"
      assert vars.key?(key), "Missing RGB variant for shade #{shade}"
      # RGB value should be space-separated integers
      assert_match(/\A\d+ \d+ \d+\z/, vars[key], "#{key} should be space-separated RGB")
    end
  end

  def test_primary_palette_has_default_alias
    vars = @resolver.primary_palette_vars
    assert vars.key?("--color-primary"), "Missing --color-primary default"
    assert vars.key?("--color-primary-rgb"), "Missing --color-primary-rgb default"
  end

  def test_primary_palette_default_matches_primary_color
    vars = @resolver.primary_palette_vars
    assert_equal "#8E82FE", vars["--color-primary"]
  end

  def test_primary_palette_500_matches_primary_color
    vars = @resolver.primary_palette_vars
    assert_equal "#8E82FE", vars["--color-primary-500"]
  end

  def test_primary_palette_rgb_default_is_correct
    vars = @resolver.primary_palette_vars
    assert_equal "142 130 254", vars["--color-primary-rgb"]
  end

  def test_primary_palette_total_var_count
    vars = @resolver.primary_palette_vars
    # 10 shades + 10 RGB + 1 default + 1 default RGB = 22
    assert_equal 22, vars.size
  end

  def test_primary_palette_uses_default_when_no_primary
    resolver = Studio::ThemeResolver.new({})
    vars = resolver.primary_palette_vars
    assert_equal "#8E82FE", vars["--color-primary"]
  end

  # ── to_css ──────────────────────────────────────────────────

  def test_to_css_returns_string
    css = @resolver.to_css
    assert_kind_of String, css
  end

  def test_to_css_contains_dark_mode_section
    css = @resolver.to_css
    assert_includes css, ":root, .dark {"
  end

  def test_to_css_contains_light_mode_section
    css = @resolver.to_css
    assert_includes css, "html:not(.dark) {"
  end

  def test_to_css_contains_page_var
    css = @resolver.to_css
    assert_includes css, "--color-page:"
  end

  def test_to_css_contains_cta_var
    css = @resolver.to_css
    assert_includes css, "--color-cta:"
  end

  def test_to_css_contains_primary_palette
    css = @resolver.to_css
    assert_includes css, "--color-primary-500:"
    assert_includes css, "--color-primary-500-rgb:"
  end

  def test_to_css_palette_in_both_sections
    css = @resolver.to_css
    # Palette vars should appear in both dark and light sections
    # Count occurrences of the primary default
    occurrences = css.scan("--color-primary:").length
    assert_equal 2, occurrences, "Primary palette should appear in both :root/.dark and html:not(.dark)"
  end

  def test_to_css_valid_css_property_format
    css = @resolver.to_css
    # Every line inside a block should be "  --name: value;" format
    css.each_line do |line|
      next if line.strip.empty? || line.include?("{") || line.include?("}")
      assert_match(/\A\s+--[\w-]+:\s+.+;\s*\z/, line, "Invalid CSS property line: #{line.inspect}")
    end
  end

  # ── with Turf Monster colors ────────────────────────────────

  def test_turf_monster_green_primary
    resolver = Studio::ThemeResolver.new(primary: "#4BAF50", dark: "#1A1535", light: "#f8fafc")
    vars = resolver.dark_mode_vars
    assert_equal "#4BAF50", vars["--color-cta"]
  end

  def test_turf_monster_palette_is_green
    resolver = Studio::ThemeResolver.new(primary: "#4BAF50")
    vars = resolver.primary_palette_vars
    assert_equal "#4BAF50", vars["--color-primary-500"]
    assert_equal "#4BAF50", vars["--color-primary"]
  end
end

class ThemeResolverAccentTest < Minitest::Test
  # The accent ROLE existed end-to-end (config -> ThemeSetting.accent2 ->
  # resolved_colors) but the resolver never emitted a variable, so
  # config.theme_accent painted nothing and apps hardcoded the hex instead.
  def test_accent_emits_in_both_modes_from_config
    resolver = Studio::ThemeResolver.new(accent: "#2845D6")
    assert_equal "#2845D6", resolver.dark_mode_vars["--color-accent"]
    assert_equal "#2845D6", resolver.light_mode_vars["--color-accent"]
  end

  def test_accent_defaults_match_the_theme_role_default
    resolver = Studio::ThemeResolver.new({})
    assert_equal "#F72585", resolver.dark_mode_vars["--color-accent"]
    assert_equal "#F72585", resolver.light_mode_vars["--color-accent"]
  end
end

class ThemeResolverInkContrastTest < Minitest::Test
  # Property, and this time actually the property: the derived inks must clear
  # WCAG targets on EVERY emitted background, for a swept space of bases —
  # the fleet, the reviewer's counterexamples (each broke the old fixed-blend
  # derivation with a green suite), and a grayscale sweep of the sane domain
  # for each mode. The theme editor accepts arbitrary hexes, so this is an
  # operator-reachable input space, not a hypothetical one.
  FLEET_DARK = %w[#1A1535 #0D1A63 #0f172a #10101f].freeze
  COUNTEREXAMPLES = %w[#374151 #1e3a8a #312e81 #134e4a].freeze
  # Above ~#555555 even pure white cannot reach 4.5:1 on the lifted surface —
  # that is not a dark theme any more. The invariant holds on the real domain;
  # brighter bases degrade to the clamp (pinned below).
  DARK_SWEEP = (0x00..0x55).step(0x11).map { |v| format("#%02x%02x%02x", v, v, v) }.freeze
  LIGHT_SWEEP = (0xaa..0xff).step(0x11).map { |v| format("#%02x%02x%02x", v, v, v) }.freeze
  FLEET_LIGHT = %w[#f8fafc #ffffff].freeze

  def test_dark_mode_inks_clear_targets_on_every_emitted_background
    (FLEET_DARK + COUNTEREXAMPLES + DARK_SWEEP).each do |base|
      vars = Studio::ThemeResolver.new(dark: base).dark_mode_vars
      backgrounds = vars.values_at("--color-page", "--color-surface", "--color-surface-alt", "--color-inset")

      backgrounds.each do |bg|
        assert_operator contrast(vars["--color-text-muted"], bg), :>=, 3.0,
          "muted must clear 3:1 on #{bg} for base #{base}"
        assert_operator contrast(vars["--color-text-secondary"], bg), :>=, 4.5,
          "secondary must clear 4.5:1 on #{bg} for base #{base}"
      end

      assert_operator luminance(vars["--color-text-muted"]), :<=, luminance(vars["--color-text-secondary"]),
        "the ink ladder must stay monotonic (muted <= secondary) for base #{base}"
    end
  end

  def test_pathological_dark_base_clamps_to_best_achievable_ink
    vars = Studio::ThemeResolver.new(dark: "#999999").dark_mode_vars

    assert_equal "#ffffff", vars["--color-text-secondary"].downcase,
      "an unreachable target must clamp at pure white, not loop"
  end

  def test_light_mode_inks_clear_targets_on_every_emitted_background
    (FLEET_LIGHT + LIGHT_SWEEP).each do |base|
      vars = Studio::ThemeResolver.new(light: base).light_mode_vars
      backgrounds = vars.values_at("--color-page", "--color-surface", "--color-surface-alt", "--color-inset")

      backgrounds.each do |bg|
        assert_operator contrast(vars["--color-text-muted"], bg), :>=, 3.0,
          "muted must clear 3:1 on #{bg} for base #{base}"
        assert_operator contrast(vars["--color-text-secondary"], bg), :>=, 4.5,
          "secondary must clear 4.5:1 on #{bg} for base #{base}"
      end
    end
  end

  private

  def contrast(hex_a, hex_b)
    Studio::ColorScale.contrast_ratio(hex_a, hex_b)
  end

  def luminance(hex)
    Studio::ColorScale.relative_luminance(hex)
  end
end
