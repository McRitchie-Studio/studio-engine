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
  # THE SOURCES ARE NOW ONE HOP AWAY, AND THE BINDING IS STILL ASSERTED.
  #
  # publish() used to write each property straight from its expression, and this
  # test matched property-and-expression in one regex. Both values are now READ
  # INTO LOCALS FIRST and written after, for two reasons the publisher's own
  # comment records: a write to an inherited custom property on documentElement
  # invalidates style, so a read taken after one write forces a fresh layout;
  # and each write is now skipped when the value has not changed.
  #
  # Rather than relax to "offsetHeight appears somewhere" — the exact
  # vocabulary-not-wiring mistake this file was blocked for — each assertion
  # below CAPTURES the local a source is read into and requires THAT local to be
  # the one written. Shannon's swap mutation still dies here: exchange the two
  # sources and the captured names cross, so both matches fail.
  def test_head_publishes_the_bottom_edge_from_the_headers_rect
    html = render_head

    # The height keeps its old meaning — consumers size off it and must not shift.
    h_local = html[/var\s+(\w+)\s*=\s*\w+\.offsetHeight\s*;/, 1]
    refute_nil h_local, "--nav-h's source must still be the header's offsetHeight"
    assert_match(/setProperty\(\s*'--nav-h'\s*,\s*#{Regexp.escape(h_local)}\s*\+/, html,
                 "--nav-h must be written from the local read out of offsetHeight, not from anything else")

    # The offset is a DIFFERENT measurement and must come from the rect, clamped.
    # Feeding it from offsetHeight would reintroduce the bug under a new name.
    b_local = html[/var\s+(\w+)\s*=\s*Math\.max\(\s*0\s*,\s*\w+\.getBoundingClientRect\(\)\.bottom\s*\)\s*;/, 1]
    refute_nil b_local, "--nav-bottom's source must still be the clamped rect bottom"
    assert_match(/setProperty\(\s*'--nav-bottom'\s*,\s*#{Regexp.escape(b_local)}\s*\+/, html,
                 "--nav-bottom must be written from the local read out of the clamped rect bottom")

    refute_equal h_local, b_local, "the two measurements must not collapse into one local"

    # And neither may be fed by the other's source, in any spelling.
    refute_match(/setProperty\(\s*'--nav-h'\s*,[^;]*getBoundingClientRect/, html,
                 "feeding --nav-h from the rect breaks every consumer that sizes off it")
    refute_match(/setProperty\(\s*'--nav-bottom'\s*,[^;]*offsetHeight/, html,
                 "feeding --nav-bottom from the height IS the banner-overlap bug")
  end

  # THE ANTI-THRASH ORDER, which is the point of hoisting the reads at all.
  #
  # THE MUTATION THIS KILLS: moving either read back below the first write.
  # Every assertion above still passes — same sources, same locals, same
  # properties — and the second read forces a layout against a style tree the
  # first write just dirtied, which is the per-frame cost this change removed.
  def test_head_reads_both_measurements_before_writing_either
    html = render_head
    body = html[/function publish\(header\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty body, "could not isolate publish()"

    last_read  = [body.index("offsetHeight"), body.index("getBoundingClientRect")].compact.max
    first_write = body.index("setProperty")
    refute_nil last_read
    refute_nil first_write
    assert last_read < first_write,
           "both geometry reads must precede both writes — a read after a write to " \
           "documentElement forces a fresh layout, which is the thrash this removed"
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

  # === THE PINNED STACK ==================================================
  #
  # --nav-h and --nav-bottom answer for ONE element. Everything else that pins
  # has been re-deriving the same geometry by hand: on mcritchie-studio's
  # /deployments the app strip positions itself with `:style="{ top: offset +
  # 'px' }"`, and the lane headers compute "site header height + strip height"
  # in Alpine behind their OWN ResizeObserver on .vt-pinned-header — while
  # --nav-bottom, which already answers the first half, goes unused there.
  #
  # Any element carrying data-pin="<name>" now publishes --pin-<name>-h and
  # --pin-<name>-bottom, so a consumer composes layers in pure CSS.

  def test_head_publishes_geometry_for_every_data_pin_element
    html = render_head

    assert_match(/querySelectorAll\(\s*['"]\[data-pin\]['"]\s*\)/, html,
                 "the publisher must find pinned layers by data-pin")
    assert_match(/setProperty\(\s*['"]--pin-['"]\s*\+\s*\w+\.name\s*\+\s*['"]-h['"]/, html,
                 "each pin publishes its own height under its own name")
    assert_match(/setProperty\(\s*['"]--pin-['"]\s*\+\s*\w+\.name\s*\+\s*['"]-bottom['"]/, html,
                 "each pin publishes its own bottom edge under its own name")

    # Same sourcing discipline as the header's pair: height from offsetHeight,
    # bottom from the CLAMPED rect. A hidden layer must measure 0 so it drops
    # out of a consumer's max() — that is what removes the need for a declared
    # stacking order, and an unclamped rect bottom could go negative and win.
    pin = html[/function publishPin\(pin\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty pin, "could not isolate publishPin()"
    assert_match(/=\s*pin\.el\.offsetHeight/, pin, "pin height comes from offsetHeight")
    assert_match(/Math\.max\(\s*0\s*,\s*pin\.el\.getBoundingClientRect\(\)\.bottom\s*\)/, pin,
                 "pin bottom comes from the CLAMPED rect bottom, so a hidden layer measures 0")

    # Both reads before either write, and no-op writes skipped — the same two
    # properties of publish(), for the same reasons.
    last_read = [pin.index("offsetHeight"), pin.index("getBoundingClientRect")].compact.max
    first_write = pin.index("setProperty")
    assert last_read < first_write,
           "a pin's reads must precede its writes, or the second forces a fresh layout"
    assert_match(/if\s*\(\s*h\s*!==\s*pin\.lastH\s*\)/, pin, "an unchanged height must skip its write")
    assert_match(/if\s*\(\s*bottom\s*!==\s*pin\.lastBottom\s*\)/, pin, "an unchanged bottom must skip its write")
  end

  def test_pins_share_one_observer_and_one_frame
    html = render_head

    # N pinned layers must not mean N observers or N frames. schedule() already
    # coalesces; the pins ride it.
    assert_equal 1, html.scan(/new ResizeObserver\(/).length,
                 "every pinned layer shares the one observer"
    sched = html[/function schedule\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    assert_match(/publishPin\(/, sched, "pins must publish inside the coalesced frame, not on their own")
  end

  def test_pins_are_rescanned_rather_than_captured_once
    html = render_head

    # THE MUTATION THIS KILLS: registering pins once at init. The board's own
    # hand-rolled version documents this exact bug — a Turbo Stream swaps the
    # app strip, the observer keeps watching a detached node, and the live one
    # is never measured. Rebuilding from the document is what makes that
    # unreachable, so the rebuild has to be reachable from a stream render.
    assert_match(/addEventListener\(\s*['"]turbo:before-stream-render['"][\s\S]{0,160}?registerPins/, html,
                 "a Turbo Stream replaces nodes without a turbo:load; pins must re-register after one")
    reg = html[/function registerPins\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty reg, "could not isolate registerPins()"
    assert_match(/pins\s*=\s*\[\]/, reg,
                 "registerPins must REBUILD the list, not append to a stale one")
    assert_match(/if\s*\(!name\)\s*continue/, reg,
                 "an unnamed data-pin would publish `--pin--h`, a valid property and a silent nonsense one")
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
