# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"
require "tailwindcss/ruby"

# [integration] The layer scale as a CONSUMER RECEIVES IT — compiled, not read.
#
# WHY THIS TIER EXISTS AND WHAT IT SEES THAT THE UNIT TIER CANNOT.
# test/lib/layer_scale_contract_test.rb parses the `:root` block out of
# engine.css as TEXT. That is the right tier for the decision the scale records,
# and it is blind to everything between the source file and the bytes an app
# serves: this repo ships a Tailwind v4 ENTRY POINT, and a consumer reaches it
# through `@import "../builds/tailwind/studio_engine"` after a real compile.
# Between those two points sit @import resolution, layer ordering, declaration
# de-duplication, and the possibility that a later `:root` in the bundle shadows
# an earlier one — the exact mechanism by which a consumer shim outranked this
# gem for as long as one existed. A source read answers none of it, and the
# question this file asks is the only one an app cares about: in the stylesheet
# actually delivered, WHICH TIER WINS.
#
# It runs the same binary tailwindcss-rails hands consumers, over the same entry
# point, in the same order a consuming app assembles its own sheet — the pattern
# test/integration/tailwind_probe_build_test.rb established.
#
# THE PROPERTY. --z-toast and --z-toast-blur must resolve ABOVE --z-banner in
# the compiled bundle. With a modal open, engine.css lifts the environment bar
# stack to --z-banner at sticky top 0, over the same pixels #toast-container's
# fixed top-0 padding puts a toast's Dismiss button on. Ranked the other way the
# banner takes the click — and a toast carrying buttons is given duration 0, so
# that button is its only exit and the toast is stranded. The browser-level
# proof is e2e/toast_over_banner.spec.js; this is the same property one layer
# down, where it is cheap and total.
class LayerScaleBuildTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # Compile once — the Tailwind binary is the expensive part, and every
  # assertion below asks about the same artifact.
  def self.compiled
    @compiled ||= compile_consumer_bundle
  end

  # Assembled the way a consuming app assembles application.css: core Tailwind,
  # the shared preset, then the engine's component layer. Compare
  # e2e/tailwind_input.css and mcritchie-studio's own entry point.
  def self.compile_consumer_bundle
    Dir.mktmpdir("studio-engine-layer-scale") do |dir|
      File.write(File.join(dir, "probe.html"), %(<div class="card"></div>\n))
      File.write(File.join(dir, "tailwind.config.js"), <<~JS)
        const studio = require('#{ROOT}/tailwind/studio.tailwind.config.js')
        module.exports = { content: ['#{dir}/probe.html'], theme: studio.theme }
      JS
      File.write(File.join(dir, "input.css"), <<~CSS)
        @import 'tailwindcss';
        @config '#{dir}/tailwind.config.js';
        @import '#{ROOT}/app/assets/tailwind/studio_engine/engine.css';
      CSS

      out_path = File.join(dir, "out.css")
      _stdout, stderr, status = Open3.capture3(
        Tailwindcss::Ruby.executable,
        "-i", File.join(dir, "input.css"), "-o", out_path
      )
      raise "tailwind build failed:\n#{stderr}" unless status.success?

      File.read(out_path)
    end
  end

  # THE LAST DEFINITION WINS, and taking the last one is the point rather than a
  # detail. A tier defined twice in the delivered bundle resolves to whichever
  # the cascade reaches last; scanning for the FIRST would report the value the
  # browser discards, which is precisely how a shadowed token hides.
  def tier(name)
    values = self.class.compiled.scan(/#{Regexp.escape(name)}:\s*(-?\d+)/).flatten
    refute_empty values, "#{name} is not in the compiled bundle at all — a consumer " \
                         "importing this engine would resolve it to nothing"
    values.last.to_i
  end

  def test_integration_the_compiled_bundle_ranks_a_toast_above_the_banner
    banner = tier("--z-banner")

    %w[--z-toast --z-toast-blur].each do |above|
      assert_operator tier(above), :>, banner,
                      "in the COMPILED stylesheet a consumer serves, #{above} resolves to " \
                      "#{tier(above)} and --z-banner to #{banner}. With a modal open the bar " \
                      "stack is lifted to --z-banner at top 0, across the toast's Dismiss " \
                      "button — and a toast with buttons never auto-dismisses, so the toast " \
                      "is stranded for the rest of the session."
    end
  end

  # The order above is worth nothing if the lift stopped reading the tier. The
  # rule and the token travel together into the bundle or neither is delivered.
  def test_integration_the_modal_open_lift_survives_the_compile_reading_its_tier
    bundle = self.class.compiled
    rule = bundle[/body\.modal-open\s+\.studio-bar-stack[^{]*\{[^}]*\}/m]

    refute_nil rule, "the modal-open bar-stack lift is missing from the compiled bundle"
    assert_match(/z-index:\s*var\(--z-banner/, rule,
                 "the lift must read the shared tier in the DELIVERED css, not a bare number")
    assert_match(/position:\s*sticky/, rule,
                 "a scrolled reader never sees a bar that only got a z-index")
  end

  # The tiers around the pair, asserted on the same artifact: both still clear
  # the modal (the property the lift exists for) and the tooltip still clears
  # the banner it hangs off.
  def test_integration_the_compiled_bundle_keeps_both_tiers_over_the_modal
    modal = tier("--z-modal")

    assert_operator tier("--z-toast"), :>, modal, "a toast must surface over an open modal"
    assert_operator tier("--z-banner"), :>, modal,
                    "the environment bars must stay reachable over a modal"
    assert_operator tier("--z-tooltip"), :>, tier("--z-banner"),
                    "a banner tooltip must clear the banner it hangs off"
  end
end
