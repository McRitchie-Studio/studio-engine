# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require_relative "../../app/helpers/studio/fizz_helper"

# [component] The hold-to-confirm button, rendered — the markup half of the
# contract engine-motion.css styles.
#
# The load-bearing shapes:
#   A. The bubbles are the button's SIBLING inside .hold-stack. A child cannot
#      get behind the button's own background (its transform makes it a stacking
#      context), so this is the difference between bubbles escaping the edges and
#      bubbles sitting on the face.
#   B. Every hook the stylesheet targets is emitted: the ring, the tick, four
#      sliding labels, the nudge countdown.
#   C. The levels differ by layer count, not by speed — lively renders the
#      hover-only second layer, calm renders one and pays for nothing.
#   D. A palette can arrive statically (fizz_colors) or bound (fizz_bind), and
#      each bubble reads its own slot with its hue as the fallback.
class HoldButtonTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  # ── A + B. the stack, and every hook the CSS styles ─────────

  test "the fizz layer is the button's sibling, never its child" do
    doc = render_button(hold_id: "desktop")

    assert doc.at_css(".hold-stack > .hold-fizz"), "the layer lives in the stack"
    assert doc.at_css(".hold-stack > button.hold-btn"), "the button is its sibling"
    assert_nil doc.at_css(".hold-btn .fizz-bit"), "no bubble may live inside the button"
    assert_equal "true", doc.at_css(".hold-fizz")["aria-hidden"],
      "decoration stays out of the accessibility tree"
  end

  test "every hook the stylesheet targets is rendered" do
    doc = render_button

    assert doc.at_css(".hold-btn > .hold-icon > svg.progress circle"), "progress ring"
    assert doc.at_css(".hold-btn > .hold-icon > svg.tick polyline"), "tick"
    assert_equal 4, doc.css(".hold-btn ul.hold-text > li").size,
      "four labels: idle / holding / confirmed / blocked"
    assert doc.at_css(".hold-btn .nudge-debug .countdown-num"), "dev nudge countdown"
  end

  test "the labels and duration are the caller's" do
    doc = render_button(duration: 3500, default_text: "Hold to Pay",
                        hold_text: "Nearly", success_text: "Paid", error_text: "Declined")

    assert_includes doc.at_css(".hold-btn")["style"], "--duration: 3500ms"
    assert_equal [ "Hold to Pay", "Nearly", "Paid", "Declined" ],
                 doc.css(".hold-btn ul.hold-text > li").map(&:text)
  end

  # ── C. the two levels ───────────────────────────────────────

  test "lively is the default and carries the hover-only second layer" do
    doc = render_button(hold_id: "lively")

    assert doc.at_css(".hold-stack.fizz-lively"), "lively is the default level"
    assert_equal 2, doc.css(".hold-stack > .hold-fizz").size, "both layers"
    assert doc.at_css(".hold-stack > .hold-fizz-extra"), "the hover layer is marked"
    assert_equal Studio::FizzHelper::ZONES * 10, doc.css(".fizz-bit").size,
      "hover doubles the bubble count"
    refute_equal doc.css(".hold-fizz:not(.hold-fizz-extra) > .fizz-bit").map { |b| b["style"] },
                 doc.css(".hold-fizz-extra > .fizz-bit").map { |b| b["style"] },
                 "the second scatter must fill the first one's gaps, not shadow it"
  end

  test "calm renders one layer and pays for no second" do
    doc = render_button(hold_id: "calm", fizz_level: :calm)

    assert_nil doc.at_css(".fizz-lively"), "calm drops the modifier"
    assert_nil doc.at_css(".hold-fizz-extra"), "and the hover layer with it"
    assert_equal Studio::FizzHelper::ZONES * 5, doc.css(".fizz-bit").size
  end

  test "fizz false renders no bubbles at all" do
    doc = render_button(fizz: false)

    assert doc.at_css("button.hold-btn"), "the button still renders"
    assert_nil doc.at_css(".hold-fizz"), "with no particle layer"
  end

  # ── D. the palette ──────────────────────────────────────────

  test "each bubble reads its own slot and falls back to its hue" do
    doc = render_button(hold_id: "desktop")

    doc.css(".fizz-bit").each do |bit|
      assert_match(/--fc:var\(--fizz-c-\d+, hsl\(/, bit["style"],
        "a bubble reads its slot with its own hue behind it")
    end
    # Zone by zone: the resting layer takes its zone's first slot, the hover
    # layer the second and third.
    slots = ->(sel) { doc.css(sel).map { |b| b["style"][/--fizz-c-(\d+)/, 1].to_i }.uniq.sort }
    assert_equal [ 1, 4, 7, 10, 13, 16 ], slots.call(".hold-fizz:not(.hold-fizz-extra) > .fizz-bit")
    assert_equal [ 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 ], slots.call(".hold-fizz-extra > .fizz-bit")
  end

  test "a static palette paints the slots and a bound one rides Alpine" do
    static = render_button(hold_id: "teams", fizz_colors: %w[#ff0000 #00ff00 #0000ff])
    assert_includes static.at_css(".hold-stack")["style"], "--fizz-c-1:#ff0000"
    assert_includes static.at_css(".hold-stack")["style"], "--fizz-c-3:#0000ff"

    bound = render_button(hold_id: "bound", fizz_bind: "fizzPalette")
    assert_equal "fizzPalette", bound.at_css(".hold-stack")[":style"],
      "a runtime palette binds to the stack's style"
  end

  test "a palette longer than the slot count is truncated, not spilled" do
    doc = render_button(hold_id: "long", fizz_colors: Array.new(30) { "#123456" })

    style = doc.at_css(".hold-stack")["style"]
    assert_includes style, "--fizz-c-#{Studio::FizzHelper::SLOTS}:"
    refute_includes style, "--fizz-c-#{Studio::FizzHelper::SLOTS + 1}:"
  end

  # ── callbacks travel as data-*, not baked into a global ──────

  test "per-instance callbacks travel with the button" do
    doc = render_button(hold_id: "board", guard: "d.ready", on_success: "d.confirm()",
                        validate: "d.check()", validate_at: 900,
                        early_action: "d.early()", early_action_guard: "d.web3",
                        on_hold_start: "d.warmUp()")

    button = doc.at_css("button.hold-btn")
    assert_equal "board", button["data-hold-id"]
    assert_equal "d.ready", button["data-guard"]
    assert_equal "d.confirm()", button["data-on-success"]
    assert_equal "d.check()", button["data-validate"]
    assert_equal "900", button["data-validate-at"]
    assert_equal "d.early()", button["data-early-action"]
    assert_equal "d.web3", button["data-early-action-guard"]
    assert_equal "d.warmUp()", button["data-on-hold-start"]
  end

  private

  def render_button(**locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(
      [ File.join(ENGINE_ROOT, "app/views") ]
    )
    view.extend(Studio::FizzHelper)
    Nokogiri::HTML::DocumentFragment.parse(
      view.render(partial: "studio/hold_button", locals: locals).to_s
    )
  end
end
