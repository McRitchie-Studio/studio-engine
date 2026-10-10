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

  # ── E. the portal (fizz_portal) ─────────────────────────────

  test "the default stack is unchanged: no portal hook, layers straight under the stack" do
    doc = render_button(hold_id: "desktop")

    stack = doc.at_css(".hold-stack")
    assert_nil stack["data-fizz-portal"], "no portal unless the caller opts in"
    assert_nil stack["x-init"], "and no Alpine hook on the stack"
    assert_nil doc.at_css(".hold-fizz-portal"), "no wrapper around the layers"
    assert_equal 2, doc.css(".hold-stack > .hold-fizz").size, "both layers sit directly in the stack"
    assert_equal render_button(hold_id: "desktop").to_html, render_button(hold_id: "desktop", fizz_portal: false).to_html,
      "fizz_portal: false renders exactly what the default renders"
  end

  test "fizz_portal wraps the layers and marks the stack for its controller to lift them out" do
    doc = render_button(hold_id: "phone", fizz_portal: true)

    stack = doc.at_css(".hold-stack")
    assert stack.key?("data-fizz-portal"), "the stack is marked"
    assert_equal "hold-button", stack["data-studio-controller"],
      "a stack mounted later (x-if, a modal) lifts its own layers when its controller connects"
    assert_nil stack["x-init"], "the portal is the controller's, not an Alpine hook"
    portal = doc.at_css(".hold-stack > .hold-fizz-portal")
    assert portal, "one wrapper, in the stack until the script moves it"
    assert_equal "true", portal["aria-hidden"]
    assert_includes portal["class"], "fizz-lively", "the wrapper carries the level the stack has"
    assert_equal 2, portal.css("> .hold-fizz").size, "both layers ride the wrapper"
    assert doc.at_css(".hold-stack > button.hold-btn"), "the button stays in the stack"
    assert_nil doc.at_css(".hold-btn .fizz-bit")
  end

  test "fizz_portal does nothing when there is no fizz" do
    doc = render_button(fizz: false, fizz_portal: true)

    assert_nil doc.at_css(".hold-stack")["data-fizz-portal"]
    assert_nil doc.at_css(".hold-fizz-portal")
  end

  test "the calm level's wrapper carries no lively modifier" do
    doc = render_button(hold_id: "calm", fizz_level: :calm, fizz_portal: true)

    refute_includes doc.at_css(".hold-fizz-portal")["class"], "fizz-lively"
    assert_equal 1, doc.css(".hold-fizz-portal > .hold-fizz").size
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

  # ── no JavaScript travels in a local ────────────────────────

  test "every removed string local raises, naming itself and the event that answers" do
    Studio::HoldButton::REMOVED_LOCALS.each do |local, event|
      error = assert_raises(ActionView::Template::Error, "#{local}: rendered") { render_button(hold_id: "board", local => "d.go()") }

      assert_kind_of ArgumentError, error.cause
      assert_includes error.message, "#{local}: (answer #{event})"
      assert_includes error.message, "no longer evaluates JavaScript-string locals"
    end
  end

  test "an empty string local raises too, and every one passed is named" do
    error = assert_raises(ActionView::Template::Error) { render_button(guard: "", on_success: "go()", validate_at: 150) }

    assert_includes error.message, "guard: (answer hold-button:guard), on_success: (answer hold-button:success)"
  end

  test "a removed local passed as nil renders the button" do
    doc = render_button(hold_id: "board", **Studio::HoldButton::REMOVED_LOCALS.keys.index_with { nil })

    assert doc.at_css("button.hold-btn")
  end

  test "the removed locals are the six, and the refusal runs in every environment" do
    assert_equal %i[guard on_hold_start validate early_action early_action_guard on_success],
                 Studio::HoldButton::REMOVED_LOCALS.keys
    source = File.read(File.join(ENGINE_ROOT, "lib/studio/hold_button.rb"))
    refute_match(/Rails\.env|ENV\[/, source)
  end

  # The browser refuses the attribute each local wrote: one table, two files.
  test "the hooks module refuses the attribute of every removed local" do
    source = File.read(File.join(ENGINE_ROOT, "app/javascript/studio/hold_button_hooks.js"))
    rows = source[/^export const REMOVED_HOOKS = \{\n(.*?)^\}/m, 1].scan(/"(data-[a-z-]+)": \["(\w+)", "([a-z:-]+)"\]/)

    assert_equal Studio::HoldButton::REMOVED_LOCALS.map { |local, event| [ "data-#{local.to_s.dasherize}", local.to_s, event ] }, rows
  end

  test "no button carries an attribute the hooks module refuses" do
    button = render_button(hold_id: "board", validate_at: 900, early_action_at: 1200, fizz_portal: true).at_css("button.hold-btn")

    assert_equal %w[class data-duration data-early-action-at data-hold-id data-studio-action data-validate-at style],
                 button.attribute_nodes.map(&:name).sort
  end

  # ── F. the controller's wiring ──────────────────────────────

  test "the stack carries the hold-button controller and the button its presses" do
    doc = render_button(hold_id: "desktop")

    assert_equal "hold-button", doc.at_css(".hold-stack")["data-studio-controller"]
    assert_equal %w[mousedown->hold-button#start mouseup->hold-button#end mouseleave->hold-button#end
                    touchstart->hold-button#press touchend->hold-button#end touchcancel->hold-button#end],
                 doc.at_css("button.hold-btn")["data-studio-action"].split
    button = doc.at_css("button.hold-btn")
    assert_empty button.attribute_nodes.map(&:name).grep(/\A@|\Ax-on:/), "no Alpine listener on the button"
  end

  test "the partial emits no script" do
    html = render_button(hold_id: "desktop", fizz_portal: true).to_html

    refute_match(/<script/i, html, "the behaviour is studio/hold_button, a module")
    refute_includes html, "holdBtnStart"
  end

  test "the timing attributes travel only when passed" do
    bare = render_button(hold_id: "desktop").at_css("button.hold-btn")
    assert_nil bare["data-validate-at"]
    assert_nil bare["data-early-action-at"]

    timed = render_button(hold_id: "desktop", validate_at: 150, early_action_at: 400).at_css("button.hold-btn")
    assert_equal "150", timed["data-validate-at"]
    assert_equal "400", timed["data-early-action-at"]
  end

  test "the module's slot count is the helper's" do
    source = File.read(File.join(ENGINE_ROOT, "app/javascript/studio/hold_button.js"))

    assert_equal Studio::FizzHelper::SLOTS, source[/^export const FIZZ_SLOTS = (\d+)$/, 1].to_i
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
