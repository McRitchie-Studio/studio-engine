# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"

# [integration] ONE LAB REQUEST MUST NOT CHANGE WHAT THE NEXT ONE RENDERS.
#
# THE INCIDENT. `Studio.sidebar_sections` is a `mattr_accessor` — ONE slot for the
# whole process — and E2eLabController#bar_stack used to assign it per request from
# `?sidebar=1`. So a single visit to /lab/bar_stack?sidebar=1 armed the link sidebar
# for every later request in that server process, whatever it asked for. Measured on
# the browser lane at a73edfe, port 3621, one Puma process:
#
#   GET /lab/toast_over_banner                          0 trigger buttons, --nav-h 125px
#   GET /lab/bar_stack?signed_in=1&admin=1&sidebar=1     (arms the global)
#   GET /lab/toast_over_banner                          2 trigger buttons, --nav-h 145px
#
# Two sidebar triggers and two slide-out panels on a page that declared none, and a
# header 20px taller than the one every other spec measures.
#
# WHY NO BROWSER SPEC CAUGHT IT, AND WHY THAT IS THE WORST PART. Playwright runs the
# e2e/ files in alphabetical order, which happens to put nav_collapse.spec.js — which
# visits /lab/bar_stack with no `sidebar` param, resetting the global — between the
# contaminator (header_phone_width.spec.js) and the victim (toast_over_banner.spec.js).
# The lane was clean by FILE NAMING. Measured: running the contaminator and the victim
# back to back with nothing between them still passed every assertion, so the lane's
# own green check could never have reported this.
#
# WHY THIS TIER. The contamination is in the RESPONSE BYTES — the navbar renders the
# trigger server-side — so the cheapest honest observer is a Rails integration test
# that issues the two requests in one process, in the order that breaks. It runs on
# every PR in the Ruby suite, it is deterministic, and it does not depend on which
# browser spec happens to sort where.
#
# THE MIDDLE ASSERTION IS THE ANTI-VACUITY ONE. "No sidebar rendered" is trivially
# true of a lab that lost the ability to render one at all — which is exactly what a
# careless fix (deleting the knob) would produce. So the contaminating request is
# asserted to ACTUALLY arm the sidebar before its absence afterwards means anything.
class E2eLabIsolationTest < ActionDispatch::IntegrationTest
  # The trigger button `components/_link_sidebar_trigger` renders, and the two
  # panels `components/_link_sidebar` renders. Counted through the DOM rather than
  # by scanning the body text: `components/_link_sidebar`'s own bridge script
  # carries the string '[data-link-sidebar-trigger]' as a selector literal, so a
  # substring count reads one higher than the number of buttons on the page.
  TRIGGER = "[data-link-sidebar-trigger]"
  PANELS = "#studio-link-sidebar, #studio-link-sidebar-mobile"

  # The one link LAB_SIDEBAR_SECTIONS declares, and the only thing on the page
  # that ONLY that constant can put there.
  DECLARED_LINK = "#studio-link-sidebar a[href='/']"

  def triggers = css_select(TRIGGER).length

  def panels = css_select(PANELS).length

  def declared_links = css_select(DECLARED_LINK).length

  test "a lab page renders no sidebar after one that asked for it" do
    get "/lab/toast_over_banner"
    assert_response :success
    assert_equal 0, triggers, "the victim page starts clean — it declares no sections"

    # SIGNED OUT, DELIBERATELY, and the reason is a measurement. `?signed_in=1`
    # renders two triggers on its own: Studio::SidebarSections.standard prepends
    # the engine's own "You" section for any signed-in view that has a
    # profile_path, so a trigger count taken with signed_in=1 would be satisfied
    # whether or not `?sidebar=1` still does anything. This request's sections can
    # only come from LAB_SIDEBAR_SECTIONS, and the declared link is asserted
    # rather than the count, so a lab that had lost the knob fails HERE instead of
    # greening the leak assertion below.
    get "/lab/bar_stack?sidebar=1"
    assert_response :success
    assert_operator declared_links, :>, 0,
                    "/lab/bar_stack?sidebar=1 no longer renders the host-declared link from " \
                    "LAB_SIDEBAR_SECTIONS, so the assertion below would pass over a lab that " \
                    "simply cannot exhibit the leak. The knob has to still work for its " \
                    "absence elsewhere to mean anything."

    get "/lab/toast_over_banner"
    assert_response :success
    assert_equal 0, triggers,
                 "/lab/toast_over_banner rendered #{triggers} link-sidebar trigger(s) after a " \
                 "request to /lab/bar_stack?sidebar=1. Studio.sidebar_sections is a process " \
                 "global; a lab action that assigns it per request leaks that request's state " \
                 "into every page served afterwards."
    assert_equal 0, panels, "and no slide-out panels either"
  end

  # THE OTHER HALF OF THE ACCEPTANCE: the declaration is per REQUEST, not per
  # bar_stack. Any lab page can now ask for the sidebar, which is what makes the
  # sidebar a local of the page rather than a fact about the process.
  test "any lab page can declare a sidebar for its own request" do
    get "/lab/toast_over_banner?sidebar=1"
    assert_response :success
    assert_operator declared_links, :>, 0,
                    "?sidebar=1 is declared by a before_action on EVERY lab action, so a page " \
                    "other than bar_stack must be able to ask for it"

    get "/lab/toast_over_banner"
    assert_response :success
    assert_equal 0, triggers, "and the next request is unaffected by that one"
  end
end
