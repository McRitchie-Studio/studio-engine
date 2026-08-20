# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "active_support/testing/time_helpers"

# Drive the real dummy app through the full router -> controller stack.
ActionDispatch::IntegrationTest.app = Rails.application

# Studio::ErrorHandling#require_authentication answers four formats, one of them
# turbo_stream — and a respond_to block raises on ANY unregistered mime, whatever
# the request asked for. Every real host has turbo-rails (an engine dependency);
# the dummy loads only the frameworks it needs, so register the type here.
Mime::Type.register "text/vnd.turbo-stream.html", :turbo_stream unless Mime[:turbo_stream]

# The engine's controllers inherit the HOST's ApplicationController, so define
# the minimal base a host provides. Nothing else in the dummy claims this name.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling
end

class User < ApplicationRecord
  def admin? = role == "admin"
end

# [integration] The geo gate, end to end: the operator's stored policy, the
# request-time detection that feeds it, the LOCK a host hangs on its own pages,
# and the two admin surfaces that manage all of it.
#
# The dummy app plays the host: GeoLabController includes Studio::GeoDetection
# and hangs `require_geo_allowed` on ONE action, which is exactly the shape the
# engine documents. So what runs here is the seam an app actually writes, not
# the concern's methods called directly.
class GeoGateTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  # A Geocoder result, in the only two shapes that matter: one that places the
  # visitor, and one that cannot.
  FakeResult = Struct.new(:state_code, :country_code, :region_code, :region, keyword_init: true)

  def self.ensure_schema!
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      # The engine's rescue path writes here. Without the table, any controller
      # exception is replaced by a confusing "Could not find table 'error_logs'"
      # — the real failure, hidden behind the logger's own.
      create_table :error_logs, force: true do |t|
        t.string :slug
        t.text   :message
        t.text   :inspect
        t.text   :backtrace
        t.string :target_type
        t.bigint :target_id
        t.string :parent_type
        t.bigint :parent_id
        t.timestamps
      end

      create_table :users, force: true do |t|
        t.string :email, null: false
        t.string :name
        t.string :role
        t.timestamps
      end
      add_index :users, :email, unique: true
    end

    return if ActiveRecord::Base.connection.table_exists?(:studio_geo_settings)

    # The REAL migration the gem ships — the one a host runs — rather than a
    # hand-written table that could drift from it.
    require_relative "../../db/migrate/20260818120000_create_studio_geo_settings"
    ActiveRecord::Migration.suppress_messages { CreateStudioGeoSettings.new.migrate(:up) }
  end

  def setup
    self.class.ensure_schema!
    Studio::GeoSetting.delete_all
    User.delete_all
    @home_country = Studio.geo_home_country
    @defaults = [Studio.geo_default_banned_subdivisions, Studio.geo_default_banned_countries]
    @lookups = []
    stub_geocoder(nil)
  end

  def teardown
    restore_geocoder
    Studio::GeoSetting.delete_all
    User.delete_all
    Studio.geo_home_country = @home_country
    Studio.geo_default_banned_subdivisions, Studio.geo_default_banned_countries = @defaults
  end

  # --- 1. what the operator stored -----------------------------------------

  # One vocabulary in the column. A grid posts bare codes, an older app stored
  # bare codes, a country editor posts tokens — all of them land as tokens, so a
  # reader never has to guess which form it is holding.
  test "bare subdivision codes are canonicalised to region tokens on save" do
    setting = Studio::GeoSetting.create!(app_name: Studio.app_name, enabled: true,
                                         banned_subdivisions: %w[wa Washington US-ID],
                                         banned_countries: %w[cu ir])

    assert_equal %w[US-ID US-WA], setting.reload.banned_subdivisions
    assert_equal %w[CU IR], setting.banned_countries
  end

  test "the grid reads back bare codes for the home country" do
    Studio::GeoSetting.create!(app_name: Studio.app_name, enabled: true,
                               banned_subdivisions: %w[WA CA-AB])

    assert_equal %w[WA], Studio::GeoSetting.banned_subdivision_codes
  end

  # A fresh app has no row. It must still publish, and enforce, the policy its
  # initializer declares — otherwise the exclusion page and the gate disagree
  # from the first request until someone visits /admin/geo.
  test "with no row the configured defaults are the effective policy" do
    Studio.geo_default_banned_subdivisions = %w[WA ID]
    Studio.geo_default_banned_countries = %w[cu]

    assert_equal %w[US-ID US-WA], Studio::GeoSetting.effective_banned_subdivisions
    assert_equal %w[CU], Studio::GeoSetting.effective_banned_countries
    refute Studio::GeoSetting.enforcing?, "an unprovisioned app enforces nothing"
  end

  # --- 2. detection, cached in the session ---------------------------------

  test "a resolved visitor is placed and the answer is reused" do
    stub_geocoder(FakeResult.new(state_code: "CO", country_code: "us"))

    get "/lab/geo"
    assert_equal "US | CO | ALLOWED", response.body
    assert_equal 1, @lookups.length

    get "/lab/geo"
    assert_equal 1, @lookups.length, "a resolved region is trusted for the full TTL"
  end

  # THE SELF-HEAL, and the clock bug hiding under it. A blank result is retried
  # within minutes; the stamp is written as `Time.current.to_s` (UTC), so the
  # comparison must be made against the same clock. Against a local-zone Time.now
  # the two strings differ by the offset and read as a different DAY — the retry
  # then never fires and an unplaceable visitor stays locked out for 24 hours.
  test "a blank result is retried within minutes, on the Rails clock" do
    stub_geocoder(nil)
    get "/lab/geo"
    assert_equal 1, @lookups.length

    get "/lab/geo"
    assert_equal 1, @lookups.length, "not on every single request"

    stub_geocoder(FakeResult.new(state_code: "CO", country_code: "US"))
    travel(Studio.geo_retry_ttl + 1.minute) { get "/lab/geo" }

    assert_equal 2, @lookups.length, "the short retry window must expire"
    assert_equal "US | CO | ALLOWED", response.body
  end

  # Outside the home country the provider's only answer is often the region NAME.
  # Dropping it would blank the location — and a blank is the state the
  # fail-closed rule treats as suspicious.
  test "a foreign visitor keeps the region name the provider gave" do
    stub_geocoder(FakeResult.new(region: "Alberta", country_code: "CA"))

    get "/lab/geo"

    assert_equal "CA | Alberta | ALLOWED", response.body
  end

  # An unplaceable visitor is reported as unplaceable. The badge says "??" and
  # the policy decides what that means — the detection layer never guesses.
  test "an unplaceable visitor is honest about it" do
    stub_geocoder(nil)

    get "/lab/geo"

    assert_equal "US | ?? | ALLOWED", response.body
  end

  # A provider that raises must not 500 the page. Every host app's navbar renders
  # the badge, so a lookup failure would otherwise take down every page at once.
  test "a provider failure leaves the page standing" do
    stub_geocoder_raising(Timeout::Error.new("ipinfo timed out"))

    get "/lab/geo"

    assert_response :success
    assert_equal "US | ?? | ALLOWED", response.body
  end

  # --- 3. the lock ----------------------------------------------------------

  test "a blocked visitor is turned away from a locked page and told why" do
    enable_gate(subdivisions: %w[WA])
    stub_geocoder(FakeResult.new(state_code: "WA", country_code: "US"))

    get "/lab/geo_locked"

    assert_redirected_to "/"
    assert_match(/not available in your area \(WA\)/, flash[:alert])
  end

  test "an allowed visitor walks through the same lock" do
    enable_gate(subdivisions: %w[WA])
    stub_geocoder(FakeResult.new(state_code: "CO", country_code: "US"))

    get "/lab/geo_locked"

    assert_response :success
    assert_equal "locked page", response.body
  end

  # The kill switch has to mean OFF. This is the state an operator flips to when
  # the gate is misfiring, so it must release even the blocked region itself.
  test "a disabled gate locks nobody out" do
    enable_gate(subdivisions: %w[WA], enabled: false)
    stub_geocoder(FakeResult.new(state_code: "WA", country_code: "US"))

    get "/lab/geo_locked"

    assert_response :success
  end

  # FAIL CLOSED: a home-country visitor the app cannot place could be sitting in
  # any blocked region behind a VPN.
  test "an unplaceable home country visitor is locked out" do
    enable_gate(subdivisions: %w[WA])
    stub_geocoder(nil)

    get "/lab/geo_locked"

    assert_redirected_to "/"
    # No region resolved, so the copy must not print an empty "( )".
    assert_equal "This feature is not available in your area.", flash[:alert]
  end

  test "a JSON request gets 403 and the same words" do
    enable_gate(subdivisions: %w[WA])
    stub_geocoder(FakeResult.new(state_code: "WA", country_code: "US"))

    get "/lab/geo_locked", headers: { "ACCEPT" => "application/json" }

    assert_response :forbidden
    assert_match(/not available in your area/, JSON.parse(response.body)["error"])
  end

  # THE TRAP THE REGION TOKEN EXISTS FOR: a Canadian region code that collides
  # with a US state must not be caught by the US ban.
  test "a foreign region colliding with a banned us state is allowed" do
    enable_gate(subdivisions: %w[CA])
    stub_geocoder(FakeResult.new(region_code: "CA", country_code: "CA"))

    get "/lab/geo_locked"

    assert_response :success
  end

  test "a banned country blocks every region in it" do
    enable_gate(subdivisions: [], countries: %w[CU])
    stub_geocoder(FakeResult.new(region: "Havana", country_code: "CU"))

    get "/lab/geo_locked"

    assert_redirected_to "/"
  end

  # --- 4. the probe ---------------------------------------------------------

  # PUBLIC by design: a page's own JavaScript asks this before anyone signs in.
  test "the probe answers a signed-out visitor" do
    enable_gate(subdivisions: %w[WA])
    stub_geocoder(FakeResult.new(state_code: "WA", country_code: "US"))

    get "/geo/check"

    body = JSON.parse(response.body)
    assert_response :success
    assert_equal "US", body["country"]
    assert_equal "WA", body["subdivision"]
    assert_equal "US-WA", body["region"]
    assert_equal true, body["blocked"]
    # The legacy key turf-monster's client already reads.
    assert_equal "WA", body["state"]
  end

  # The point of the probe is a FRESH answer — an operator moving between
  # networks needs where they are now, not the answer cached for the next day.
  test "the probe forces a fresh lookup" do
    stub_geocoder(FakeResult.new(state_code: "CO", country_code: "US"))

    get "/lab/geo"
    assert_equal 1, @lookups.length

    get "/geo/check"
    assert_equal 2, @lookups.length
  end

  # --- 5. the admin surfaces ------------------------------------------------

  test "the manager is admin only" do
    # Signed out, the host's own authentication gate answers first — the page is
    # never rendered to a stranger.
    get "/admin/geo"
    assert_redirected_to "/login"

    # Signed in but not an admin: past authentication, stopped by require_admin.
    user = User.create!(email: "member@example.test", name: "Member", role: "member")
    post "/lab/sign_in", params: { user_id: user.id }
    get "/admin/geo"
    assert_redirected_to "/"

    sign_in_admin
    get "/admin/geo"
    assert_response :success
    assert_match(/Geo Settings/, response.body)
  end

  # THE FORM'S OWN FIELD NAMES, not hand-posted params. A namespaced model's
  # param key is `studio_geo_setting`, so a bare form_with here would post fields
  # the controller never reads — a Save that redirects with "updated" and changes
  # nothing, which every hand-rolled params test in the world stays green through.
  test "the page posts the field names the controller reads" do
    sign_in_admin
    get "/admin/geo"

    assert_match(/name="geo_setting\[enabled\]"/, response.body)
    assert_match(/name="geo_setting\[banned_subdivisions\]\[\]"/, response.body)
    assert_match(/name="geo_setting\[banned_countries\]\[\]"/, response.body)
    refute_match(/name="studio_geo_setting\[/, response.body,
                 "the namespaced param key would be read by nobody")
  end

  # THE PAGE MUST SHOW THE GATE'S ACTUAL STATE. An operator reads the kill switch
  # to decide whether the gate is live; a box that renders unchecked while the
  # gate is ENFORCING is worse than no page at all, because the next Save posts
  # that lie back and silently disables enforcement.
  test "the kill switch renders checked when the gate is live" do
    sign_in_admin
    enable_gate(subdivisions: %w[WA])

    get "/admin/geo"

    assert_match(/checked/, enabled_input, "the box must be checked while the gate is enforcing:\n#{enabled_input}")
  end

  test "the kill switch renders unchecked when the gate is off" do
    sign_in_admin
    enable_gate(subdivisions: %w[WA], enabled: false)

    get "/admin/geo"

    refute_match(/checked/, enabled_input)
  end

  # THE GRID MUST ANSWER A CLICK. It paints from the checkbox — the server sets
  # `checked`, one CSS rule paints it — so a click repaints instantly with no JS.
  # Painting from a server-rendered class instead (the first version of this page)
  # meant a click changed nothing on screen until Save: the operator toggling
  # squares reasonably read the grid as dead while it was recording every click.
  #
  # Asserted structurally, because that is what a request test can honestly see:
  # a blocked square's input carries `checked`, an allowed one does not, and the
  # paint hangs off that state rather than off a class baked into the markup.
  test "a blocked square is marked on its checkbox, not baked into its class" do
    sign_in_admin
    enable_gate(subdivisions: %w[WA])

    get "/admin/geo"

    assert_match(/checked/, grid_input("WA"), "WA is blocked, so its box must be checked")
    refute_match(/checked/, grid_input("CO"), "CO is not blocked")

    # The rule that does the painting, and the class that hangs it on the state.
    assert_match(/\.geo-grid label:has\(input:checked\)/, response.body,
                 "the blocked look must follow the checkbox, or a click paints nothing")
    refute_match(/class="[^"]*text-red-400[^"]*"[^>]*>\s*<input[^>]*value="WA"/m, response.body,
                 "no server-baked red class on the square itself")
  end

  # --- the two editors ------------------------------------------------------

  # Countries are a GRID now, not a comma-separated field: the same click that
  # blocks a state blocks a country, with the country's flag beside it.
  test "the page offers both editors, with flags" do
    sign_in_admin

    get "/admin/geo"

    # States: a checkbox per subdivision, each with its small flag raster.
    assert_match(/name="geo_setting\[banned_subdivisions\]\[\]"[^>]*value="WA"/, response.body)
    assert_match(%r{state-flags/thumb/wa\.png}, response.body, "the state square carries its flag")

    # "CO" is Colorado AND Colombia, so the two grids carry distinct classes —
    # a selector that reached both would be ambiguous for every later reader.
    assert_match(/geo-grid-states/, response.body)
    assert_match(/geo-grid-countries/, response.body)

    # Countries: a checkbox per country, each with its emoji flag.
    assert_match(/name="geo_setting\[banned_countries\]\[\]"[^>]*value="CU"/, response.body)
    assert_includes response.body, "🇨🇺", "the country square carries its flag"
    assert_includes response.body, "Cuba", "and its name, for the operator who does not read codes"
  end

  # THE SUMMARY CARD answers "what does this app block?" without reading a
  # 52-square grid — the switch and what it switches on, together.
  test "the configuration card summarises what is blocked" do
    sign_in_admin
    enable_gate(subdivisions: %w[WA ID], countries: %w[CU])

    get "/admin/geo"

    states = response.body[/data-geo-summary="states".*?<\/div>/m]
    countries = response.body[/data-geo-summary="countries".*?<\/div>/m]

    assert_match(/geo-chip.*?\bID\b/m, states, "each blocked region gets a chip")
    assert_match(/geo-chip.*?\bWA\b/m, states)
    assert_match(%r{state-flags/thumb/wa\.png}, states, "with its flag")
    assert_match(/geo-chip.*?\bCU\b/m, countries)
    assert_includes countries, "🇨🇺"
    # The counts beside the headings — and the same numbers on the tabs, because
    # a page showing two different counts for one list is its own bug report.
    assert_equal 2, response.body.scan(/data-geo-summary-count="states"[^>]*>2</).size
    assert_equal 2, response.body.scan(/data-geo-summary-count="countries"[^>]*>1</).size
  end

  test "the summary says so when nothing is blocked" do
    sign_in_admin
    enable_gate(subdivisions: [], countries: [])

    get "/admin/geo"

    assert_includes response.body, "Nothing blocked yet."
    assert_match(/data-geo-summary-count="states"[^>]*>0</, response.body)
  end

  test "an operator blocks a country from the grid" do
    sign_in_admin

    patch "/admin/geo", params: {
      geo_setting: { enabled: "1", banned_countries: ["", "CU", "IR"] }, tab: "countries"
    }

    assert_equal %w[CU IR], Studio::GeoSetting.current.banned_countries
  end

  # The tab rides in the form, so a save lands back in the editor the operator
  # was working in rather than snapping to states every time.
  test "saving returns to the editor you were in" do
    sign_in_admin

    patch "/admin/geo", params: { geo_setting: { enabled: "1" }, tab: "countries" }

    assert_redirected_to "/admin/geo?tab=countries"
    follow_redirect!
    assert_match(/id="geo_tab_countries"[^>]*checked/, response.body)
  end

  # A tab value goes into a redirect URL, so it is whitelisted rather than echoed.
  test "an unknown tab is ignored rather than reflected" do
    sign_in_admin

    patch "/admin/geo", params: { geo_setting: { enabled: "1" }, tab: "javascript:alert(1)" }

    assert_redirected_to "/admin/geo"
  end

  # --- the live preview -----------------------------------------------------

  # Ticking your OWN region repaints the badge before anything is saved, so an
  # operator sees what a rule does to a real visitor instead of saving to find
  # out. The browser half is asserted in a consuming app's lane; what a request
  # test can honestly see is that the page carries the inputs that computation
  # needs — the visitor's own region, and the fail-closed setting.
  test "the page carries what the live preview computes from" do
    sign_in_admin

    get "/admin/geo"

    assert_match(/data-geo-home="US"/, response.body)
    assert_match(/data-geo-fail-closed="true"/, response.body)
    assert_match(/data-geo-verdict/, response.body)
    assert_match(/data-geo-preview/, response.body, "one attribute drives badge and verdict alike")
  end

  test "an operator saves a policy from the page" do
    sign_in_admin

    patch "/admin/geo", params: {
      geo_setting: { enabled: "1", banned_subdivisions: ["", "WA", "ID"], banned_countries: "cu, ir" }
    }

    assert_redirected_to "/admin/geo"
    setting = Studio::GeoSetting.current
    assert setting.enabled?
    assert_equal %w[US-ID US-WA], setting.banned_subdivisions
    assert_equal %w[CU IR], setting.banned_countries
  end

  # Unchecking the LAST box has to save an empty list. The hidden anchor field is
  # what makes the form post something rather than nothing — and "nothing" would
  # read as no change, i.e. a save that silently did nothing.
  test "clearing every box saves an empty list" do
    sign_in_admin
    enable_gate(subdivisions: %w[WA])

    patch "/admin/geo", params: { geo_setting: { enabled: "1", banned_subdivisions: [""] } }

    assert_empty Studio::GeoSetting.current.banned_subdivisions
  end

  # The button NAMES the place. An operator about to be moved should read where
  # to — and it is the assertion that keeps a consuming app's browser lane, which
  # clicks "Simulate WA" by name, from silently matching nothing.
  test "the simulate button names the region it would pin" do
    sign_in_admin
    enable_gate(subdivisions: %w[WA])

    get "/admin/geo"

    assert_match(/Simulate WA/, response.body)
  end

  # Simulation is how an operator walks the blocked experience without a VPN.
  test "an operator can stand in a blocked region and step back out" do
    sign_in_admin
    enable_gate(subdivisions: %w[WA])
    stub_geocoder(FakeResult.new(state_code: "CO", country_code: "US"))

    post "/admin/geo/toggle"
    # The flash names the PLACE, not the storage token: "Simulating WA", never
    # "Simulating US-WA". A consuming app's browser lane reads this string.
    assert_equal "Simulating WA.", flash[:notice]
    get "/lab/geo"
    assert_equal "US | WA | BLOCKED", response.body

    post "/admin/geo/toggle"
    get "/lab/geo"
    assert_equal "US | CO | ALLOWED", response.body
  end

  # With nothing blocked there is no blocked experience to walk. Saying so beats
  # pinning the operator to a location that behaves like the one they are in.
  test "simulation refuses when the app blocks nothing" do
    sign_in_admin

    post "/admin/geo/toggle"

    assert_match(/Nothing is blocked yet/, flash[:alert])
  end

  private

  # The CHECKBOX for the kill switch — not the hidden "0" companion Rails emits
  # right before it, which carries the same name and would answer every question
  # about it wrongly.
  def enabled_input
    response.body.scan(/<input[^>]*name="geo_setting\[enabled\]"[^>]*>/)
            .find { |tag| tag.include?(%(type="checkbox")) } ||
      raise("no geo_setting[enabled] checkbox on the page")
  end

  # The grid checkbox for one subdivision code.
  def grid_input(code)
    response.body[/<input[^>]*name="geo_setting\[banned_subdivisions\]\[\]"[^>]*value="#{code}"[^>]*>/] ||
      raise("no grid checkbox for #{code}")
  end

  def enable_gate(subdivisions: [], countries: [], enabled: true)
    Studio::GeoSetting.create!(app_name: Studio.app_name, enabled: enabled,
                               banned_subdivisions: subdivisions, banned_countries: countries)
  end

  # Through a real request, so the cookie jar carries the session the way a
  # browser would, rather than reaching into the session store.
  def sign_in_admin
    user = User.create!(email: "admin@example.test", name: "Admin", role: "admin")
    post "/lab/sign_in", params: { user_id: user.id }
  end

  # --- Geocoder doubles -----------------------------------------------------

  def stub_geocoder(result)
    install_geocoder_stub { |ip| @lookups << ip; [result].compact }
  end

  def stub_geocoder_raising(error)
    install_geocoder_stub { |ip| @lookups << ip; raise error }
  end

  def install_geocoder_stub(&block)
    @geocoder_original ||= ::Geocoder.method(:search)
    ::Geocoder.define_singleton_method(:search) { |ip, *_args| block.call(ip) }
  end

  def restore_geocoder
    return if @geocoder_original.nil?

    ::Geocoder.define_singleton_method(:search, @geocoder_original)
    @geocoder_original = nil
  end
end
