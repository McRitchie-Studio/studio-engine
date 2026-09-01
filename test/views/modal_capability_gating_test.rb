# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] Guard for engine 0.19's modal convergence — the engine-owned wallet
# brand icons and the capability-gated entry-confirmed / seeds / free-entry
# primitives. Renders the living style guide the way the app does and asserts the
# load-bearing properties, each EXERCISED against the real Studio.feature? flag
# (not merely declared):
#
#   1. Wallet brand icons ship INLINE from the engine (a <symbol> sprite +
#      <use> refs), with the letter tile only as an unknown-wallet fallback, and
#      no per-app PNG path left in the picker.
#   2. :web3 ON  → the generic entry-confirmed success renders (branded tx link).
#   3. :leveling ON  → the seeds bar mounts inside the _success_card yield.
#   4. :leveling OFF → the seeds bar is ABSENT even with :web3 on (a web3-only app
#      gets the clean success card) — the independent-flags contract.
#   5. The new modal ids register in the overlay and stay openable when a
#      capability is off (disabled-but-present preview), never hidden.
class ModalCapabilityGatingTest < ActiveSupport::TestCase
  # solana-studio's app/views. The Connect Wallet picker asserted below is the
  # GEM's partial since the two-template split moved the wallet UI out of this
  # engine — BASE is studio-engine + mcritchie-studio, WEB3 ADD is solana-studio
  # + turf-monster. style/_modals gates its registration on the partial
  # RESOLVING, so without this path the picker is simply absent and the brand-mark
  # assertions below describe a page that never rendered one.
  #
  # The dummy app REQUIRES solana-studio (test/dummy/config/application.rb), so
  # this is the faithful render. The absent-gem rendering is asserted directly in
  # test/views/style_web3_specimens_test.rb instead.
  #
  # NOTE the sprite ids asserted here (se-wallet-*) come from THIS engine —
  # studio/modals/blocks/_wallet_brand_sprite, which the gem's picker renders by
  # name across the gem boundary. That cross-repo contract is pinned in
  # style_web3_specimens_test.
  GEM_VIEWS = File.join(
    Gem::Specification.find_by_name("solana-studio").gem_dir, "app/views"
  ).freeze

  def render_index
    # A host renders these views through ApplicationController, which has EVERY
    # engine helper mixed in (no isolate_namespace). A bare test view has none, so
    # give it the whole set rather than the one module today's specimens happen to
    # call — otherwise the next helper-backed specimen breaks all five harnesses.
    view = ActionView::Base.with_empty_template_cache
                           .with_view_paths(["app/views", GEM_VIEWS])
    view.extend(Studio::Engine.helpers)
    view.render(template: "style/index")
  end

  def with_features(features)
    original = Studio.features
    Studio.features = features
    yield
  ensure
    Studio.features = original
  end

  # The entry-confirmed modal's rendered fragment (sliced between the stable
  # overlay id markers that bracket it). The flag-gating assertions below target
  # THAT card specifically: as of 0.22 the Modals section also ships the
  # Leveling-activities gallery, which renders the leveling-activity primitive
  # BOTH ways via an explicit `leveling:` override to showcase each mode — so
  # seeds chrome now appears on the page independent of the app flag. Scoping to
  # entry-confirmed keeps its "seeds bar is :leveling-gated" contract precise.
  def entry_confirmed_fragment(html)
    start = html.index("id === 'entry-confirmed'")
    return "" unless start
    rest = html[start..]
    stop = rest.index("id === 'ds-processing'")
    stop ? rest[0...stop] : rest
  end

  # --- 1. wallet brand icons ship inline, engine-owned -----------------------

  # A wallet with no brand still gets a MARK, not a hole. The three brand marks
  # are official rasters; this one cannot be, because "brand unknown" has no
  # official artwork to be faithful to — so it is paths, and it takes
  # currentColor, which is what lets a caller tint it to whatever it stands in
  # for. Asserted separately from the brand marks above because its CONTRACT is
  # the opposite of theirs: they must not be hand-drawn, and this one must be.
  test "the sprite ships a neutral fallback mark, drawn in paths and tintable" do
    html = render_index

    assert_includes html, %(id="se-wallet-default"),
      "a wallet whose brand we do not recognise still needs a mark to render"
    default_symbol = html[/<symbol id="se-wallet-default".*?<\/symbol>/m]
    assert default_symbol, "the fallback mark must be an inline <symbol> like the brands"

    assert_includes default_symbol, "currentColor",
      "the fallback must inherit its colour, so one mark serves every surface"
    assert_includes default_symbol, "<path",
      "the fallback is drawn, not embedded — it has no official raster to carry"
    assert_not_includes default_symbol, "base64",
      "a raster fallback would need a second asset for every size it is shown at"
  end

  test "the wallet picker ships engine-owned inline brand marks, not app PNGs" do
    html = render_index

    # The sprite ships all three brand marks as inline <symbol>s.
    %w[se-wallet-phantom se-wallet-solflare se-wallet-backpack].each do |sym|
      assert_includes html, %(id="#{sym}"),
        "the engine wallet sprite must ship the inline #{sym} mark"
    end

    # The picker resolves a mark by name and <use>s it (detected + install rows).
    assert_includes html, "brandIcon(",
      "the picker resolves a known wallet name to its brand <symbol>"
    assert_includes html, "'#se-wallet-' + brandIcon(w.name)",
      "a detected wallet row references its brand mark by name"

    # The letter tile survives ONLY as the unknown-wallet fallback.
    assert_includes html, 'x-text="w.name.slice(0,1)"',
      "an unknown wallet still falls back to a letter tile"

    # No app-served PNG path remains — the whole point of owning the icons.
    refute_includes html, "/wallet-phantom.png",
      "the engine picker must not reference an app-served wallet PNG"
    refute_includes html, "/wallet-solflare.png"
    refute_includes html, "/wallet-backpack.png"

    # Each mark embeds the wallet's OFFICIAL brand asset inline (a base64 PNG
    # data-URI, byte-matching what the wallet ships) — not a hand-drawn path that
    # drifts from the brand. The old inaccurate Phantom ghost path is gone.
    %w[se-wallet-phantom se-wallet-solflare se-wallet-backpack].each do |sym|
      assert_match(%r{id="#{sym}".*?data:image/png;base64}m, html,
        "the #{sym} mark embeds its real brand asset inline")
    end
    refute_includes html, "M110.584 64.9142",
      "the inaccurate hand-drawn Phantom ghost path is gone"
  end

  # --- 2. :web3 gates the generic entry-confirmed success --------------------

  test "with :web3 ON the entry-confirmed generic success renders (branded tx link)" do
    with_features(%i[web3]) do
      html = render_index
      assert_includes html, "$store.dsModals.open('entry-confirmed'",
        "the entry-confirmed specimen is wired"
      assert_includes html, "explorer.solana.com/tx/",
        "the generic entry-confirmed success renders the branded Solana tx link"
    end
  end

  # --- 3 + 4. :leveling gates the seeds bar, independently of :web3 -----------

  test "with :leveling ON the seeds bar mounts inside the entry-confirmed card" do
    with_features(%i[web3 leveling]) do
      html = render_index
      assert_includes entry_confirmed_fragment(html), "seeds-bar-continuous",
        "the :leveling seeds bar mounts INSIDE the entry-confirmed card (scoping is not vacuous)"
      assert_includes html, "seeds-bar-continuous",
        "the :leveling seeds bar mounts in the _success_card yield"
      assert_includes html, "seeds-shimmer",
        "the seeds bar ships its shimmer sweep (class-driven)"
      assert_includes html, "seeds-reel-track",
        "the rolling digit reel uses the class-based (reduced-motion-reachable) track"
      # The rolling digit reel + its unit label render inside the bar.
      assert_includes html, ">seeds<",
        "the seeds counter renders its unit label"
    end
  end

  test "with :leveling OFF the seeds bar is ABSENT even when :web3 is ON" do
    with_features(%i[web3]) do
      html = render_index
      refute_includes entry_confirmed_fragment(html), "seeds-bar-continuous",
        "a web3-only app (leveling off) gets the clean success card — no seeds bar"
    end
  end

  test "with both flags OFF the seeds bar is absent but icons stay inline" do
    with_features([]) do
      html = render_index
      refute_includes entry_confirmed_fragment(html), "seeds-bar-continuous",
        "leveling off => no seeds bar in the entry-confirmed card"
      # Brand icons are not capability-gated — they always ship inline.
      assert_includes html, %(id="se-wallet-phantom"),
        "wallet brand marks ship regardless of capability flags"
    end
  end

  # --- 5. the new modal ids register + stay openable when gated off ----------

  test "the entry-confirmed + free-entry-earned modals register and stay openable" do
    with_features([]) do
      html = render_index
      %w[entry-confirmed free-entry-earned].each do |id|
        assert_includes html, "$store.dsModals.current().id === '#{id}'",
          "the overlay must register the #{id} modal"
        assert_includes html, "$store.dsModals.open('#{id}'",
          "the #{id} specimen stays present + openable, not hidden"
      end
      # Capability specimens are flagged disabled but keep the click affordance.
      assert_includes html, "disabled on this app"
      assert_includes html, "opacity-60 grayscale"
    end
  end

  # --- 6. reduced-motion is EFFECTIVE, not merely declared -------------------
  # Carl's blocker: inline `style="transition/animation: …"` beats a class rule
  # on specificity, so the @media(prefers-reduced-motion) override could never
  # win. Guard the fix mutation-first: the motion PROPERTY lives on the classes
  # (reachable by the @media block), NOT in the view's inline styles.

  ENGINE_ROOT   = File.expand_path("../..", __dir__)
  SEEDS_BAR_ERB = File.join(ENGINE_ROOT, "app/views/studio/modals/blocks/_seeds_bar.html.erb")
  DIGIT_REEL_ERB = File.join(ENGINE_ROOT, "app/views/studio/modals/blocks/_digit_reel.html.erb")
  MOTION_CSS    = File.join(ENGINE_ROOT, "app/assets/tailwind/studio_engine/engine-motion.css")

  test "seeds motion lives on classes so reduced-motion can cancel it (not inline)" do
    css = File.read(MOTION_CSS)
    # The three motion properties live on classes.
    assert_match(/\.seeds-bar-continuous\s*\{[^}]*transition:\s*--bar-progress/m, css,
      "the bar fill transition lives on .seeds-bar-continuous")
    assert_match(/\.seeds-reel-track\s*\{[^}]*transition:\s*transform/m, css,
      "the reel slide transition lives on .seeds-reel-track")
    assert_match(/\.seeds-shimmer\s*\{[^}]*animation:\s*seedsShimmer/m, css,
      "the shimmer animation lives on .seeds-shimmer")

    # The reduced-motion block cancels ALL THREE — reachable because they are
    # class-based. These literal cancel rules live only in the reduced-motion
    # @media block; a regressor that drops any of them reddens here.
    assert_includes css, "@media (prefers-reduced-motion: reduce)"
    assert_includes css, ".seeds-bar-continuous { transition: none; }"
    assert_includes css, ".seeds-reel-track { transition: none; }"
    assert_includes css, ".seeds-shimmer { animation: none; }"
  end

  test "the seeds view keeps motion OUT of inline styles (the specificity bug)" do
    bar  = File.read(SEEDS_BAR_ERB)
    reel = File.read(DIGIT_REEL_ERB)

    # A plain (non-Alpine) inline style attribute must not carry the motion —
    # that is exactly what beat the reduced-motion override.
    refute_match(/style="[^"]*transition:\s*--bar-progress/, bar,
      "the bar fill transition must NOT be an inline style (it would beat reduced-motion)")
    refute_match(/style="[^"]*animation:\s*seedsShimmer/, bar,
      "the shimmer animation must NOT be an inline style (it would beat reduced-motion)")

    # The fix is in place: the fill-duration knob is inline, motion is class-based.
    assert_includes bar, "--seeds-fill-dur",
      "the view sets the fill-duration knob inline while the property stays class-based"
    assert_includes bar, %(track_class: "seeds-reel-track"),
      "the reel is rendered with the class-based track (no inline transition)"

    # The reel omits its inline transition when a track_class is supplied.
    assert_match(/track_class\s*\?\s*""\s*:/, reel,
      "the digit reel drops its inline transition when track_class is used")
  end
end
