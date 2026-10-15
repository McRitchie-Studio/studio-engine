# frozen_string_literal: true

require_relative "../test_helper"

# [unit] The scrim primitive's contract, read from engine.css as source.
#
# Tints and shades (README "Tints and shades"): a SHADE lays the dark base over
# media and light ink reads on it; a TINT lays the light base over media and
# dark ink reads on it. `.scrim` is theme-aware, `.scrim-tint` / `.scrim-shade`
# force a tone, `.scrim-soft` / `.scrim-strong` move the strength, and
# `.scrim-ink` / `.scrim-ink-muted` pick the ink for the tone.
#
# What this tier pins is the DECISION: which tone each mode gets, the strength
# numbers Alex approved, the ink treatments, and that the CSS fallbacks agree
# with what Studio::ThemeResolver emits. Whether those rules win the cascade and
# paint is the browser's question: e2e/scrim_tones.spec.js.
class ScrimContractTest < Minitest::Test
  ENGINE_CSS = File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)

  TONE_VARS = %w[
    --scrim-color --scrim-tone-edge --scrim-tone-mid
    --scrim-ink --scrim-ink-muted --scrim-ink-muted-weight
  ].freeze

  def css
    @css ||= File.read(ENGINE_CSS).gsub(%r{/\*.*?\*/}m, "")
  end

  # The declarations of the rule whose selector is exactly `selector`, as a
  # name => value hash. No scrim rule nests braces, so the first `}` closes it.
  # engine.css has more than one `:root` (the layer scale is another), so the
  # rule taken is the one that sets a scrim var, or the only one there is.
  def decls(selector)
    bodies = css.scan(/^#{Regexp.escape(selector)}\s*\{(.*?)\}/m).flatten
    body = bodies.find { |b| b.include?("--scrim-") } || bodies.first
    refute_nil body, "engine.css defines no `#{selector} { ... }` rule"
    body.scan(/([\w-]+)\s*:\s*([^;]+);/m).to_h { |k, v| [k, v.gsub(/\s+/, " ").gsub(/\( /, "(").gsub(/ \)/, ")").strip] }
  end

  def defaults
    @defaults ||= Studio::ThemeResolver.new({}).tone_vars
  end

  # ── the classes exist, as utilities ──────────────────────────

  def test_every_scrim_class_is_an_engine_utility
    %w[scrim scrim-tint scrim-shade scrim-soft scrim-strong scrim-ink scrim-ink-muted].each do |name|
      assert_match(/^@utility #{name} \{/, css, "engine.css must define @utility #{name}")
    end
  end

  # ── theme-aware default: a tint in light mode, a shade in dark ──

  def test_root_carries_the_tint_and_dark_carries_the_shade
    assert_equal decls("@utility scrim-tint"), decls(":root").slice(*TONE_VARS),
      ":root (light mode and the no-class default) must be exactly the tint"
    assert_equal decls("@utility scrim-shade"), decls(".dark"),
      ".dark must be exactly the shade, so the theme-aware .scrim matches the forced one"
  end

  def test_every_tone_sets_every_tone_var
    [ "@utility scrim-tint", "@utility scrim-shade", ".dark" ].each do |sel|
      assert_equal TONE_VARS.sort, decls(sel).keys.sort, "#{sel} must set the whole tone, or a forced tone inherits half the other one"
    end
  end

  # ── the forced tones read the theme-INDEPENDENT tokens ────────

  def test_tint_reads_the_tint_tokens_and_shade_the_shade_tokens
    tint  = decls("@utility scrim-tint")
    shade = decls("@utility scrim-shade")
    assert_match(/\Avar\(--color-tint,/,            tint["--scrim-color"])
    assert_match(/\Avar\(--color-tint-ink,/,        tint["--scrim-ink"])
    assert_match(/\Avar\(--color-tint-ink-muted,/,  tint["--scrim-ink-muted"])
    assert_match(/\Avar\(--color-shade,/,           shade["--scrim-color"])
    assert_match(/\Avar\(--color-shade-ink,/,       shade["--scrim-ink"])
    assert_match(/\Avar\(--color-shade-ink-muted,/, shade["--scrim-ink-muted"])
    # Never the theme-following tokens: a forced tone must not flip with the theme.
    (tint.values + shade.values).each do |value|
      refute_match(/--color-(page|text)\b/, value, "a forced tone read a theme-following token: #{value}")
    end
  end

  def test_css_fallbacks_match_the_resolver_defaults
    {
      "@utility scrim-tint"  => %w[tint tint-ink tint-ink-muted],
      "@utility scrim-shade" => %w[shade shade-ink shade-ink-muted]
    }.each do |sel, tokens|
      values = decls(sel).values.join(" ")
      tokens.each do |token|
        fallback = values[/var\(--color-#{token},\s*(#[0-9A-Fa-f]{6})\)/, 1]
        refute_nil fallback, "#{sel} reads --color-#{token} with no hex fallback"
        assert_equal defaults["--color-#{token}"].downcase, fallback.downcase,
          "#{sel}'s fallback for --color-#{token} drifted from ThemeResolver"
      end
    end
  end

  # ── strength: the approved defaults, and the steps ────────────

  def test_default_strengths_are_the_approved_numbers
    tint  = decls("@utility scrim-tint")
    shade = decls("@utility scrim-shade")
    assert_equal %w[75% 58%], [tint["--scrim-tone-edge"],  tint["--scrim-tone-mid"]],  "the tint Alex approved on the hub hero"
    assert_equal %w[85% 70%], [shade["--scrim-tone-edge"], shade["--scrim-tone-mid"]], "the shade: the old navy rgba(26,21,53,.85/.7/.85)"
  end

  def test_soft_and_strong_step_from_the_tones_own_default
    soft   = decls("@utility scrim-soft")
    strong = decls("@utility scrim-strong")
    assert_equal "calc(var(--scrim-tone-edge) - 15%)", soft["--scrim-edge"]
    assert_equal "calc(var(--scrim-tone-mid) - 15%)",  soft["--scrim-mid"]
    assert_equal "calc(var(--scrim-tone-edge) + 10%)", strong["--scrim-edge"]
    assert_equal "calc(var(--scrim-tone-mid) + 10%)",  strong["--scrim-mid"]
  end

  def test_the_wash_reads_the_override_first_then_the_tone_default
    paint = decls("@utility scrim")["background-image"]
    refute_nil paint
    assert_includes paint, "135deg"
    assert_equal 2, paint.scan("var(--scrim-edge, var(--scrim-tone-edge))").size, "both end stops"
    assert_equal 1, paint.scan("var(--scrim-mid, var(--scrim-tone-mid))").size,  "the middle stop"
    assert_equal 3, paint.scan("color-mix(in srgb, var(--scrim-color)").size
  end

  # ── ink ───────────────────────────────────────────────────────

  def test_ink_classes_read_the_tone_and_muted_carries_its_weight
    assert_equal "var(--scrim-ink)", decls("@utility scrim-ink")["color"]
    muted = decls("@utility scrim-ink-muted")
    assert_equal "var(--scrim-ink-muted)", muted["color"]
    assert_equal "var(--scrim-ink-muted-weight)", muted["font-weight"]
  end

  def test_muted_ink_is_bold_body_on_a_tint_and_plain_secondary_on_a_shade
    assert_equal "600", decls("@utility scrim-tint")["--scrim-ink-muted-weight"]
    assert_equal "400", decls("@utility scrim-shade")["--scrim-ink-muted-weight"]
  end
end
