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
#
# VERIFIED RED AGAINST THE DEFECT REINTRODUCED — the one line put back in
# #bar_stack, on a committed tree:
#
#   Studio.sidebar_sections = params[:sidebar].present? ? … : []   2-3 red of 3
#
# Two runs, two counts, and the spread is itself the finding: minitest randomises
# test order, and the first bar_stack request REPLACES the declared callable with a
# bare Array, so which of the three tests notices depends on the seed. The leak test
# and the global sweep were red in both runs. Nothing about this defect is stable
# under ordering, in either suite — which is exactly why the lane could stay green
# over it for as long as it did.
class E2eLabIsolationTest < ActionDispatch::IntegrationTest
  # The trigger button `components/_link_sidebar_trigger` renders, and the two
  # panels `components/_link_sidebar` renders. Counted through the DOM rather than
  # by scanning the body text, so a selector literal anywhere on the page cannot
  # read as one more button.
  TRIGGER = "[data-link-sidebar-trigger]"
  PANELS = "#studio-link-sidebar, #studio-link-sidebar-mobile"

  # The one link LAB_SIDEBAR_SECTIONS declares, and the only thing on the page
  # that ONLY that constant can put there.
  DECLARED_LINK = "#studio-link-sidebar a[href='/']"

  # /lab/geo_settings and /lab/site_identity are the lab pages that need a SCHEMA,
  # and the sweep below walks every lab route rather than a curated list — so their
  # tables have to exist here for the same reason e2e/boot.rb creates them for the
  # browser lane. The REAL migrations the gem ships, not hand-written CREATEs,
  # matching the pattern test/integration/geo_gate_test.rb established.
  def self.ensure_schema!
    connection = ActiveRecord::Base.connection
    unless connection.table_exists?(:studio_geo_settings)
      require_relative "../../db/migrate/20260818120000_create_studio_geo_settings"
      ActiveRecord::Migration.suppress_messages { CreateStudioGeoSettings.new.migrate(:up) }
    end
    return if connection.table_exists?(:studio_site_identities)

    require_relative "../../db/migrate/20260930120000_create_studio_site_identities"
    ActiveRecord::Migration.suppress_messages { CreateStudioSiteIdentities.new.migrate(:up) }
  end

  def setup = self.class.ensure_schema!

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

  # ---- THE GUARD THAT OUTLIVES THIS ONE ACCESSOR -----------------------------
  #
  # The two tests above pin `Studio.sidebar_sections`. This one pins the PROPERTY
  # the incident was an instance of: serving a lab page must not write ANY of the
  # engine's process-wide config. lib/studio.rb declares 73 `mattr_accessor`s
  # (counted 2026-09-28; studio_globals below snapshots 74 writable accessors,
  # the extra being the hand-written magic_link_store writer) and the
  # next one to be reached for per request will not be the sidebar.
  #
  # BY INSTRUMENTATION, NOT BY READING THE SOURCE. The obvious guard greps the lab
  # controller and views for `Studio.<attr> =`, and it is the weaker of the two:
  # it has to strip Ruby and ERB comments out of files that are mostly prose ABOUT
  # these accessors, it only catches the spellings its regex anticipated, and it
  # cannot see an in-place mutation (`Studio.auth_methods << :wallet`). Snapshotting
  # the values and diffing them after the requests catches every spelling, catches
  # mutation in place, and needs no opinion about comments.
  #
  # ENUMERATED FROM THE ROUTER AND FROM Studio ITSELF, both on purpose: a lab
  # action added next month is swept without anyone remembering to add it here, and
  # so is an accessor added to lib/studio.rb.
  #
  # EVERY PATH TWICE — bare, then with every knob the lane turns. A write can live
  # inside a branch only a query parameter reaches, which is exactly where this one
  # lived (`params[:sidebar].present? ? … : …`), so a bare sweep would have walked
  # straight past it.
  KNOBS = "signed_in=1&admin=1&devnet=1&sidebar=1&balance=1&subscribed=1" \
          "&identity=long&birthday=stored&tab=countries&state=authenticated&fp=x&issued=1"

  test "no lab request writes any Studio process global" do
    paths = lab_paths
    assert_operator paths.length, :>=, 15,
                    "only #{paths.length} lab route(s) found — the router enumeration broke and " \
                    "this test would be sweeping almost nothing"

    before = studio_globals

    paths.each do |path|
      get path
      assert_response :success, "GET #{path}"
      get "#{path}?#{KNOBS}"
      assert_response :success, "GET #{path}?#{KNOBS}"
    end

    after = studio_globals
    changed = before.keys.select { |key| before[key] != after[key] }

    assert_empty changed,
                 "serving the lab changed Studio.#{changed.join(", Studio.")} — a process-wide " \
                 "accessor written while handling a request. #{changed.map do |key|
                   "#{key}: #{before[key]} -> #{after[key]}"
                 end.join("; ")}. Studio's accessors are `mattr_accessor`s: one slot for the whole " \
                 "process, shared by every later request and every Playwright worker. Declare the " \
                 "value as a local of the request instead — test/dummy/config/application.rb shows " \
                 "the shape, and the two tests above are what happened the last time one of these " \
                 "was written per request."
  end

  private

  # Every GET the browser lane can reach on E2eLabController, read off the router
  # rather than listed, so a new lab action cannot quietly escape the sweep.
  def lab_paths
    Rails.application.routes.routes.filter_map do |route|
      next unless route.defaults[:controller] == "e2e_lab"
      next unless route.verb.to_s.include?("GET")

      route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
    end.uniq.sort
  end

  # Every Studio accessor that has a writer, with its current value rendered as a
  # string. `inspect` rather than the object: it separates a REASSIGNMENT from an
  # unchanged value, and it also catches a collection mutated IN PLACE, where the
  # before and after snapshots would otherwise be the same object and compare equal.
  def studio_globals
    Studio.singleton_methods(false)
          .grep(/\A[a-z_][a-z_0-9]*=\z/)
          .map { |writer| writer.to_s.chomp("=").to_sym }
          .select { |reader| Studio.respond_to?(reader) }
          .to_h do |reader|
            # A reader that raises is not evidence of a write; record the failure so
            # the diff stays stable across the two snapshots instead of erroring
            # this test out on something it is not about.
            [reader, begin
              Studio.public_send(reader).inspect
            rescue StandardError => e
              "unreadable: #{e.class}"
            end]
          end
  end
end
