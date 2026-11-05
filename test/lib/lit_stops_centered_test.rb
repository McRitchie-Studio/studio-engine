# frozen_string_literal: true

require_relative "../test_helper"

# [unit] The lit buttons' gradient stops are centered on their fill, read from engine.css as
# source (task lit-button-centers-on-brand).
#
# THE DEFECT THIS PINS. The lit primary stepped down from --color-cta at both stops
# (l - 0.03 and l - 0.18) and added chroma, so the whole button sat darker and more saturated
# than the text-primary word beside it: two purples. The semantic variants were symmetric in
# lightness but added chroma too.
#
# THE LINE IT HOLDS. Every filled variant's top and low stop come from the same --lit-fill, step
# lightness by the same amount up and down, and keep chroma and hue as they are. Then the oklab
# midpoint is the token. The primary's fill is --color-cta, the brand violet. Whether the painted
# midpoint really is the token is the browser's question: e2e/glass_surfaces.spec.js.
class LitStopsCenteredTest < Minitest::Test
  ENGINE_CSS = File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)
  VARIANTS = %w[primary secondary danger warning success].freeze
  STOP = /oklch\(from var\(--lit-fill\) calc\(l ([+-]) ([\d.]+)\) (\S+) (\S+) \/ var\(--lit-fill-alpha, 1\)\)/

  def css
    @css ||= File.read(ENGINE_CSS).gsub(%r{/\*.*?\*/}m, "")
  end

  # Every glass rule body that sets the property, with the selector it sits under.
  def rules_setting(prop)
    css.scan(/(html\[data-surface-style="glass"\][^{}]*)\{([^{}]*)\}/m)
       .select { |_sel, body| body.include?("#{prop}:") }
       .map { |sel, body| [sel.strip, body[/#{Regexp.escape(prop)}:\s*([^;]+);/, 1].strip] }
  end

  def stop_for(variant, prop)
    hits = rules_setting(prop).select { |sel, _| sel.match?(/\.btn-#{variant}\b/) }
    assert_equal 1, hits.size, "btn-#{variant}: expected one rule setting #{prop}, found #{hits.map(&:first).inspect}"
    hits.first.last
  end

  def test_every_variant_steps_lightness_the_same_amount_up_and_down
    VARIANTS.each do |variant|
      top = STOP.match(stop_for(variant, "--lit-top-stop"))
      low = STOP.match(stop_for(variant, "--lit-low-stop"))
      refute_nil top, "btn-#{variant} top stop is not a relative oklch from --lit-fill"
      refute_nil low, "btn-#{variant} low stop is not a relative oklch from --lit-fill"
      assert_equal "+", top[1], "btn-#{variant}: the top stop is lighter than the fill"
      assert_equal "-", low[1], "btn-#{variant}: the low stop is darker than the fill"
      assert_equal top[2], low[2], "btn-#{variant}: the steps are symmetric, so the midpoint is the fill"
      assert_operator top[2].to_f, :>=, 0.04, "btn-#{variant}: a step under 0.04 flattens the 3D look"
      assert_operator top[2].to_f, :<=, 0.08, "btn-#{variant}: a step over 0.08 washes the top out"
    end
  end

  def test_chroma_and_hue_pass_through_unchanged
    VARIANTS.each do |variant|
      %w[--lit-top-stop --lit-low-stop].each do |prop|
        m = STOP.match(stop_for(variant, prop))
        refute_nil m, "btn-#{variant} #{prop} is not a relative oklch from --lit-fill"
        assert_equal %w[c h], [m[3], m[4]], "btn-#{variant} #{prop}: chroma and hue stay the token's"
      end
    end
  end

  def test_the_primary_centers_on_the_brand_violet
    assert_equal "var(--color-cta)", stop_for("primary", "--lit-fill"),
      "the lit primary centers on --color-cta, the violet a text-primary word paints"
  end
end
