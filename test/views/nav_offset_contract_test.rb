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

    # THE SOURCES, STILL INSEPARABLE FROM THEIR PROPERTIES — through one more
    # hop than before. The header is no longer measured by a publish() of its
    # own: it is a pin named "nav" that ALSO writes the legacy pair, from the
    # same reading, so it is never measured twice per frame. readPin() takes
    # both measurements; writeReading() writes them.
    read = html[/function readPin\(pin\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    write = html[/function writeReading\(r\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty read, "could not isolate readPin()"
    refute_empty write, "could not isolate writeReading()"

    h_field = read[/(\w+):\s*pin\.el\.offsetHeight/, 1]
    refute_nil h_field, "the height must still come from the header's offsetHeight"
    b_field = read[/(\w+):\s*Math\.max\(\s*0\s*,\s*pin\.el\.getBoundingClientRect\(\)\.bottom\s*\)/, 1]
    refute_nil b_field, "the bottom must still come from the CLAMPED rect bottom"
    refute_equal h_field, b_field, "the two measurements must not collapse into one field"

    # Shannon's swap mutation still dies: exchange the two sources and the
    # captured field names cross, so both of these fail.
    assert_match(/setProperty\(\s*'--nav-h'\s*,\s*r\.#{Regexp.escape(h_field)}\s*\+/, write,
                 "--nav-h must be written from the field read out of offsetHeight")
    assert_match(/setProperty\(\s*'--nav-bottom'\s*,\s*r\.#{Regexp.escape(b_field)}\s*\+/, write,
                 "--nav-bottom must be written from the field read out of the clamped rect bottom")
    refute_match(/setProperty\(\s*'--nav-h'\s*,[^;]*getBoundingClientRect/, html,
                 "feeding --nav-h from the rect breaks every consumer that sizes off it")
    refute_match(/setProperty\(\s*'--nav-bottom'\s*,[^;]*offsetHeight/, html,
                 "feeding --nav-bottom from the height IS the banner-overlap bug")

    # THE LEGACY PAIR RIDES THE PIN'S MEASUREMENT, which is what stops the
    # header being measured twice a frame for values proven identical.
    assert_match(/pin\.legacy/, write, "the legacy names must be written from the pin's own reading")
    refute_match(/function publish\(/, html,
                 "a second header-only publisher is the double measurement this replaced")
  end

  # THE ANTI-THRASH ORDER, now ACROSS the whole frame rather than inside one
  # function.
  #
  # THE MUTATION THIS KILLS, and it shipped once: keeping reads-before-writes
  # inside each function while the FRAME ran a writing pass and then a reading
  # one. Every per-function assertion stayed green, and a read after a write to
  # documentElement forces a fresh layout — measured by review at 6x CPU
  # throttle over 175 frames, 62 frames past 20ms against 42 with the second
  # pass off; at 10x, 84/180 against 4/180.
  def test_head_reads_every_measurement_before_writing_any
    html = render_head
    body = html[/function publishAll\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty body, "could not isolate publishAll()"

    last_read = body.index("readPin")
    first_write = body.index("writeReading")
    refute_nil last_read, "publishAll must collect readings"
    refute_nil first_write, "publishAll must write them"
    assert last_read < first_write,
           "every measurement must be taken before any write — a read after a write to " \
           "documentElement forces a fresh layout, and that regression shipped once"

    # And the two passes must be separate loops, not one interleaved pass.
    assert_match(/for\s*\([^)]*\)\s*readings\.push\(readPin[\s\S]{0,120}?for\s*\([^)]*\)\s*writeReading/, body,
                 "the read pass and the write pass must be distinct loops")
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
    assert_match(/requestAnimationFrame\(\s*function\s*\([^)]*\)\s*\{[^}]*publishAll\(/, html,
                 "the rAF callback must republish — a throttle that never publishes is not a throttle")

    # And the scroll handler must be the one that schedules that frame, rather than
    # some unrelated function that merely shares the name.
    scroll_handler = html[/addEventListener\(\s*'scroll'\s*,\s*(\w+)/, 1]
    refute_nil scroll_handler, "could not identify the scroll handler"
    assert_match(/function\s+#{Regexp.escape(scroll_handler)}\s*\([^)]*\)\s*\{[^}]*requestAnimationFrame/m, html,
                 "the function bound to scroll must be the one that schedules the republish")
  end

  def test_head_releases_everything_when_a_page_has_no_pinned_chrome
    html = render_head

    # The scroll listener outlives the visit, so a Turbo nav to a page with no
    # pinned chrome would otherwise keep publishing from DETACHED nodes — an
    # all-zero rect, which drives the properties to 0px. Nothing ran after
    # detach before this existed, so they simply kept their last value; keep
    # that promise. The guard moved from "no <header>" to "no pins at all",
    # because the header is a pin now and a page can carry pinned chrome
    # without one.
    body = html[/function attach\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty body, "could not isolate attach()"

    assert_match(/if\s*\(\s*!pins\.length\s*&&\s*ro\s*\)\s*\{[^}]*disconnect\(\)/, body,
                 "a page with no pinned chrome must release the observer, not keep it on detached nodes")
    assert_match(/ro\s*=\s*null/, body, "and must drop the reference, so the next attach builds a fresh one")
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
    pin = html[/function readPin\(pin\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty pin, "could not isolate readPin()"
    assert_match(/pin\.el\.offsetHeight/, pin, "pin height comes from offsetHeight")
    assert_match(/Math\.max\(\s*0\s*,\s*pin\.el\.getBoundingClientRect\(\)\.bottom\s*\)/, pin,
                 "pin bottom comes from the CLAMPED rect bottom, so a hidden layer measures 0")

    # No-op writes still skipped: these are INHERITED properties on
    # documentElement, so an unchanged write still invalidates the document.
    write = html[/function writeReading\(r\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    assert_match(/if\s*\(\s*r\.h\s*!==\s*pin\.lastH\s*\)/, write, "an unchanged height must skip its write")
    assert_match(/if\s*\(\s*r\.bottom\s*!==\s*pin\.lastBottom\s*\)/, write, "an unchanged bottom must skip its write")
  end

  def test_pins_share_one_observer_and_one_frame
    html = render_head

    # N pinned layers must not mean N observers or N frames. schedule() already
    # coalesces; the pins ride it.
    assert_equal 1, html.scan(/new ResizeObserver\(/).length,
                 "every pinned layer shares the one observer"
    sched = html[/function schedule\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    assert_match(/publishAll\(/, sched, "pins must publish inside the coalesced frame, not on their own")
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

  # F1 — A REMOVED LAYER MUST CLEAR ITS PROPERTIES.
  #
  # A layer goes away three ways. display:none and x-show both KEEP the node, so
  # it measures 0 and drops out of a consumer's max() on its own. REMOVAL does
  # not: nothing is left to measure, the last published value stands forever,
  # and the consumer sits at the height of a strip that is gone. Review measured
  # a removed 300px strip holding --pin-apps-bottom at 300px against a real
  # stack bottom of 160px — a permanent 140px error, and a direct contradiction
  # of this primitive's headline promise.
  def test_a_departed_pin_has_its_properties_removed
    html = render_head
    reg = html[/function registerPins\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty reg, "could not isolate registerPins()"

    assert_match(/removeProperty\(\s*'--pin-'\s*\+\s*\w+\s*\+\s*'-h'\s*\)/, reg,
                 "a departed pin's height must be REMOVED, not left at its last value")
    assert_match(/removeProperty\(\s*'--pin-'\s*\+\s*\w+\s*\+\s*'-bottom'\s*\)/, reg,
                 "a departed pin's bottom must be REMOVED — it is what a consumer's max() reads")

    # The removal has to be driven by what is NO LONGER in the document, which
    # means remembering what was published. A rebuild that only adds is what
    # let the stale value survive.
    assert_match(/published/, reg, "registerPins must track what it has published to know what left")
    assert_match(/!\s*seen\[/, reg, "clearing must key off absence from THIS scan, not a guess")
  end

  # THE COVERAGE GAP REVIEW FOUND, closed. Stripping data-pin="nav" off the
  # engine navbar passed the ENTIRE unit suite — every assertion here is about
  # the publisher, and none of them said the header actually opts in. The e2e
  # lane caught it; a unit tier that cannot is a unit tier with a hole.
  def test_the_engine_navbar_opts_into_the_pinned_stack
    navbar = File.read(File.expand_path("../../app/views/layouts/_navbar.html.erb", __dir__))

    assert_match(/<header[^>]*\sdata-pin="nav"/, navbar,
                 "the engine navbar must carry data-pin=\"nav\", or no consumer gets --pin-nav-* for free")
  end

  # THE HOST-OWNED HEADER — the back-compat promise, asserted where it actually
  # breaks.
  #
  # THIS IS THE HOLE THAT SHIPPED. The registry is built from [data-pin], and
  # --nav-h / --nav-bottom are written from the legacy pin's reading — so a
  # header that does not carry the attribute publishes NEITHER. Every test in
  # this file passed anyway, because the ENGINE's own navbar carries data-pin;
  # the broken path exists only in a consumer that owns its header, which is
  # both live consumers (turf-monster layouts/_navbar, mcritchie-studio
  # layouts/application). Review measured --nav-h unset, the gear drawer 82px
  # out of place and the contest board 114px, on apps that would have taken it
  # on their next bundle update with no floor bump.
  def test_a_header_without_data_pin_still_publishes_the_legacy_properties
    html = render_head
    reg = html[/function registerPins\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty reg, "could not isolate registerPins()"

    # It must NOTICE that the header was absent from the scan...
    assert_match(/headerPinned/, reg,
                 "registerPins must track whether the header was among the data-pin nodes")
    # ...and adopt it anyway, as the legacy pin.
    assert_match(/if\s*\(\s*header\s*&&\s*!headerPinned\s*\)\s*\{[\s\S]{0,400}?legacy:\s*true/, reg,
                 "a header that does not carry data-pin must still be adopted, or --nav-h never publishes")
    assert_match(/if\s*\(\s*header\s*&&\s*!headerPinned\s*\)\s*\{[\s\S]{0,400}?observe\(\s*header\s*\)/, reg,
                 "and must be observed, or it publishes once and never tracks the collapse")
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
