# frozen_string_literal: true

require "test_helper"
require_relative "../support/engine_tailwind_build"

# [integration] The glass surface tokens as a CONSUMER RECEIVES THEM: compiled by the
# Tailwind binary tailwindcss-rails hands an app, over the engine's entry point, not
# read as source text (test/views/glass_surface_tokens_css_test.rb is that tier).
#
# THE PROPERTY. An app overrides --glass-surface-tint and --glass-surface-shadow-tint
# with a plain, unlayered :root rule (docs/NEW_APP_SETUP.md § 9). That wins only while
# the engine's defaults stay INSIDE a cascade layer: an unlayered engine default would
# tie on specificity and win or lose on source order. And the light surface rules must
# still read the tokens after the compile. The browser proof is
# e2e/glass_surface_tokens.spec.js.
class GlassSurfaceTokensBuildTest < Minitest::Test
  def self.compiled
    @compiled ||= EngineTailwindBuild.compile(%w[card badge input-field])
  end

  # The cascade layers open at a byte offset, outermost first. Comments are dropped
  # first, because a brace inside one would throw the count off.
  def layers_at(css, index)
    stack = []
    css.to_enum(:scan, /@layer\s+([\w-]+)\s*\{|\{|\}/).each do
      match = Regexp.last_match
      break if match.begin(0) >= index

      if match[0] == "}"
        stack.pop
      else
        stack.push(match[1] || :block)
      end
    end
    stack.grep(String)
  end

  def bundle
    self.class.compiled.gsub(%r{/\*.*?\*/}m, "")
  end

  def test_integration_the_token_defaults_ship_inside_the_utilities_layer
    css = bundle
    index = css.index("--glass-surface-tint: 29 24 50") || flunk("the tint default is not in the compiled bundle")

    assert_includes layers_at(css, index), "utilities",
                    "an unlayered default would fight an app's unlayered :root override on source order"
    assert_match(/--glass-surface-shadow-tint:\s*60 50 120/, css)
  end

  def test_integration_the_light_surface_values_read_the_tokens_after_the_compile
    css = bundle

    assert_match(/--surface-glass-line:\s*rgb\(var\(--glass-surface-tint\) \/ 0\.1\)/, css)
    assert_match(/--surface-glass-shadow:\s*0 6px 20px rgb\(var\(--glass-surface-shadow-tint\) \/ 0\.08\)/, css)
    %w[--lit-soft-bottom --lit-soft-pressed --lit-badge --lit-input].each do |name|
      assert_match(/#{name}:[^;]*rgb\(var\(--glass-surface-tint\)/, css, "#{name} lost its token in the compile")
    end
    refute_match(/rgb\((29 24 50|60 50 120) \//, css.scan(/html\[data-surface-style="glass"\]\s*\{[^}]*\}/).join)
  end
end
