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
    assert_match(/roomExpanded\s*<[\s\S]{0,80}?\bp\s*=\s*0/, html,
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
    assert_match(/\bp\s*=\s*\([\s\S]*?\)\s*\?\s*1\s*:\s*0/, branch,
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
    assert_includes nav, "nav-shell", "the header is the --nav-p scope root"
    assert_includes nav, "nav-row", "the collapsing row needs its own hook"

    # The step and the clock, both gone. transition-shadow may stay: box-shadow
    # paints, it never reflows, so it cannot move content under the reader.
    refute_match(/@scroll\.window/, nav,
                 "the per-event threshold handler is replaced by navCollapse's coalesced listener")
    refute_match(/scrolled \? 'py-2' : 'py-6'/, nav,
                 "row padding must interpolate off --nav-p, not swap on a boolean")
    refute_match(/transition-all duration-300/, nav,
                 "no collapsing dimension may sit on a clock")
    assert_includes nav, "transition-shadow",
                    "the shadow may still fade on a clock — it paints and never reflows"

    # Each band is the two ENDPOINTS of its collapse, expressed once.
    %w[--nav-pad --nav-logo-size --nav-title-size --nav-title-lead-size].each do |hook|
      assert_match(/#{Regexp.escape(hook)}:\s*(calc\([^;]*var\(--nav-p\)|var\(--nav-title-size\))/, nav,
                   "#{hook} must derive from --nav-p")
    end
    assert_match(/--nav-ramp:\s*\d+px/, nav, "each band must declare its own ramp width")

    refute_match(/\.is-scrolled\s+\.nav-(title|logo)/, nav,
                 "the .is-scrolled size overrides are replaced by --nav-p interpolation")
    # Anchored on a DURATION so the band table's own comment, which names the
    # declaration it replaced, does not trip its own guard.
    refute_match(/transition:\s*font-size\s+[\d.]+s/, nav,
                 "font-size transitions produced the 1px reverse twitch at the threshold")
  end

  private

  def navbar_source
    File.read(File.expand_path("../../app/views/layouts/_navbar.html.erb", __dir__))
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
