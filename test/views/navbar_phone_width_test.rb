# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [unit] The header's PHONE WIDTH contract — the markup and the two width caps
# that let layouts/_navbar shrink instead of spilling.
#
# WHAT THE DEFECT ACTUALLY WAS, because it is not the obvious one. The header
# row is two columns: `flex-1` on the left (logo + app name) and a
# `flex-shrink-0` column on the right (balance, icons, username, avatar). The
# right column's phone step was a CONSTANT 14rem = 224px, which is 57% of a
# 390px screen, on an item that refuses to shrink. That left the left column
# 166px for 32px of padding, a 48px logo, its gap, and the app's name — and
# because every flex item defaults to `min-width: auto`, the name could not
# truncate either. So it drew OUTSIDE its own column, across the gap, on top of
# the user column beside it.
#
# MEASURED before the fix, /lab/bar_stack?signed_in=1 at 390x844 with
# app_name "McRitchie Industries" (e2e/header_phone_width.spec.js drives the
# same page):
#   documentElement.scrollWidth  390
#   documentElement.clientWidth  390     <- the page did NOT scroll sideways
#   left column border box       0..166
#   .nav-title right edge        175.3   <- 9.3px outside its own column
# The honest document-level test for "this page scrolls sideways" was GREEN on
# the broken header, at the exact width in the acceptance criterion. That is why
# this file pins the CONTAINMENT contract and not a document width: a column
# that overflows into its neighbour never reaches documentElement at all.
#
# The contract, in the order it matters:
#   A. Every flex item between the row and the app name carries min-w-0, so the
#      name's box can be smaller than the name. One missing link restores the
#      min-content floor and the spill comes back.
#   B. The two TITLE SPANS truncate — not the <h1>, which is itself a flex
#      container.
#   C. Both phone width caps are a share of the viewport, and BOTH properties
#      are covered: .user-nav-col is a `width`, .user-nav-fit is a `max-width`.
#   D. 768px and up is untouched.
class NavbarPhoneWidthTest < ActiveSupport::TestCase
  # A signed-in host, because the right-hand column — the half that could not
  # shrink — does not render at all for a signed-out visitor. A signed-out
  # fixture measures a header that cannot exhibit this defect.
  class SignedInHostController < ActionController::Base
    class StubUser
      def display_name = "Alexandra Mcritchie"
      def avatar = @avatar ||= Class.new { def attached? = false }.new
      def avatar_color = "#6366f1"
      def avatar_initials = "AM"
    end

    helper_method :logged_in?, :current_user, :root_path

    def logged_in? = true
    def current_user = @current_user ||= StubUser.new
    def root_path = "/"
  end

  def navbar_html(**locals)
    args = locals.map { |k, v| ", #{k}: #{v.inspect}" }.join
    SignedInHostController.render(inline: %(<%= render "layouts/navbar"#{args} %>))
  end

  # ── A. the min-w-0 chain ────────────────────────────────────────────────

  test "every flex item between the row and the title can shrink" do
    html = navbar_html

    # The row's left item. `flex-1` alone is flex: 1 1 0% with min-width auto,
    # which floors it at its own min-content — the basis of 0 is irrelevant.
    assert_includes html, %(class="flex-1 min-w-0 px-4"),
      "the row's left column must be allowed below its min-content"

    # Its inner flex, which is what actually holds the logo link.
    assert_includes html, %(class="flex items-center gap-6 min-w-0")

    # The logo link.
    assert_match(/class="nav-logo-link inline-flex items-center gap-3 group min-w-0"/, html,
      "the logo link is a flex item too and floors the chain if it is left out")

    # The title itself.
    assert_match(/<h1 class="nav-title[^"]*\bmin-w-0\b/, html)
  end

  # ── B. the spans truncate, not the h1 ───────────────────────────────────

  test "both title words truncate individually" do
    html = navbar_html

    # .nav-title is display:flex (a column below 768px, a baseline row above),
    # so the boxes that need clipping are the SPANS. `truncate` on the h1 clips
    # the flex container and leaves its items drawing outside it.
    assert_match(/<h1 class="nav-title[^"]*"><span class="truncate">/, html,
      "the app name's first word must clip itself")
    assert_match(/<span class="text-primary truncate">/, html,
      "the app name's last word must clip itself")

    refute_match(/<h1 class="nav-title[^"]*\btruncate\b/, html,
      "truncate belongs on the spans; on the flex container it clips the wrong box")
  end

  # ── C. both caps, both properties, a share of the viewport ──────────────

  test "the phone width caps are a share of the viewport" do
    html = navbar_html

    # .user-nav-fit — the no-balance shape, a max-width (the column hugs its
    # content and this is the ceiling).
    assert_includes html, ".user-nav-fit { max-width: min(14rem, 46vw); }"
    assert_match(/min-width: 400px.*\.user-nav-fit \{ max-width: min\(15rem, 46vw\); \}/, html)
  end

  test "the balance-bearing column is capped too" do
    html = navbar_html

    # .user-nav-col is a `width`, not a max-width. It is a SEPARATE property on
    # a separate class, so a fix applied to .user-nav-fit alone leaves the
    # balance-bearing shape — the one turf-monster's fork is modelled on —
    # exactly as broken. Asserted apart from the fit column for that reason.
    assert_includes html, ".user-nav-col { width: min(14rem, 46vw); }"
    assert_match(/min-width: 400px.*\.user-nav-col \{ width: min\(15rem, 46vw\); \}/, html)
  end

  # ── D. desktop is untouched ─────────────────────────────────────────────

  test "the desktop band keeps its bare rem" do
    html = navbar_html

    # No min() at 768px and up. A vw there would fold the desktop scrollbar's
    # width into a header dimension, and the band has 448px of slack at its own
    # breakpoint — there is nothing for a share to buy.
    assert_match(/min-width: 768px.*\.user-nav-col \{ width: 20rem; \}/, html)
    assert_match(/min-width: 768px.*\.user-nav-fit \{ max-width: 20rem; \}/, html)
    refute_match(/min-width: 768px.*vw/, html,
      "the desktop band must not measure the viewport")
  end

  # ── The caps are ordered, which is the property, not the numbers ────────

  test "a wider band never caps the user column narrower than a smaller one" do
    html = navbar_html

    caps = html.scan(/\.user-nav-fit \{ max-width: (?:min\()?(\d+(?:\.\d+)?)rem/).flatten.map(&:to_f)

    assert_equal 3, caps.length, "expected a cap for each of the three bands"
    assert_equal caps.sort, caps,
      "the rem ceilings must not decrease as the viewport grows — a wider phone " \
      "showing LESS of the app's name is the regression this ordering exists to stop"
  end
end
