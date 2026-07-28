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
  def render_index
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    view.render(template: "style/index")
  end

  def with_features(features)
    original = Studio.features
    Studio.features = features
    yield
  ensure
    Studio.features = original
  end

  # --- 1. wallet brand icons ship inline, engine-owned -----------------------

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
      assert_includes html, "seeds-bar-continuous",
        "the :leveling seeds bar mounts in the _success_card yield"
      assert_includes html, "seedsShimmer",
        "the seeds bar ships its shimmer sweep"
      # The rolling digit reel + its unit label render inside the bar.
      assert_includes html, ">seeds<",
        "the seeds counter renders its unit label"
    end
  end

  test "with :leveling OFF the seeds bar is ABSENT even when :web3 is ON" do
    with_features(%i[web3]) do
      html = render_index
      refute_includes html, "seeds-bar-continuous",
        "a web3-only app (leveling off) gets the clean success card — no seeds bar"
    end
  end

  test "with both flags OFF the seeds bar is absent but icons stay inline" do
    with_features([]) do
      html = render_index
      refute_includes html, "seeds-bar-continuous",
        "leveling off => no seeds bar"
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
end
