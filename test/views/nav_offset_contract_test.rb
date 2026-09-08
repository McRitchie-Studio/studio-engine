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

    # THE SOURCES, STILL INSEPARABLE FROM THEIR PROPERTIES. The header is a pin
    # named "nav" that ALSO writes the legacy pair, from the same reading, so it
    # is never measured twice per frame. measure() takes both measurements;
    # write() writes them.
    read = html[/function measure\(el, name, legacy\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    write = html[/function write\(pins, stack\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty read, "could not isolate measure()"
    refute_empty write, "could not isolate write()"

    h_field = read[/(\w+):\s*el\.offsetHeight/, 1]
    refute_nil h_field, "the height must still come from the header's offsetHeight"
    b_field = read[/(\w+):\s*Math\.max\(\s*0\s*,\s*r\.bottom\s*\)/, 1]
    refute_nil b_field, "the bottom must still come from the CLAMPED rect bottom"
    refute_equal h_field, b_field, "the two measurements must not collapse into one field"
    assert_match(/var r = el\.getBoundingClientRect\(\)/, read,
                 "the clamped bottom must come from the element's own rect")

    # Shannon's swap mutation still dies: exchange the two sources and the
    # captured field names cross, so both of these fail.
    assert_match(/setProperty\(\s*'--nav-h'\s*,\s*p\.#{Regexp.escape(h_field)}\s*\+/, write,
                 "--nav-h must be written from the field read out of offsetHeight")
    assert_match(/setProperty\(\s*'--nav-bottom'\s*,\s*p\.#{Regexp.escape(b_field)}\s*\+/, write,
                 "--nav-bottom must be written from the field read out of the clamped rect bottom")
    refute_match(/setProperty\(\s*'--nav-h'\s*,[^;]*getBoundingClientRect/, html,
                 "feeding --nav-h from the rect breaks every consumer that sizes off it")
    refute_match(/setProperty\(\s*'--nav-bottom'\s*,[^;]*offsetHeight/, html,
                 "feeding --nav-bottom from the height IS the banner-overlap bug")

    # THE LEGACY PAIR RIDES THE PIN'S MEASUREMENT, which is what stops the
    # header being measured twice a frame for values proven identical.
    assert_match(/p\.legacy/, write, "the legacy names must be written from the pin's own reading")
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

    last_read = body.index("readPins")
    first_write = body.index("write(")
    refute_nil last_read, "publishAll must collect readings"
    refute_nil first_write, "publishAll must write them"
    assert last_read < first_write,
           "every measurement must be taken before any write — a read after a write to " \
           "documentElement forces a fresh layout, and that regression shipped once"

    # AND NOTHING MAY MEASURE AFTER THE WRITE PASS. composed() is pure arithmetic
    # over readings already taken, and syncObserver() only moves the observer —
    # neither may reach for the layout again. This is the mutation the ordering
    # assertion above cannot see: a getBoundingClientRect anywhere downstream of
    # write() re-forces the layout the ordering exists to avoid.
    tail = body[first_write..].to_s
    refute_match(/getBoundingClientRect|offsetHeight|getComputedStyle/, tail,
                 "nothing may measure the layout after the write pass has begun")
    comp = html[/function composed\(pins\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty comp, "could not isolate composed()"
    refute_match(/getBoundingClientRect|offsetHeight|getComputedStyle/, comp,
                 "composing the stack must be arithmetic over readings already taken")
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
    # all-zero rect, which drives the properties to 0px. The guard lives with the
    # observer now, because the observer is the only thing left that holds a node.
    body = html[/function syncObserver\(pins\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty body, "could not isolate syncObserver()"

    assert_match(/if\s*\(\s*!pins\.length\s*\)\s*\{[\s\S]{0,200}?disconnect\(\)/, body,
                 "a page with no pinned chrome must release the observer, not keep it on detached nodes")
    assert_match(/ro\s*=\s*null/, body, "and must drop the reference, so the next publish builds a fresh one")

    # A DEPARTED NODE MUST BE UNOBSERVED, not merely dropped from the readings.
    # A replaced node left under observation keeps waking the publisher from
    # outside the document for the life of the page.
    assert_match(/unobserve\(/, body,
                 "a node that is no longer pinned must be unobserved, or it wakes the publisher forever")
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
    # out of the stack — that is what removes the need for a declared stacking
    # order, and an unclamped rect bottom could go negative and win.
    pin = html[/function measure\(el, name, legacy\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty pin, "could not isolate measure()"
    assert_match(/el\.offsetHeight/, pin, "pin height comes from offsetHeight")
    assert_match(/Math\.max\(\s*0\s*,\s*r\.bottom\s*\)/, pin,
                 "pin bottom comes from the CLAMPED rect bottom, so a hidden layer measures 0")

    # No-op writes still skipped: these are INHERITED properties on
    # documentElement, so an unchanged write still invalidates the document, and
    # a scroll frame reaches this four times per layer.
    write = html[/function write\(pins, stack\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    assert_match(/if\s*\(force \|\| p\.h !== prev\.h\)/, write,
                 "an unchanged height must skip its write unless a structural change forced it")
    assert_match(/if\s*\(force \|\| p\.bottom !== prev\.bottom\)/, write,
                 "an unchanged bottom must skip its write unless a structural change forced it")
    assert_match(/if\s*\(force \|\| p\.top !== prev\.top\)/, write,
                 "an unchanged top must skip its write unless a structural change forced it")
    assert_match(/if\s*\(force \|\| stack !== lastStack\)/, write,
                 "an unchanged stack bottom must skip its write — it is read by every consumer")
    sched = html[/function schedule\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    assert_match(/publishAll\(/, sched, "pins must publish inside the coalesced frame, not on their own")
  end

  def test_pins_are_rescanned_rather_than_captured_once
    html = render_head

    # THE MUTATION THIS KILLS: holding pinned nodes by reference between scans.
    # A Turbo Stream swaps the app strip, the held reference points at the
    # DETACHED predecessor, and a detached node's rect is all zeros — which is
    # indistinguishable from a layer that is legitimately hidden. Measured on
    # mcritchie-studio's /deployments: --pin-apps-bottom published 0px while the
    # live strip stood at display:block, bottom 152px.
    #
    # The registry is DERIVED PER PUBLISH now, which is stronger than
    # re-registering on an event: there is no window between a DOM patch and a
    # re-scan in which anything can be pointed at the wrong node.
    reads = html[/function readPins\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty reads, "could not isolate readPins()"
    assert_match(/querySelectorAll\(\s*['"]\[data-pin\]['"]\s*\)/, reads,
                 "readPins must rebuild from the DOCUMENT on every publish")
    assert_match(/if\s*\(!name\)\s*continue/, reads,
                 "an unnamed data-pin would publish `--pin--h`, a valid property and a silent nonsense one")

    # THE ASSERTION HAS TO BE THAT IT IS UNCONDITIONAL. "readPins() appears in
    # publishAll" is satisfied by `pins = cache || (cache = readPins())`, which
    # is the cached registry wearing the call as a disguise — that mutation
    # survived a first version of this line. Pin the whole statement.
    pub = html[/function publishAll\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    assert_match(/^\s*var pins = readPins\(\);$/, pub,
                 "every publish must re-derive the registry OUTRIGHT, never behind a cache or a guard")
    refute_match(/\|\||&&|\?/, pub,
                 "a conditional in publishAll is a cache or a bail-out; the registry must be rebuilt every time")

    # AND THE HELD-NODE FIELD IS GONE. A module-level `pins` array outliving a
    # publish is the exact shape of the bug; if one comes back, this goes red.
    body = html[/\(function \(\) \{\s*if \(!window\.ResizeObserver\)([\s\S]*?)\n  \}\)\(\);/, 1].to_s
    refute_empty body, "could not isolate the publisher"
    refute_match(/^\s*var pins = \[\];/, body,
                 "a module-level pins array is a cached registry — the defect this replaced")

    # A stream render must still re-publish: the observer has to be moved onto
    # the incoming node and the stack recomposed for a layer that arrived or left.
    # It republishes through invalidate(), which forces the write —
    # test_a_structural_change_republishes_even_unchanged_values pins that
    # invalidate() is publishAll plus the force, so this stays a wiring check.
    assert_match(/addEventListener\(\s*['"]turbo:before-stream-render['"][\s\S]{0,200}?invalidate/, html,
                 "a Turbo Stream replaces nodes without a turbo:load; the stack must republish after one")
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
    w = html[/function write\(pins, stack\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty w, "could not isolate write()"

    assert_match(/removeProperty\(\s*'--pin-'\s*\+\s*\w+\s*\+\s*'-h'\s*\)/, w,
                 "a departed pin's height must be REMOVED, not left at its last value")
    assert_match(/removeProperty\(\s*'--pin-'\s*\+\s*\w+\s*\+\s*'-bottom'\s*\)/, w,
                 "a departed pin's bottom must be REMOVED — a consumer may still name it directly")
    assert_match(/removeProperty\(\s*'--pin-'\s*\+\s*\w+\s*\+\s*'-top'\s*\)/, w,
                 "a departed pin's top must be REMOVED, on the same rule as the other two")

    # The removal has to be driven by what is NO LONGER in the document, which
    # means remembering what was published. A rebuild that only adds is what
    # let the stale value survive.
    assert_match(/last\[/, w, "write must track what it has published to know what left")
    assert_match(/!\s*seen\[/, w, "clearing must key off absence from THIS scan, not a guess")
    assert_match(/delete last\[/, w,
                 "and must forget it, or the name is re-cleared forever and can never come back clean")
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
    reads = html[/function readPins\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty reads, "could not isolate readPins()"

    # It must NOTICE that the header was absent from the scan...
    assert_match(/headerPinned/, reads,
                 "readPins must track whether the header was among the data-pin nodes")
    # ...and adopt it anyway, as the legacy pin.
    assert_match(/if\s*\(header\s*&&\s*!headerPinned\)[\s\S]{0,200}?measure\(header,\s*'nav',\s*true\)/, reads,
                 "a header that does not carry data-pin must still be adopted, or --nav-h never publishes")

    # AND IT MUST BE OBSERVED. The observer is synced from the SAME list this
    # returns, so an adopted header is observed by construction rather than by a
    # second branch that could be forgotten — assert that binding, not a call.
    pub = html[/function publishAll\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    assert_match(/syncObserver\(pins\)/, pub,
                 "the observer must be synced from the derived registry, so an adopted header tracks the collapse")
  end

  # ==================== THE SAME-FRAME PROPERTY ====================
  #
  # THE DEFECT THIS PINS, measured on production /deployments 2026-09-07.
  #
  # A frame runs: rAF callbacks -> style/layout -> ResizeObserver callbacks ->
  # paint. The publisher used to be WOKEN by the observer and then DEFER its
  # write to requestAnimationFrame, which lands at the top of the NEXT frame. So
  # the frame in which a layer actually appeared or disappeared painted with the
  # previous frame's number — every time, not occasionally.
  #
  # A/B measured in isolation, toggling a pinned layer's display and sampling
  # what the changing frame paints: rAF-deferred wrong on 8/8 changing frames,
  # RO-synchronous wrong on 0/8. On the live board that showed up as the lane
  # headers slamming 99px and back on a page nobody was touching.
  #
  # This is the assertion the old suite could not make, because the old suite
  # asserted that pins published "inside the coalesced frame" — which is exactly
  # the defect, stated as a requirement.
  def test_a_size_change_publishes_synchronously_rather_than_a_frame_late
    html = render_head
    body = html[/function onResize\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty body, "could not isolate onResize()"

    assert_match(/publishAll\(\)/, body,
                 "the observer callback must publish, so the write lands in the frame that caused it")

    # THE MUTATION THIS KILLS: reintroducing the deferral, in ANY spelling.
    #
    # Matching "requestAnimationFrame(...publishAll" is not enough — a mutation
    # writing `rAF(function () { publishAll(); })` slips a `)` past any such
    # regex, and it did: the deferral survived a first version of this assertion.
    # So instead the ONE legitimate frame callback in this function — the
    # re-entrancy depth reset, which schedules no publish — is removed by name,
    # and NOTHING may defer after that. Every spelling of the defect is caught,
    # including ones nobody thought of.
    residue = body.sub(/window\.requestAnimationFrame\(function \(\) \{ resetQueued = false; depth = 0; \}\);/, "")
    refute_equal body, residue, "the depth-reset frame callback moved; re-anchor this assertion"
    refute_match(/requestAnimationFrame/, residue,
                 "deferring the publish to rAF paints the changing frame with the previous frame's number")
    assert body.strip.end_with?("publishAll();"),
           "the callback must END by publishing outright, not hand it to another clock"

    # And the observer must be built on this callback, not on the scheduler.
    assert_match(/new ResizeObserver\(\s*onResize\s*\)/, html,
                 "the ResizeObserver must publish through onResize, not through the scroll scheduler")
  end

  # SCROLL IS THE OTHER CLOCK, and it must stay on rAF. A scroll moves a sticky
  # header's bottom EDGE without changing its SIZE, so the observer never fires
  # and there is nothing to be synchronous with. rAF is correct there, and it
  # coalesces the burst iOS momentum fires far above 60Hz.
  def test_scroll_still_publishes_through_a_coalesced_frame
    html = render_head
    sched = html[/function schedule\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty sched, "could not isolate schedule()"

    assert_match(/requestAnimationFrame/, sched, "the scroll path must coalesce into one write per frame")
    assert_match(/publishAll\(/, sched, "and must publish the whole stack, not just the header")
    assert_match(/addEventListener\(\s*'scroll'\s*,\s*schedule\s*,\s*\{\s*passive:\s*true\s*\}/, html,
                 "the scroll listener must be passive and must go through the scheduler")
  end

  # SKIPPING AN UNCHANGED WRITE IS ONLY SAFE ON A SCROLL FRAME.
  #
  # THE DEFECT THIS PINS, caught by the e2e lane while this was being built. The
  # legacy --nav-h / --nav-bottom pair is written from the nav pin's reading, so
  # gating it on the PIN's change-check couples two different facts: strip
  # data-pin off the header and the pair is still "unchanged", so it is skipped —
  # and any consumer that had cleared it never gets it back. Measured in the lab:
  # --nav-h stayed "" through a full re-scan, on the exact host-owned-header path
  # both live consumers use.
  #
  # The rule that fixes it is the general one. A SCROLL frame may skip an
  # unchanged write, and that is most of why this publisher is cheap. A
  # STRUCTURAL change may not: a layer arriving or leaving, a Turbo patch, a
  # fresh document — any of those may have cleared a property out from under the
  # cache, so one full write is owed.
  def test_a_structural_change_republishes_even_unchanged_values
    html = render_head
    body = html[/\(function \(\) \{\s*if \(!window\.ResizeObserver\)([\s\S]*?)\n  \}\)\(\);/, 1].to_s
    refute_empty body, "could not isolate the publisher"

    # It must START dirty: the first publish of a document has nothing cached and
    # must write everything.
    assert_match(/var forceWrite = true;/, body,
                 "the first publish must write every property — nothing is cached yet")

    # Every structural entry point must invalidate, not merely publish.
    assert_match(/function invalidate\(\)\s*\{\s*forceWrite = true;\s*publishAll\(\);\s*\}/, body,
                 "invalidate() must force the write, not just re-publish through the cache")
    %w[DOMContentLoaded turbo:load turbo:before-stream-render].each do |evt|
      assert_match(/addEventListener\(\s*'#{Regexp.escape(evt)}'[\s\S]{0,120}?invalidate/, body,
                   "#{evt} is a structural change and must force a full write")
    end

    # A ROSTER CHANGE counts too, and it is not always announced by an event —
    # an x-show that adds a node fires no stream render.
    w = html[/function write\(pins, stack\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    assert_match(/if\s*\(!last\.hasOwnProperty\(pins\[i\]\.name\)\)\s*\{\s*force = true/, w,
                 "a layer that was not in the last publish must force a full write")

    # And the flag must be CONSUMED, or every write after the first structural
    # change is unconditional and the skip stops being a skip at all.
    assert_match(/var force = forceWrite;\s*\n\s*forceWrite = false;/, w,
                 "the force flag must be consumed by the publish that honours it")

    # THE SCROLL PATH MUST NOT FORCE. If it did, every scroll frame would write
    # four properties per layer on documentElement, which is the style
    # invalidation the skip exists to avoid.
    sched = html[/function schedule\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_match(/forceWrite/, sched, "a scroll frame must still skip unchanged writes")
    ro = html[/function onResize\(\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_match(/forceWrite/, ro, "a plain resize must still skip unchanged writes")
  end

  # ==================== THE COMPOSED STACK ====================
  #
  # WHY THE CONSUMER MUST NOT COMPOSE. `top: max(var(--pin-nav-bottom),
  # var(--pin-apps-bottom))` — mcritchie-studio's deploy board, until this
  # landed — fails twice. It does not SCALE: a fourth pinned layer means editing
  # every consumer that ever wanted to sit under the stack. And it is not SOUND:
  # a max() over two custom properties is only meaningful if they were written in
  # the same frame, so any skew between publishers is expressed instantly as
  # layout. One composed value cannot disagree with itself.
  def test_the_publisher_composes_the_stack_so_consumers_do_not
    html = render_head

    assert_match(/setProperty\(\s*'--pin-stack-bottom'/, html,
                 "the publisher must publish the stack's own bottom edge as one value")

    comp = html[/function composed\(pins\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty comp, "could not isolate composed()"

    # THE STACK BOTTOM IS THE LOWEST EDGE of any layer — a max, not a sum. Layers
    # overlap (a fixed strip sits AT the header's bottom, not below its own
    # height), so summing heights would push a consumer down by the whole stack
    # twice over.
    assert_match(/if\s*\(pins\[i\]\.bottom\s*>\s*stack\)\s*stack\s*=\s*pins\[i\]\.bottom/, comp,
                 "the stack bottom is the LOWEST layer edge, not the sum of the heights")

    # A LAYER THAT IS ITSELF IN THE STACK gets its own reference point: the
    # bottom of everything ABOVE it. --pin-stack-bottom includes that layer's own
    # edge, so a layer positioned off it would chase itself down the page.
    assert_match(/setProperty\(\s*'--pin-'\s*\+\s*\w+\.name\s*\+\s*'-top'/, html,
                 "each layer publishes the edge of everything above it, so it can position without circularity")
    assert_match(/if\s*\(i\s*===\s*j\)\s*continue/, comp,
                 "a layer must not stack on itself — that is the circularity --pin-<name>-top exists to avoid")
  end

  # ORDER IS DOCUMENT ORDER, with an escape hatch. Layers are declared in the
  # order they read down the page, so querySelectorAll already returns them
  # correctly; data-pin-order exists for the layer whose DOM position does not
  # match where it sits on screen, and needs to exist on only that layer.
  def test_stacking_order_defaults_to_document_order
    html = render_head
    comp = html[/function composed\(pins\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty comp, "could not isolate composed()"

    assert_match(/j\s*<\s*i/, comp,
                 "with no explicit order, a layer earlier in the document is above a later one")
    assert_match(/oj\s*<\s*oi/, comp,
                 "two explicitly ordered layers must compare their numbers, lower being higher up")

    ord = html[/function order\(p\)\s*\{([\s\S]*?)\n    \}/, 1].to_s
    refute_empty ord, "could not isolate order()"
    assert_match(/getAttribute\(\s*'data-pin-order'\s*\)/, ord, "the override is read off the element")
    assert_match(/isNaN\(raw\)\s*\?\s*null/, ord,
                 "an absent or unparseable order must fall back to document order, never to 0 — " \
                 "0 would silently promote the layer above every ordered one")
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
