# frozen_string_literal: true

require "test_helper"
require "action_view"

# The nav-offset contract — both halves in one file, because either half alone is
# silently useless.
#
#   --nav-h      the header's HEIGHT
#   --nav-bottom the header's BOTTOM EDGE, in viewport coordinates
#
# They are equal only when the header starts at the top of the viewport, which is
# exactly why one was used for the other for so long without anyone noticing. A
# `fixed` overlay offset by the HEIGHT rides UP over the header by the height of
# any chrome stacked above it. mcritchie-industries renders an environment banner
# before the navbar; the open sidebar panel overlapped the header by 47px and
# covered the Log in button. Production self-gates that banner off, so the bug was
# only ever visible on QA — which is where the operator reviews.
#
# The failure this file exists to prevent is a SILENT one. The panel falls back to
# --nav-h, so if the publisher ever stops emitting --nav-bottom the panel quietly
# returns to the old broken geometry with nothing red anywhere. That is why the
# PUBLISHER is asserted here too, not just the consumer.
#
# What this tier cannot do: run the JS, or lay out a page. The engine has no
# browser lane, so this holds the CONTRACT, not the pixels. The pixel proof has to
# come from a consumer that has one.
class NavOffsetContractTest < Minitest::Test
  # ASSERT THE ASSIGNMENT PAIR, NOT THE TOKENS.
  #
  # The first version of this file asked whether '--nav-h', '--nav-bottom',
  # 'offsetHeight' and 'getBoundingClientRect().bottom' each appeared SOMEWHERE in
  # the rendered head. That pins a vocabulary, not a wiring. Shannon defeated it
  # with a mutation that deletes no token at all — just swap the two sources:
  #
  #   style.setProperty('--nav-h',      Math.max(0, header.getBoundingClientRect().bottom) + 'px');
  #   style.setProperty('--nav-bottom', header.offsetHeight + 'px');
  #
  # Every grepped string survives, the banner-overlap bug is fully restored, every
  # --nav-h consumer in the engine breaks — and the suite was green. Each regex
  # below therefore spans the property name AND the expression feeding it, so the
  # two cannot be exchanged without going red.
  def test_head_publishes_the_bottom_edge_from_the_headers_rect
    html = render_head

    # The height keeps its old meaning — consumers size off it and must not shift.
    assert_match(/setProperty\(\s*'--nav-h'\s*,\s*\w+\.offsetHeight/, html,
                 "--nav-h must be fed by the header's HEIGHT, not by its rect")

    # The offset is a DIFFERENT measurement and must come from the rect, clamped.
    # Feeding it from offsetHeight would reintroduce the bug under a new name.
    assert_match(
      /setProperty\(\s*'--nav-bottom'\s*,\s*Math\.max\(\s*0\s*,\s*\w+\.getBoundingClientRect\(\)\.bottom/,
      html,
      "--nav-bottom must be fed by the header's clamped rect BOTTOM, not by its height"
    )

    # And neither may be fed by the other's source, in any spelling.
    refute_match(/setProperty\(\s*'--nav-h'\s*,[^;]*getBoundingClientRect/, html,
                 "feeding --nav-h from the rect breaks every consumer that sizes off it")
    refute_match(/setProperty\(\s*'--nav-bottom'\s*,[^;]*offsetHeight/, html,
                 "feeding --nav-bottom from the height IS the banner-overlap bug")
  end

  def test_head_republishes_the_bottom_edge_on_scroll
    html = render_head

    # Chrome above the header scrolls away WHILE a panel is open — nothing in the
    # engine locks body scroll — so a bottom edge published only on resize goes
    # stale mid-scroll and the panel drifts. --nav-h has no such problem, which is
    # why the publisher cannot simply treat the two the same.
    assert_match(/addEventListener\(\s*'scroll'\s*,\s*(\w+)\s*,\s*\{\s*passive:\s*true\s*\}/, html,
                 "the bottom edge is scroll-dependent and must be republished on a passive scroll listener")

    # The listener has to DO something. Greping for 'requestAnimationFrame' alone
    # passed a mutation that kept the rAF and dropped the republish:
    #   window.requestAnimationFrame(function () { queued = false; });
    # which kills scroll tracking entirely — the exact drift this test names.
    # So: the rAF callback must actually call the publisher.
    assert_match(/requestAnimationFrame\(\s*function\s*\([^)]*\)\s*\{[^}]*publish\(/, html,
                 "the rAF callback must republish — a throttle that never publishes is not a throttle")

    # And the scroll handler must be the one that schedules that frame, rather than
    # some unrelated function that merely shares the name.
    scroll_handler = html[/addEventListener\(\s*'scroll'\s*,\s*(\w+)/, 1]
    refute_nil scroll_handler, "could not identify the scroll handler"
    assert_match(/function\s+#{Regexp.escape(scroll_handler)}\s*\([^)]*\)\s*\{[^}]*requestAnimationFrame/m, html,
                 "the function bound to scroll must be the one that schedules the republish")
  end

  def test_head_releases_the_header_when_a_page_has_none
    html = render_head

    # The scroll listener outlives the visit, so a Turbo nav to a headerless page
    # would otherwise keep publishing from the DETACHED old node — an all-zero rect,
    # which drives --nav-h to 0px. Nothing ran after detach before this listener
    # existed, so --nav-h kept its last value; the no-header branch has to release
    # the node to keep that promise. Shape-level, like the rest of this file.
    # Extract the guard BODY — everything between `if (!header) {` and its `return;`
    # — and assert inside it. A whole-file grep would pass on a `current = null`
    # anywhere else in the IIFE, which is the same token-vs-wiring mistake this
    # file was blocked for. It also keeps a failure message readable.
    guard = html[/if\s*\(\s*!header\s*\)\s*\{([\s\S]*?)\breturn;/, 1].to_s

    refute_empty guard, "could not find the no-header guard block in the rendered head"
    assert_includes guard, "current = null",
                    "the no-header branch must drop the stale node, not just return"
    assert_includes guard, "disconnect()",
                    "and must disconnect the observer bound to the old header"
  end

  def test_sidebar_panel_offsets_from_the_bottom_edge_not_the_height
    html = render_sidebar_panel

    assert_includes html, "top:var(--nav-bottom, var(--nav-h, 6rem))",
                    "a fixed panel must start at the header's bottom edge"
    assert_includes html, "height:calc(100% - var(--nav-bottom, var(--nav-h, 6rem)))",
                    "and must be sized from that same edge, or it runs past the viewport"

    # The exact shape of the regression, pinned. --nav-h survives only as the
    # fallback INSIDE var(--nav-bottom, ...), never as the offset itself.
    refute_includes html, "top:var(--nav-h,",
                    "offsetting a fixed panel by the header HEIGHT is the banner-overlap bug"
  end

  private

  def render_head
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    def view.csrf_meta_tags = ""
    def view.csp_meta_tag = ""
    def view.studio_theme_css_tag = ""
    def view.javascript_importmap_tags = "<script></script>"

    view.render(partial: "layouts/studio/head")
  end

  def render_sidebar_panel
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])

    view.render(partial: "components/sidebar_panel", locals: { open: "false" })
  end
end
