# frozen_string_literal: true

require "test_helper"
require "action_view"

# The nav-COLLAPSE contract. Sibling to nav_offset_contract_test, and for the
# same reason: layouts/studio/_head is where the engine publishes the sticky
# header's live geometry, and a third property now joins the two there.
#
#   --nav-h      the header's HEIGHT
#   --nav-bottom the header's BOTTOM EDGE, in viewport coordinates
#   --nav-p      how far through its COLLAPSE the header is, 0..1
#
# The first two are measurements OF the header. --nav-p is an input TO it: the
# head writes it from window.scrollY and the navbar's own stylesheet derives
# every collapsing dimension from it with calc().
#
# Why it exists. The collapse used to be a 60px THRESHOLD fed into
# `transition-all duration-300` on padding, logo width/height and two font
# sizes. The finger set the step; an ease curve owned everything after it.
# Measured in turf-monster at 390x844 (task smooth-mobile-navbar-collapse,
# 2026-08-27): the header ran 178px -> 139px and 34 of those 39px of document
# reflow landed AFTER the scroll had stopped, over 232ms, at up to 3px per
# frame -- plus a 1px REVERSE lurch in the frame the class flipped. Progress is
# a pure function of scrollY now, so the navbar cannot move in a frame the
# finger did not.
#
# What this tier cannot do: run the JS, or lay out a page. It holds the WIRING,
# and the wiring being right does not mean the motion is — every assertion here
# passes over a build that ALSO carries `transition-all duration-300` alongside.
# The motion itself is pinned one lane over, in e2e/nav_collapse.spec.js, which
# scrolls the real navbar on /lab/bar_stack and fails if the header moves after
# the scroll stops. (Its sibling nav_offset_contract_test says the engine has no
# browser lane; that was true when it was written and is not now.)
class NavCollapseContractTest < Minitest::Test
  # ASSERT THE WIRING, NOT THE VOCABULARY — the lesson nav_offset_contract_test
  # was blocked for. Every regex below spans a property AND the expression
  # feeding it, and each names the mutation it exists to kill.

  def test_head_registers_nav_p_as_a_typed_number
    html = render_head

    # Registration is not decoration. Untyped, `calc(3rem - 1rem * var(--nav-p))`
    # is invalid at computed-value time on a page that never scrolled, and every
    # collapsing dimension drops to its unstyled default. The type is what makes
    # the arithmetic legal and the initial value real.
    assert_match(/@property\s+--nav-p\s*\{[^}]*syntax:\s*["']<number>["']/m, html,
                 "--nav-p must be registered as a <number>, or the calc()s are invalid before the first scroll")
    assert_match(/@property\s+--nav-p\s*\{[^}]*inherits:\s*true/m, html,
                 "--nav-p must inherit, or only the header itself can read it")
    assert_match(/@property\s+--nav-p\s*\{[^}]*initial-value:\s*0\b/m, html,
                 "an unscrolled page must start EXPANDED; a non-zero initial paints the collapsed navbar on load")
  end

  def test_nav_p_is_written_from_scroll_position_onto_the_header
    html = render_head

    # Fed by scrollY, clamped at 0. Rubber-band overscroll reports negative, and
    # a negative progress inflates the navbar past its expanded size.
    assert_match(/Math\.max\(\s*0\s*,\s*window\.scrollY\s*\)/, html,
                 "progress must be read from a scrollY clamped at 0 — overscroll reports negative")

    # THE MUTATION THIS KILLS: `document.documentElement.style.setProperty('--nav-p', ...)`.
    # Every pixel still lands in the right place, every string above survives, and
    # the cost changes completely — writing an inherited custom property on :root
    # dirties style for the whole document once per scroll frame instead of for
    # the navbar subtree. It is also load-bearing for the /navbar preview page,
    # whose preview headers must NOT inherit the live page's scroll progress.
    assert_match(/\bel\.style\.setProperty\(\s*["']--nav-p["']/, html,
                 "--nav-p must be written on the HEADER element the component owns")
    refute_match(/document\.documentElement\.style\.setProperty\(\s*["']--nav-p["']/, html,
                 "writing --nav-p on :root dirties the whole document every scroll frame and leaks into preview headers")
  end

  def test_the_ramp_is_smoothstepped_and_fed_by_the_ramp_width
    html = render_head

    # Both a linear ramp and a smoothstep are pure functions of scroll position,
    # so both stop dead with the finger. The difference is the SHAPE. Collapsing
    # a sticky, in-flow header pulls the page up, so content moves by the scroll
    # AND by the shrink; a linear ramp equal to the collapse steps content speed
    # to ~2x the moment it starts and back to 1x the moment it ends. Smoothstep's
    # slope is zero at both ends, so the burst fades in and out: 1x -> ~1.5x -> 1x.
    #
    # THE MUTATION THIS KILLS: keeping `t * t * (3 - 2 * t)` but feeding `t` from
    # something other than the ramp — a constant, or scrollY unnormalised — which
    # keeps the token and destroys the curve. So the two lines are asserted as a
    # pair, in order.
    assert_match(/\bt\s*=\s*Math\.min\(\s*1\s*,\s*y\s*\/\s*ramp\s*\)/, html,
                 "the smoothstep input must be scroll position normalised by --nav-ramp")
    assert_match(/t\s*\*\s*t\s*\*\s*\(\s*3\s*-\s*2\s*\*\s*t\s*\)/, html,
                 "the ramp must be smoothstepped — a linear ramp steps content speed to 2x and back")

    # And the ramp width comes from CSS, so each breakpoint band can size its own
    # (it is 3x that band's collapse total, which is what puts the peak at ~1.5x).
    assert_match(/getPropertyValue\(\s*["']--nav-ramp["']\s*\)/, html,
                 "--nav-ramp must be read from CSS so each band can size its own ramp")
  end

  def test_the_short_page_guard_does_not_chase_itself
    html = render_head

    # Collapsing shortens the document by the collapse total. On a page with
    # barely more than that to scroll, the collapse deletes the very scroll room
    # that triggered it, the browser clamps scrollY to 0, and the navbar flaps
    # open and shut forever.
    #
    # THE MUTATION THIS KILLS: measuring room as a plain
    # `scrollHeight - innerHeight`. That reads the document as it is RIGHT NOW,
    # mid-collapse, so the measurement shrinks as the thing it is measuring
    # shrinks and the guard releases halfway. The add-back is the whole trick.
    guard = html[/roomExpanded\s*=([\s\S]{0,200}?);/, 1].to_s
    refute_empty guard, "could not find the short-page guard's room measurement"

    assert_match(/scrollHeight/, guard, "room must start from the document height")
    assert_match(/innerHeight/, guard, "minus the viewport")
    assert_match(/\+\s*ramp\s*\*\s*\w+\.p\b/, guard,
                 "room must add back the shrink ALREADY applied, or the measurement chases itself as it collapses")

    # And the guard has to actually refuse, not merely compute.
    assert_match(/roomExpanded\s*<[\s\S]{0,120}?\btarget\s*=\s*0/, html,
                 "under the threshold the guard must pin progress at 0")
  end

  def test_reduced_motion_snaps_instead_of_interpolating
    html = render_head

    # Scroll-linked motion has no clock left to slow down, so there is a real
    # argument that reduced motion needs nothing here. It does: resizing type
    # under a moving finger is itself the motion some readers are asking us to
    # drop. Under the query, progress snaps on the old hysteresis.
    assert_match(/matchMedia\(\s*["']\(prefers-reduced-motion: reduce\)["']\s*\)/, html,
                 "the component must consult prefers-reduced-motion")

    branch = html[/_reduce\.matches\s*\)\s*\{([\s\S]{0,240}?)\}/, 1].to_s
    refute_empty branch, "could not find the reduced-motion branch"
    assert_match(/\btarget\s*=\s*\([\s\S]*?\)\s*\?\s*1\s*:\s*0/, branch,
                 "reduced motion must snap progress to 0 or 1, never interpolate")
  end

  def test_the_scroll_listener_is_passive_and_coalesced_into_one_frame
    html = render_head

    # iOS momentum scrolling fires well above 60Hz. One write per frame, and a
    # listener that never blocks the compositor.
    assert_match(/addEventListener\(\s*["']scroll["']\s*,\s*this\._onScroll\s*,\s*\{\s*passive:\s*true\s*\}/, html,
                 "the scroll listener must be passive")

    # THE MUTATION THIS KILLS, lifted straight from the sibling file: keeping the
    # requestAnimationFrame and dropping the call inside it. The frame is
    # scheduled, nothing is published, and scroll tracking is dead with every
    # token intact.
    assert_match(/requestAnimationFrame\(\s*apply\s*\)/, html,
                 "the scheduled frame must call apply — a throttle that never applies is not a throttle")

    # A Turbo visit tears the header down and builds a new one; without an
    # explicit removal every visit stacks another listener on window.
    assert_match(/destroy(?:\(\)|:\s*function\s*\(\))\s*\{[\s\S]{0,400}?removeEventListener\(\s*["']scroll["']/, html,
                 "destroy() must unbind the scroll listener, or Turbo visits stack them")
  end

  def test_the_navbar_derives_every_collapsing_dimension_from_nav_p
    nav = navbar_source

    assert_includes nav, 'x-data="navCollapse()"',
                    "the header must own the scroll-linked collapse component"
    # ANCHORED ON THE ATTRIBUTE, not the bare name. `navbar_source` is File.read of
    # raw ERB, so the file's OWN COMMENTS count as source: with a bare
    # `assert_includes nav, "nav-shell"`, deleting nav-shell from the header's class
    # left this green, satisfied by the comment above the header that explains what
    # nav-shell is. Same for nav-row (satisfied by the comment AND by the surviving
    # `.nav-row {` rule text) and for transition-shadow. Three assertions, none of
    # them biting, all found by mutation in review.
    assert_match(/<header\b[\s\S]{0,600}?class="nav-shell/, navbar_markup,
                 "the header element does not CARRY nav-shell, so it is not the --nav-p scope " \
                 "root and every calc() below it resolves against nothing")
    assert_match(/<div class="nav-row /, navbar_markup,
                 "the collapsing row does not carry nav-row, so its padding never interpolates")

    # The step and the clock, both gone. transition-shadow may stay: box-shadow
    # paints, it never reflows, so it cannot move content under the reader.
    refute_match(/@scroll\.window/, nav,
                 "the per-event threshold handler is replaced by navCollapse's coalesced listener")
    refute_match(/scrolled \? 'py-2' : 'py-6'/, nav,
                 "row padding must interpolate off --nav-p, not swap on a boolean")
    refute_match(/transition-all duration-300/, nav,
                 "no collapsing dimension may sit on a clock")
    assert_match(/class="nav-shell[\s\S]{0,400}?transition-shadow/, navbar_markup,
                 "the shadow may still fade on a clock — it paints and never reflows — but it " \
                 "has to be ON THE HEADER to do so; the bare-name version of this assertion was " \
                 "satisfied by the comment that explains it")

    # Each band is the two ENDPOINTS of its collapse, expressed once.
    css = engine_css
    %w[--nav-pad --nav-logo-size --nav-title-size --nav-title-lead-size --nav-title-lead].each do |hook|
      assert_match(/#{Regexp.escape(hook)}:\s*(calc\([^;]*var\(--nav-p[,)]|var\(--nav-title-size\)|[\d.]+;)/, css,
                   "#{hook} must derive from --nav-p, in engine.css where every consumer gets it")
    end

    # THE MOVE ITSELF, pinned. Putting the table back inline would satisfy every
    # assertion above if they still read the partial — and would silently strip
    # the defaults from the three apps that fork the navbar.
    refute_match(/--nav-ramp:\s*\d+px/, nav,
                 "the band table must not return to the navbar partial — a forking app never sees it there")

    # LAYERED, so a consumer can still beat it. Unlayered CSS outranks every
    # layered rule regardless of specificity, which would make the engine's
    # defaults unoverridable by the apps they exist to serve.
    assert_match(/@layer utilities \{[\s\S]*?\.nav-shell \{/, css,
                 "the defaults must ship inside @layer utilities or a consumer cannot override them")

    # EVERY var(--nav-p) CARRIES A FALLBACK. navCollapse writes the property only when
    # progress CHANGES, so on an unscrolled page it is never written and @property's
    # `initial: 0` is doing all of the work on first paint. In a browser that ignores
    # @property, an unregistered custom property is the guaranteed-invalid token, every
    # calc() here goes invalid-at-computed-value-time, and the measured result is
    # padding-block 0 with the logo at its intrinsic size. `var(--nav-p, 0)` degrades to
    # the pre-collapse navbar instead. Inert where @property works, so it costs nothing —
    # which is exactly why it must not be quietly dropped.
    bare = engine_css.scan(/var\(--nav-p\)/)

    assert_empty bare,
                 "#{bare.length} var(--nav-p) site(s) carry no fallback; write var(--nav-p, 0) so a " \
                 "browser without @property renders an expanded navbar rather than a broken one"
    assert_operator css.scan(/var\(--nav-p,\s*0\)/).length, :>=, 5,
                    "the band table lost its --nav-p sites entirely"
    assert_match(/--nav-ramp:\s*\d+px/, css, "each band must declare its own ramp width")
    assert_match(/--nav-max-step:\s*\d+px/, css, "the per-frame cap ships beside the ramp it derives from")

    refute_match(/\.is-scrolled\s+\.nav-(title|logo)/, nav,
                 "the .is-scrolled size overrides are replaced by --nav-p interpolation")
    # Anchored on a DURATION so the band table's own comment, which names the
    # declaration it replaced, does not trip its own guard.
    refute_match(/transition:\s*font-size\s+[\d.]+s/, nav,
                 "font-size transitions produced the 1px reverse twitch at the threshold")
  end

  # === THE RATE LIMIT ===================================================
  #
  # Position-linked progress fixed motion that OUTLIVED the gesture. It also
  # guaranteed the opposite defect: scrollY can move 90px between two frames,
  # and so then does the header's whole range. Measured in turf-monster at
  # 390x844 before this clamp — 8px/frame walked 3.9px of header per frame, a
  # momentum flick walked 39.0px, which is the ENTIRE collapse in one frame. It
  # was found on a phone: slow scrolling read as smooth, a flick jumped.

  def test_the_collapse_clamps_how_far_it_travels_in_one_frame
    html = render_head

    assert_match(/--nav-max-step:\s*\d+px/, engine_css,
                 "the per-frame cap must be a CSS var so it is tunable beside --nav-ramp")
    assert_match(/getPropertyValue\(\s*['"]--nav-max-step['"]\s*\)/, html,
                 "navCollapse must read the cap from CSS, not hardcode it")

    # DERIVED, NOT TUNED PER BAND. engine.css sizes --nav-ramp at 3x the band's
    # collapse total, so a cap of N px/frame is 3*N/ramp in --nav-p units. A
    # hardcoded step would be right on one breakpoint and wrong on the other.
    assert_match(/maxStep\s*=\s*\(\s*3\s*\*\s*self\._maxPx\s*\)\s*\/\s*ramp/, html,
                 "the step must derive from --nav-ramp's 3x relation to the collapse total")

    # Within one step take the target exactly — no crawl; beyond it advance by
    # exactly one step.
    assert_match(/Math\.abs\(delta\)\s*<=\s*maxStep/, html,
                 "inside one step the target must be taken exactly, or it converges asymptotically")
    assert_match(/self\.p\s*\+\s*\(\s*delta\s*>\s*0\s*\?\s*maxStep\s*:\s*-maxStep\s*\)/, html,
                 "beyond one step it must advance by exactly one step")
  end

  def test_a_clamped_frame_keeps_scheduling_until_it_lands
    html = render_head

    # THE MUTATION THIS KILLS: keeping the clamp and dropping the follow-up
    # frame. Every assertion above still passes, and the collapse FREEZES
    # wherever the clamp left it the moment the finger lifts — because nothing
    # else schedules a frame once scroll events stop arriving.
    assert_match(/if\s*\(\s*!snap\s*&&\s*p\s*!==\s*target\s*\)\s*\{[\s\S]{0,160}?requestAnimationFrame\(\s*apply\s*\)/, html,
                 "an unfinished clamp must schedule its own next frame — no scroll event will")
  end

  def test_the_snap_paths_bypass_the_limiter
    html = render_head

    # A short-page refusal and a reduced-motion state are DECISIONS, not motion.
    # Ramping them would animate the very thing each exists to avoid: the guard
    # would ease the navbar open on a page that must not collapse, and reduced
    # motion would get the interpolation it asked us to drop.
    assert_match(/snap\s*=\s*true/, html, "the guard and reduced-motion must mark themselves as snaps")
    assert_match(/if\s*\(\s*snap\s*\)\s*\{[\s\S]{0,240}?p\s*=\s*target;/, html,
                 "a snap must take the target directly, skipping the clamp")
  end

  # === THE PUBLISHER'S PER-FRAME COST ====================================

  def test_the_geometry_publisher_coalesces_and_skips_no_ops
    html = render_head

    # The ResizeObserver used to call publish() DIRECTLY. That was fine while
    # the header only resized during a 300ms transition; navCollapse made it
    # resize on EVERY scroll frame. Measured in turf-monster at 6x CPU throttle:
    # frames over 20ms were 13/24 through the ramp vs 0/24 past it, median 26ms
    # vs 8ms — and ablating this observer alone took it to 0/24 and median 13ms.
    assert_match(/new ResizeObserver\(\s*schedule\s*\)/, html,
                 "the ResizeObserver must go through schedule(), the rAF coalescer the other listeners use")
    refute_match(/new ResizeObserver\(\s*function\s*\([^)]*\)\s*\{\s*publish/, html,
                 "publishing straight from the observer bypasses the coalescer once per resize")

    # And a republish carrying the same number must cost nothing: these are
    # INHERITED custom properties on documentElement, so every write invalidates
    # style for the whole document.
    # The header is a pin now, so its skip lives on the pin's own last values —
    # one measurement per element per frame, written from that reading. The
    # full sourcing contract is in nav_offset_contract_test; this file only
    # cares that the unchanged write is still skipped, because that is the part
    # the collapse's per-frame cost depends on.
    assert_match(/if\s*\(\s*r\.h\s*!==\s*pin\.lastH\s*\)/, html, "an unchanged height must skip its write")
    assert_match(/if\s*\(\s*r\.bottom\s*!==\s*pin\.lastBottom\s*\)/, html, "an unchanged bottom must skip its write")
  end

  private

  def navbar_source
    File.read(File.expand_path("../../app/views/layouts/_navbar.html.erb", __dir__))
  end

  # LAYER 2 OF THE PRIMITIVE. The band table moved here from the navbar
  # partial's inline <style>: every engine-consuming app imports this
  # stylesheet, but only some render that partial, and three of six FORK the
  # navbar. While the table sat inline each fork hand-wrote its own — which is
  # how four independent copies of this collapse came to exist.
  def engine_css
    File.read(File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__))
  end

  # navbar_source WITH ITS ERB COMMENTS REMOVED.
  #
  # The file explains every hook it carries, in prose, right above the element that
  # carries it — which is good writing and a terrible thing to grep. `assert_includes
  # nav, "nav-shell"` was satisfied by the comment ABOUT nav-shell, so deleting the
  # class from the header left it green. Review caught all three by mutation.
  #
  # Comments are stripped rather than assertions being made cleverer, because the
  # clever version keeps losing: `<header[^>]*class=` fails on this file too, since
  # the header tag CONTAINS an ERB comment full of `>` characters — and after those
  # are stripped it STILL fails, because the surviving `<%= ... %>` output tag on the
  # same element ends in `>`. The matchers below are therefore bounded lazy spans
  # (`[\s\S]{0,600}?`) rather than negated character classes: wide enough to cross an
  # ERB tag, narrow enough that they cannot wander into the next element.
  def navbar_markup
    navbar_source.gsub(/<%#.*?%>/m, "")
  end

  def render_head
    view = ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
    def view.csrf_meta_tags = ""
    def view.csp_meta_tag = ""
    def view.studio_theme_css_tag = ""
    def view.javascript_importmap_tags = "<script></script>"

    view.render(partial: "layouts/studio/head")
  end
end
