# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_dispatch"
require "action_dispatch/testing/integration"
require "rack/test"

# The host's base controller in the shape the strictest adopters have it:
# Studio::ErrorHandling gates EVERY controller behind require_authentication
# (mcritchie-industries and cyvasse). Signing in is a request header here, so
# the suite needs no users table: the footer only ever asks `logged_in?`.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  layout "site_footer_host"

  def logged_in? = request.headers["X-Signed-In"].present?
end

# A public page: the kind an app lists in config.site_footer_controllers.
class FooterHostLandingController < ApplicationController
  skip_before_action :require_authentication

  def show = render(inline: "<h1>Landing</h1>", layout: true)

  # Every helper a consumer may call from its own view, on one page.
  def helpers
    render inline: <<~ERB, layout: true
      <div data-own-links>
        <%= studio_booking_link %>
        <%= studio_booking_link "Book a call", class: "btn" %>
        <%= studio_booking_link "Talk to us", "/contact", class: "btn" %>
      </div>
      <%= studio_footer_map class: "contact-map", style: "height: 20rem", zoom: 12, controls: false %>
      <%= studio_footer_map({ street: "1 Main St", city_line: "Town, ST", lat: 1.5, lng: 2.5 }) %>
      <div data-frame="config"><%= studio_booking_frame %></div>
      <div data-frame="whole"><%= studio_booking_frame title: "Second frame", crop: false %></div>
      <div data-frame="one-off"><%= studio_booking_frame crop: { top: 150, bottom: 480, frame_height: 640 } %></div>
      <%= studio_booking_popup %>
    ERB
  end
end

# AN APP'S OWN BOOKING PAGE, the way an app that wants its own words around the
# calendar writes one: its own controller and view, the engine's frame, and
# nothing else. Signed-in only by default, like every controller here, and public
# because the app says so. It is named to the engine by config.booking_path.
class FooterHostScheduleController < ApplicationController
  skip_before_action :require_authentication

  def show = render(inline: "<h1>Book a time</h1><%= studio_booking_frame %>", layout: true)
end

# A working surface: signed-in only, and it keeps no footer.
class FooterHostBoardController < ApplicationController
  def show = render(inline: "<h1>Board</h1>", layout: true)
end

# [integration] The site footer and the booking primitives, rendered by a host.
#
#   1. the footer prints the declared facts, and each missing fact removes its part
#   2. no address: no Location band, no map and no Leaflet on the page
#   3. no booking_url: no popup, no frame, and booking links are ordinary links
#   4. where it shows: every page for a visitor, listed controllers when signed in
#   5. the booking page is drawn by a flag, public, and 404 with nothing to book
#   6. the helpers a consumer calls from its own views
#   7. the frame's crop: none by default, the app's when declared, one frame's own
#   8. an app's own booking page (config.booking_path) is treated as the engine's is
#   9. unset is the default footer, false is none, and the location is one setting
class SiteFooterTest < ActionDispatch::IntegrationTest
  ActionDispatch::IntegrationTest.app = Rails.application

  BOOKING_URL = "https://calendar.google.com/calendar/appointments/schedules/TEST-SCHEDULE"

  FACTS = {
    name: "Example Co",
    tagline: "Everything, by example",
    email: "team@example.test",
    address: { street: "123 Example St", city_line: "Washington, DC 20024", lat: 38.8894, lng: -77.0352 },
    social: [
      ["LinkedIn", :linkedin, "https://www.linkedin.com/in/someone/"],
      ["Instagram", :instagram, nil],
      ["Mastodon", :mastodon, "https://social.example/@someone"]
    ],
    columns: [
      ["Contact", [["team@example.test", "mailto:team@example.test"],
                   ["Schedule a call", "/contact", { booking: true }]]],
      ["Company", [["Home", "/"], ["Career", nil], ["Blog", "https://blog.example.test"]]]
    ],
    legal: [["Privacy Policy", "/privacy"], ["Terms of Service", "/terms"]]
  }.freeze

  SIGNED_IN = { "X-Signed-In" => "1" }.freeze

  def setup
    @saved = {
      site_footer: Studio.site_footer, booking_url: Studio.booking_url,
      site_footer_controllers: Studio.site_footer_controllers, draw_booking_routes: Studio.draw_booking_routes,
      site_title: Studio.site_title, theme_logos: Studio.theme_logos,
      site_footer_visible: Studio.site_footer_visible,
      booking_crop: Studio.booking_crop, booking_path: Studio.booking_path,
      site_footer_address: Studio.site_footer_address
    }
    Studio.site_footer_address = nil
    Studio.site_footer = FACTS
    Studio.booking_url = BOOKING_URL
    Studio.site_footer_controllers = []
    Studio.booking_crop = nil
    Studio.booking_path = nil
    Studio::SiteFooterHelper.reported = nil
    @booking_reporter = Studio::Booking.reporter
    @booking_reports = []
    Studio::Booking.reporter = ->(message) { @booking_reports << message }
    Studio::Booking.reported.clear
  end

  def teardown
    @saved.each { |key, value| Studio.public_send("#{key}=", value) }
    Rails.application.config.x.footer_host_legal = nil
    Rails.application.config.x.footer_host_legal_post = nil
    Rails.application.reload_routes!
    Studio::SiteFooterHelper.reported = nil
    Studio::Booking.reporter = @booking_reporter
    Studio::Booking.reported.clear
  end

  def draw_booking_routes!(on = true)
    Studio.draw_booking_routes = on
    Rails.application.reload_routes!
  end

  def draw_legal_routes!(*names, post_terms: false)
    Rails.application.config.x.footer_host_legal = names
    Rails.application.config.x.footer_host_legal_post = post_terms
    Rails.application.reload_routes!
  end

  def footer = "footer[data-site-footer]"

  # ---- 1. the footer prints the facts ----------------------------------------

  test "a visitor's page ends with one footer carrying every declared fact" do
    get "/footer_host/landing"

    assert_response :success
    assert_select footer, 1 do
      assert_select ".ftr-wordmark", text: /Example\s*Co/
      assert_select ".ftr-wordmark .ftr-wordmark-accent", "Co"
      assert_select ".ftr-tagline", "Everything, by example"
      assert_select ".ftr-email a[href='mailto:team@example.test']", "team@example.test"

      assert_select "address a[href*='google.com/maps/dir']", { text: /123 Example St\s*Washington, DC 20024/m, count: 1 }
      assert_select "[data-footer-map][data-lat='38.8894'][data-lng='-77.0352'][data-zoom='15']", 1
      assert_select "[data-footer-map] a.ftr-map-fallback[href*='google.com/maps']", 1

      assert_select "nav[aria-label='Company']" do
        assert_select "a", 2
        assert_select "a[href='/']:not([target])", "Home"
        assert_select "span[aria-disabled='true']", { text: "Career", count: 1 }
        assert_select "a[href='https://blog.example.test'][target='_blank'][rel='noopener']", "Blog"
      end
      assert_select "nav[aria-label='Contact'] a[href='mailto:team@example.test']:not([target])", 1

      assert_select ".ftr-legal a[href='/privacy']", "Privacy Policy"
      assert_select ".ftr-legal a[href='/terms']", "Terms of Service"
      assert_select ".ftr-copyright", "© #{Time.current.year} Example Co"
    end
  end

  test "a social profile with no url is drawn unlinked, and an unknown icon falls back to a letter" do
    get "/footer_host/landing"

    assert_select "#{footer} ul[aria-label='Social profiles']" do
      assert_select "a[href='https://www.linkedin.com/in/someone/'][aria-label='LinkedIn'][target='_blank'] svg", 1
      assert_select "span[aria-label='Instagram'][data-pending]", 1
      assert_select "a[aria-label='Instagram']", 0
      assert_select "a[aria-label='Mastodon'] .ftr-social-letter", "M"
    end
  end

  test "the map asks the asset pipeline for Leaflet, and the page loads no Leaflet tag of its own" do
    get "/footer_host/landing"

    map = css_select("[data-footer-map]").first
    assert_match(%r{studio/leaflet.*\.js\z}, map["data-leaflet-js"])
    assert_match(%r{studio/leaflet.*\.css\z}, map["data-leaflet-css"])
    assert_select "script[src*='leaflet']", 0, "Leaflet is fetched by the mount script, on demand"
    assert_select "link[href*='leaflet']", 0
    assert_no_match(%r{/vendor/leaflet}, response.body)
  end

  test "the name defaults to the site identity and the logo to the navbar logo" do
    Studio.site_footer = FACTS.except(:name)
    Studio.site_title = "Identity Title"
    Studio.theme_logos = [{ file: "nav-logo.png", title: "Navbar Logo" }]

    get "/footer_host/landing"

    assert_select "#{footer} .ftr-copyright", "© #{Time.current.year} Identity Title"
    assert_select "#{footer} a.ftr-home[aria-label='Identity Title'] img.ftr-logo[src='/nav-logo.png'][alt='']", 1
    assert_select "#{footer} .ftr-wordmark-accent", "Title"
  end

  test "an href that is not a path, http, https, mailto or tel is never written into the page" do
    saved = Studio::SiteFooter.reporter
    reports = []
    Studio::SiteFooter.reporter = ->(message) { reports << message }
    Studio::SiteFooter.reset_reported!
    Studio.site_footer = {
      name: "Example Co", home_path: "javascript:alert('home')",
      address: { street: "123 Example St", lat: 38.8894, lng: -77.0352, directions_url: "javascript:alert('directions')" },
      social: [["LinkedIn", :linkedin, "javascript:alert('social')"]],
      columns: [["Company", [["Click me", "javascript:alert('link')"], ["Data", "data:text/html,<b>x</b>"], ["Call", "tel:+15555550100"]]]],
      legal: [["Terms", "JAVASCRIPT:alert('legal')"]]
    }

    2.times { get "/footer_host/landing" }

    assert_response :success
    assert_no_match(/javascript:/i, response.body)
    assert_no_match(/data:text/, response.body)
    assert_select "#{footer} nav[aria-label='Company']" do
      assert_select "a", 1
      assert_select "a[href='tel:+15555550100']", "Call"
      assert_select "span.ftr-link-plain", "Click me"
      assert_select "span.ftr-link-plain", "Data"
      assert_select "span[aria-disabled]", 0, "a refused link is not a page that is coming soon"
    end
    assert_select "#{footer} .ftr-legal span.ftr-link-plain", "Terms"
    assert_select "#{footer} span.ftr-social[aria-label='LinkedIn'][title='LinkedIn']", 1
    assert_select "#{footer} a.ftr-home[href='/']", 1
    assert_select "#{footer} address a[href^='https://www.google.com/maps/dir/']", 1
    assert_select "[data-footer-map] a.ftr-map-fallback[href^='https://www.google.com/maps/dir/']", 1
    assert_equal 6, reports.size, "each refused href is reported once, not once per render"
  ensure
    Studio::SiteFooter.reporter = saved
    Studio::SiteFooter.reset_reported!
  end

  test "an empty footer is still a footer, with no part it was not given" do
    Studio.site_footer = { name: "Acme" }

    get "/footer_host/landing"

    assert_select footer, 1 do
      assert_select "nav", 0
      assert_select "ul[aria-label='Social profiles']", 0
      assert_select ".ftr-tagline", 0
      assert_select ".ftr-email", 0
      assert_select "[data-footer-location]", 0
      assert_select ".ftr-legal a", 0
      assert_select ".ftr-copyright", "© #{Time.current.year} Acme"
    end
  end

  test "the link columns are grid tracks, the first wider, with an optional width hint" do
    get "/footer_host/landing"

    assert_select "#{footer} .ftr-cols > nav.ftr-col", 2
    assert_select "#{footer} .ftr-cols:not(.ftr-cols-many)[style='--ftr-tracks: 1.5fr 1fr']", 1
    # fr tracks, never minmax(0, ...): a track is at least as wide as its longest
    # word, so the column holding an address grows and its neighbours give way.
    assert_includes response.body, ".ftr-cols { display: grid; gap: 3rem 2rem; padding-block: 4rem; grid-template-columns: 1.2fr 1fr; }"
    assert_includes response.body, ".ftr-cols { grid-template-columns: var(--ftr-tracks, 1fr); }"
    assert_includes response.body, ".ftr-cols:not(.ftr-cols-many) { grid-template-columns: 1.7fr var(--ftr-tracks,); }"
    assert_no_match(/\.ftr-cols[^{]*\{[^}]*minmax\(0/, response.body)
    assert_includes response.body, ".ftr-link-solid { white-space: nowrap; }"
    assert_equal 1, response.body.scan("overflow-wrap: anywhere").size, "only on a screen narrower than any phone"
    assert_includes response.body, "@media (max-width: 299px) { .ftr-link-solid { white-space: normal; overflow-wrap: anywhere; } }"
    # An address is solid; a word and a phrase are not.
    assert_select "#{footer} a.ftr-link.ftr-link-solid[href='mailto:team@example.test']", 2
    assert_select "#{footer} a.ftr-link:not(.ftr-link-solid)", text: "Privacy Policy"
    assert_select "#{footer} a.ftr-link:not(.ftr-link-solid)", text: "Home"

    Studio.site_footer = { columns: [["Contact", [["team@example.test", "mailto:team@example.test"]], { width: 2.5 }],
                                     ["Company", [["Home", "/"]]], ["Legal", [["Terms", "/terms"]]]] }
    get "/footer_host/landing"
    assert_select "#{footer} .ftr-cols[style='--ftr-tracks: 2.5fr 1fr 1fr']", 1

    Studio.site_footer = { columns: %w[A B C D E].map { |heading| [heading, [["Home", "/"]]] } }
    get "/footer_host/landing"
    assert_select "#{footer} .ftr-cols.ftr-cols-many:not([style])", 1, "five columns wrap four to a row"

    Studio.site_footer = { name: "Example Co" }
    get "/footer_host/landing"
    assert_select "#{footer} .ftr-cols:not([style]):not(.ftr-cols-many)", 1, "no columns, no tracks"
  end

  test "the footer and the booking note set their own line heights" do
    get "/footer_host/helpers"

    assert_match(/\.ftr-location-title \{[^}]*font-size: 1\.875rem; line-height: 2\.25rem;/, response.body)
    assert_match(/\.ftr-legal \{[^}]*font-size: \.875rem; line-height: 1\.25rem;/, response.body)
    assert_match(/\.booking-frame-note \{[^}]*font-size: \.875rem; line-height: 1\.25rem;/, response.body)
  end

  test "the footer's styles and script are on the page once" do
    get "/footer_host/helpers"

    assert_select "[data-footer-map]", 3, "the footer's map and two standalone maps"
    assert_equal 1, response.body.scan(".ftr-wrap {").size, "footer styles rendered more than once"
    assert_no_match(/<script\b(?![^>]*type="(?:importmap|module)")[^>]*>[^<]*__studio/, response.body,
                    "the footer's behaviour is in modules; no inline script carries it")
    # Each map and each booking surface names the controller that starts its module.
    assert_select "[data-footer-map][data-studio-controller='footer-map']", 3
    assert_select "[data-booking-wrap][data-studio-controller='booking']", 3
    assert_select "dialog[data-booking-dialog][data-studio-controller='booking']", 1
    assert_equal 1, response.body.scan(".booking-popup::backdrop").size, "booking styles rendered more than once"

    map = File.read(File.expand_path("../../app/javascript/studio/footer_map.js", __dir__))
    booking = File.read(File.expand_path("../../app/javascript/studio/booking.js", __dir__))
    assert_equal 1, map.scan("win.__studioFooterMapsArmed = true").size
    # Not the name, nor the bare selector, of an app's own local footer script:
    # sharing them lets one script stand the other down across a Turbo visit.
    assert_no_match(/\.__footerMapsArmed/, map)
    assert_includes map, 'export const MAPS = "[data-footer-map][data-leaflet-js]"'
    assert_equal 1, booking.scan("win.__studioBookingPopupArmed = true").size
    assert_equal 1, booking.scan("win.__studioBookingFramesArmed = true").size
    # Not the names, nor the bare selectors, of an app's own local booking script:
    # sharing them lets one script stand the other down across a Turbo visit, or
    # act on the other's elements.
    assert_no_match(/\.__booking(Frames|Popup)Armed/, booking)
    assert_includes booking, 'export const WAITING_FRAMES = "iframe[data-booking-frame][data-studio-booking][data-src]"'
    assert_includes booking, 'export const POPUP_LINK = "a[data-booking-popup][data-studio-booking]"'
    assert_includes booking, 'export const DIALOG = "dialog[data-booking-dialog][data-studio-booking]"'
    code = booking.gsub(%r{^\s*//.*$}, "")
    assert_empty code.scan(/"[^"\n]*\[data-booking-(?:frame|popup|dialog|wrap)\][^"\n]*"/)
                     .reject { |selector| selector.include?("data-studio-booking") },
                 "a booking selector in studio/booking is not scoped to the engine's own elements"
    # Every element those selectors need carries the marker.
    assert_select "[data-booking-wrap][data-studio-booking] iframe[data-booking-frame][data-studio-booking]", 3
    assert_select "dialog[data-booking-dialog][data-studio-booking]", 1
    assert_select "a[data-booking-popup]:not([data-studio-booking])", 0
    assert_select "a[data-booking-popup][data-studio-booking]", 4
  end

  # ---- 2. no address ----------------------------------------------------------

  test "no address: no Location band, no map and no Leaflet anywhere on the page" do
    Studio.site_footer = FACTS.except(:address)

    get "/footer_host/landing"

    assert_select footer, 1
    assert_select "[data-footer-location]", 0
    assert_select "[data-footer-map]", 0
    assert_select "address", 0
    assert_no_match(/leaflet\.(js|css)/, response.body, "a page with no map must not name Leaflet's files")
    # Nor Leaflet at all: the map's styles (.leaflet-* rules) and its mount
    # script ride studio/site_footer/_map_assets, which only a map renders.
    assert_no_match(/leaflet/i, response.body, "a page with no map must not name Leaflet")
    assert_no_match(/data-studio-controller="footer-map"/, response.body, "a page with no map must not name the map's controller")
    assert_no_match(/\.ftr-map/, response.body, "a page with no map must not ship the map's styles")
    assert_includes response.body, ".ftr-wrap {", "the footer's own styles still ship"
    assert_select "#{footer} .ftr-legal.ftr-legal-ruled", 1, "with no map above it the legal line carries the rule"
  end

  test "an address without coordinates keeps the Location band and drops the map" do
    Studio.site_footer = FACTS.merge(address: { street: "123 Example St", city_line: "Washington, DC 20024" })

    get "/footer_host/landing"

    assert_select "#{footer} [data-footer-location] address a", /123 Example St/
    assert_select "[data-footer-map]", 0
    assert_no_match(/leaflet/i, response.body)
  end

  # ---- 3. booking -------------------------------------------------------------

  test "with a booking_url the footer carries one popup, its frame not yet requested" do
    get "/footer_host/landing"

    assert_select "dialog[data-booking-dialog][aria-label='Schedule a call']", 1
    assert_select "dialog[data-booking-dialog] iframe[data-booking-popup-frame]", 1 do |frames|
      assert_equal "#{BOOKING_URL}?gv=true", frames.first["data-src"]
      assert_nil frames.first["src"], "the frame must not load before the dialog opens"
      assert_equal "Schedule a call with Example Co", frames.first["title"]
    end
    assert_select "dialog[data-booking-dialog] form[method='dialog'] button[type='submit'][data-booking-close]", "Close ✕"
    assert_match(/html:has\(dialog\[data-booking-dialog\]\[open\]\) \{ overflow: hidden; \}/, response.body,
                 "the page behind the open dialog must not scroll")
    assert_match(/height: min\(800px, calc\(100vh - 3rem\)\); height: min\(800px, calc\(100dvh - 3rem\)\);/, response.body,
                 "the popup is sized in dvh (a phone's toolbar-aware height), with vh before it as the fallback")
    assert_select "#{footer} a[href='/contact'][data-booking-popup]", { text: "Schedule a call", count: 1 }
    assert_select "#{footer} a[data-booking-popup]", 1, "only the booking link opens the popup"
  end

  test "with no booking_url there is no popup, and the booking link is an ordinary link" do
    Studio.booking_url = nil

    get "/footer_host/landing"

    assert_select footer, 1
    assert_select "dialog[data-booking-dialog]", 0
    assert_select "[data-booking-popup]", 0
    assert_select "#{footer} a[href='/contact']", "Schedule a call"
    assert_no_match(/calendar\.google\.com/, response.body)
    assert_no_match(/BookingPopupArmed/, response.body, "no booking script without a booking_url")
  end

  test "the popup's label and frame title come from the facts' booking copy" do
    Studio.site_footer = FACTS.merge(booking: { label: "Book a call", title: "Book a call with Sam" })

    get "/footer_host/landing"

    assert_select "dialog[data-booking-dialog][aria-label='Book a call'] .booking-popup-title", "Book a call"
    assert_select "iframe[data-booking-popup-frame][title='Book a call with Sam']", 1
  end

  test "booking_url accepts a link pasted with gv=true, and refuses one that is not https" do
    Studio.booking_url = "#{BOOKING_URL}?gv=true"
    assert_equal BOOKING_URL, Studio.booking_url

    assert_raises(ArgumentError) { Studio.booking_url = "calendar.google.com/x" }
    assert_equal BOOKING_URL, Studio.booking_url, "a refused value leaves the old one in place"

    Studio.booking_url = ""
    assert_nil Studio.booking_url
  end

  # ---- 4. where it shows ------------------------------------------------------

  # ---- 9. the default footer, the opt-out, the one-setting location ------------

  test "an app that sets nothing gets the default footer: its name and logo, and no location" do
    Studio.site_footer = nil
    Studio.booking_url = nil
    Studio.site_title = "Default Co"
    Studio.theme_logos = [{ file: "nav-logo.png", title: "Navbar Logo" }]

    get "/footer_host/landing"

    assert_response :success
    assert_select "h1", "Landing"
    assert_select footer, 1 do
      assert_select "a.ftr-home[href='/'][aria-label='Default Co'] img.ftr-logo[src='/nav-logo.png']", 1
      assert_select ".ftr-wordmark", text: /Default\s*Co/
      assert_select ".ftr-copyright", "© #{Time.current.year} Default Co"
      assert_select "nav.ftr-col", 0, "no link columns: the engine guesses no links"
      assert_select "a", 1, "the only link is the brand's own, to the home page"
      assert_select ".ftr-tagline", 0
      assert_select ".ftr-email", 0
      assert_select ".ftr-socials", 0
    end
    assert_select "[data-footer-location]", 0
    assert_select "[data-footer-map]", 0
    assert_select "address", 0
    assert_no_match(/leaflet/i, response.body, "the default footer has no map, so it must not name Leaflet")
    assert_no_match(/mailto:|tel:/, response.body, "no email and no phone by default")
    assert_select "dialog[data-booking-dialog]", 0
  end

  test "the default footer keeps the rule for where it shows" do
    Studio.site_footer = nil

    get "/footer_host/board", headers: SIGNED_IN
    assert_select footer, 0, "a signed-in working surface keeps no footer"

    Studio.site_footer_controllers = %w[footer_host_board]
    get "/footer_host/board", headers: SIGNED_IN
    assert_select footer, 1
  end

  test "config.site_footer = false is the opt-out: no footer, and the layout line is safe" do
    Studio.site_footer = false
    Studio.site_footer_address = { street: "9 Setting Rd", city_line: "Denver, CO 80202", lat: 39.7392, lng: -104.9903 }

    get "/footer_host/landing"

    assert_response :success
    assert_select footer, 0
    assert_select "[data-footer-map]", 0
    assert_select "dialog[data-booking-dialog]", 0
    assert_select "h1", "Landing"
    refute Studio.site_footer_enabled?
    refute Studio.site_footer_declared?

    Studio.site_footer = nil
    assert Studio.site_footer_enabled?, "unset is not off"
    refute Studio.site_footer_declared?
  end

  test "a callable that answers nil still declines the footer for that request" do
    Studio.site_footer = ->(_view) {}

    get "/footer_host/landing"

    assert_response :success
    assert_select footer, 0
  end

  test "one setting gives the default footer its Location band and its map" do
    Studio.site_footer = nil
    Studio.site_title = "Default Co"
    Studio.site_footer_address = { street: "9 Setting Rd", city_line: "Denver, CO 80202", lat: 39.7392, lng: -104.9903 }

    get "/footer_host/landing"

    assert_select footer, 1 do
      assert_select "[data-footer-location] address a[href*='google.com/maps/dir']",
                    { text: /9 Setting Rd\s*Denver, CO 80202/m, count: 1 }
      assert_select "[data-footer-map][data-lat='39.7392'][data-lng='-104.9903'][data-zoom='15']", 1
      assert_select ".ftr-copyright", "© #{Time.current.year} Default Co"
      assert_select "nav.ftr-col", 0
    end
    assert_match(/leaflet/i, response.body)

    Studio.site_footer_address = { street: "9 Setting Rd", city_line: "Denver, CO 80202" }
    get "/footer_host/landing"
    assert_select "[data-footer-location]", 1
    assert_select "[data-footer-map]", 0, "no coordinates: the band without the map"
  end

  test "an app's own facts are unchanged by the setting when they carry an address, and theirs wins" do
    get "/footer_host/landing"
    before = response.body

    Studio.site_footer_address = { street: "9 Setting Rd", city_line: "Denver, CO 80202", lat: 39.7392, lng: -104.9903 }
    get "/footer_host/landing"

    assert_equal before, response.body, "the page is byte for byte what it was without the setting"
    assert_select "address a", { text: /123 Example St/, count: 1 }
    assert_select "[data-footer-map][data-lat='38.8894']", 1
    assert_no_match(/Setting Rd/, response.body)

    Studio.site_footer = ->(_view) { FACTS.except(:address) }
    get "/footer_host/landing"
    assert_select "address a", { text: /9 Setting Rd/, count: 1 }, "own facts with no address take the setting"
    assert_select "nav[aria-label='Company']", 1, "and keep everything else they declared"

    Studio.site_footer = FACTS.merge(address: false)
    get "/footer_host/landing"
    assert_select "[data-footer-location]", 0, "address: false in the app's facts refuses the setting"
  end

  test "the default legal line links the host's privacy and terms routes, and only those it has" do
    Studio.site_footer = nil

    get "/footer_host/landing"
    assert_select "#{footer} .ftr-legal a", 0, "a host with no legal routes gets no legal links"
    assert_select "#{footer} .ftr-copyright", 1

    draw_legal_routes!(:privacy)
    get "/footer_host/landing"
    assert_select "#{footer} .ftr-legal a", 1
    assert_select "#{footer} .ftr-legal a[href='/footer_host/privacy']", "Privacy Policy"
    get "/footer_host/privacy"
    assert_response :success, "the link the footer printed leads to a page"

    draw_legal_routes!(:privacy, :terms)
    get "/footer_host/landing"
    assert_select "#{footer} .ftr-legal a", 2
    assert_select "#{footer} .ftr-legal a[href='/footer_host/terms']", "Terms of Service"
  end

  test "a route named terms that a visitor cannot open is not linked" do
    Studio.site_footer = nil
    draw_legal_routes!(:privacy, post_terms: true)

    get "/footer_host/landing"

    assert_select "#{footer} .ftr-legal a", 1
    assert_select "#{footer} .ftr-legal a[href='/footer_host/privacy']", 1
    assert_no_match(/Terms of Service/, response.body)
  end

  test "the address setting is refused at assignment unless it is a Hash" do
    assert_raises(ArgumentError) { Studio.site_footer_address = "9 Setting Rd" }
    assert_nil Studio.site_footer_address, "a refused value leaves the old one in place"

    Studio.site_footer_address = false
    assert_nil Studio.site_footer_address
  end

  test "a signed-in viewer keeps the footer on listed controllers and loses it on working ones" do
    Studio.site_footer_controllers = %w[footer_host_landing]

    get "/footer_host/landing", headers: SIGNED_IN
    assert_response :success
    assert_select footer, 1

    get "/footer_host/board", headers: SIGNED_IN
    assert_response :success
    assert_select "h1", "Board"
    assert_select footer, 0
    assert_select "dialog[data-booking-dialog]", 0, "no footer, so no popup either"
  end

  test "with no controllers listed a signed-in viewer sees no footer at all" do
    get "/footer_host/landing", headers: SIGNED_IN

    assert_select "h1", "Landing"
    assert_select footer, 0
  end

  test "site_footer_visible replaces the rule, so an app can narrow where a visitor sees the footer" do
    Studio.site_footer_visible = lambda do |view|
      Studio::SiteFooter.default_visible?(view) && view.controller_name != "footer_host_landing"
    end

    get "/footer_host/landing"

    assert_response :success
    assert_select "h1", "Landing"
    assert_select footer, 0, "the narrowed rule hides it from a visitor on this controller"
    assert_select "dialog[data-booking-dialog]", 0

    draw_booking_routes!
    get "/schedule"
    assert_select footer, 1, "and the default still answers everywhere else"
  end

  test "the default rule is a callable an app can read back and compose with" do
    assert_respond_to Studio.site_footer_visible, :call
    assert_raises(ArgumentError) { Studio.site_footer_visible = %w[landing] }
    assert_respond_to Studio.site_footer_visible, :call, "a refused value leaves the old rule in place"
  end

  test "assigning something that is not facts is refused when it is assigned" do
    assert_raises(ArgumentError) { Studio.site_footer = "Example Co" }
    assert_equal FACTS, Studio.site_footer
  end

  test "a callable that raises is loud locally" do
    Studio.site_footer = ->(_view) { raise "footer facts exploded" }

    controller = FooterHostLandingController.new
    controller.request = ActionDispatch::TestRequest.create

    error = assert_raises(RuntimeError) { controller.view_context.studio_site_footer }
    assert_equal "footer facts exploded", error.message
  end

  test "a callable that raises in production costs the footer, not the page, and is reported once" do
    Studio.site_footer = ->(_view) { raise "footer facts exploded" }
    controller = FooterHostLandingController.new
    controller.request = ActionDispatch::TestRequest.create
    reports = []
    capture = ->(error) { reports << error.message }

    2.times do
      view = controller.view_context
      view.define_singleton_method(:studio_site_footer_raise?) { false }
      view.define_singleton_method(:studio_site_footer_report) do |error|
        next if Studio::SiteFooterHelper.reported

        Studio::SiteFooterHelper.reported = true
        capture.call(error)
      end

      assert_nil view.studio_site_footer_facts
      assert_equal false, view.studio_show_site_footer?
      assert_nil view.studio_site_footer
    end
    assert_equal ["footer facts exploded"], reports
  end

  # ---- 5. the booking page ----------------------------------------------------

  test "the booking page is not drawn until the app opts in" do
    draw_booking_routes!(false)

    assert_raises(ActionController::RoutingError) { get "/schedule" }
  end

  test "the booking page is public and carries the deferred frame and the footer" do
    draw_booking_routes!

    get "/schedule"

    assert_response :success
    assert_select "title", "Schedule a call · Example Co"
    assert_select "[data-booking-page] h1", "Schedule a call"
    assert_select "[data-booking-wrap]:not(.booking-frame-cropped) iframe[data-booking-frame]", 1 do |frames|
      assert_equal "#{BOOKING_URL}?gv=true", frames.first["data-src"]
      assert_nil frames.first["src"], "studio/booking assigns src after `load`"
    end
    assert_select "a[href='#{BOOKING_URL}'][target='_blank']", "Open the booking page"
    assert_select footer, 1
  end

  test "with scripts off the frame's place is taken by a plain link to the booking page" do
    draw_booking_routes!

    get "/schedule"

    noscript = response.body[%r{<div class="booking-frame[^>]*data-booking-wrap data-studio-booking data-studio-controller="booking">.*?<noscript>(.*?)</noscript>}m, 1]
    assert noscript, "the frame's wrapper must carry a <noscript>"
    assert_match(%r{<a href="#{Regexp.escape(BOOKING_URL)}"[^>]*>Open the booking page to pick a time</a>}, noscript)
    assert_match(/\.booking-frame iframe \{ display: none !important; \}/, noscript,
                 "the frame that will never load must not be left as an empty box")
  end

  test "the booking page keeps the footer for a signed-in viewer without being listed" do
    draw_booking_routes!

    get "/schedule", headers: SIGNED_IN

    assert_response :success
    assert_select footer, 1
  end

  test "the booking page answers 404 when there is nothing to book" do
    draw_booking_routes!
    Studio.booking_url = nil

    get "/schedule"

    assert_response :not_found
  end

  test "a footer link to the drawn booking page opens the popup without being told to" do
    draw_booking_routes!
    Studio.site_footer = { columns: [["Contact", [["Schedule a call", "/schedule"], ["Contact", "/contact"]]]] }

    get "/footer_host/landing"

    assert_select "#{footer} a[href='/schedule'][data-booking-popup]", 1
    assert_select "#{footer} a[href='/contact']:not([data-booking-popup])", 1
  end

  # ---- 6. the helpers ---------------------------------------------------------

  test "studio_booking_link falls back to Google's page, or to the booking page once drawn" do
    get "/footer_host/helpers"

    assert_select "[data-own-links] a[data-booking-popup]", 3
    assert_select "[data-own-links] a[href='#{BOOKING_URL}']", "Schedule a call"
    assert_select "[data-own-links] a.btn[href='#{BOOKING_URL}']", "Book a call"
    assert_select "[data-own-links] a.btn[href='/contact']", "Talk to us"

    draw_booking_routes!
    get "/footer_host/helpers"

    assert_select "[data-own-links] a[href='/schedule'][data-booking-popup]", 2
  end

  test "studio_booking_link without a booking_url keeps only the link that has somewhere to go" do
    Studio.booking_url = nil

    get "/footer_host/helpers"

    assert_select "[data-own-links] a", 1
    assert_select "[data-own-links] a[href='/contact']:not([data-booking-popup])", "Talk to us"
    assert_select "iframe[data-booking-frame]", 0, "no frame without a booking_url"
  end

  test "studio_footer_map maps the footer's address, or another one" do
    get "/footer_host/helpers"

    assert_select "main [data-footer-map].contact-map[style='height: 20rem'][data-zoom='12'][data-controls='false']" \
                  "[data-lat='38.8894']", 1
    assert_select "main [data-footer-map][data-lat='1.5'][data-lng='2.5'][aria-label='Map of 1 Main St, Town, ST']", 1
  end

  test "studio_booking_frame can be titled, and the popup renders once" do
    get "/footer_host/helpers"

    assert_select "main [data-booking-wrap]", 3
    assert_select "main iframe[data-booking-frame][title='Second frame']", 1
    assert_select "dialog[data-booking-dialog]", 1, "asked for by the page and by the footer, rendered once"
  end

  # ---- 7. the crop ------------------------------------------------------------

  CROP = { top: 200, bottom: 600, frame_height: 720 }.freeze
  CROP_STYLE = "--booking-crop-offset: 194px; --booking-crop-window: 412px; --booking-frame-height: 720px"
  ONE_OFF_STYLE = "--booking-crop-offset: 144px; --booking-crop-window: 342px; --booking-frame-height: 640px"

  def frame_wrap(name) = "main [data-frame='#{name}'] [data-booking-wrap]"

  test "with no crop declared a frame shows whole, and carries no crop of any schedule" do
    get "/footer_host/helpers"

    assert_response :success
    assert_select frame_wrap("config"), 1
    assert_select "#{frame_wrap('config')}.booking-frame-cropped", 0
    assert_select "#{frame_wrap('config')}[style]", 0
    assert_select "#{frame_wrap('config')}[data-booking-crop]", 0
    assert_no_match(/414px|205px/, response.body, "the 0.83.0 crop was one schedule's and is no longer a default")
    assert_empty @booking_reports
  end

  test "a declared crop renders the measured window on the frame's own wrapper" do
    Studio.booking_crop = CROP

    get "/footer_host/helpers"

    assert_select "#{frame_wrap('config')}.booking-frame-cropped[data-booking-crop]", 1 do |wraps|
      assert_equal CROP_STYLE, wraps.first["style"]
    end
    # The stylesheet reads those properties; it names no schedule's numbers.
    assert_includes response.body, ".booking-frame-cropped { height: var(--booking-crop-window);"
    assert_includes response.body, "margin-top: calc(-1 * var(--booking-crop-offset));"
    assert_includes response.body, ".booking-frame-cropped.is-open { height: var(--booking-frame-height, 732px); }"
    assert_empty @booking_reports
  end

  test "crop: false shows one frame whole whatever the app declares" do
    Studio.booking_crop = CROP

    get "/footer_host/helpers"

    assert_select "#{frame_wrap('whole')}:not(.booking-frame-cropped):not([style]):not([data-booking-crop])", 1
  end

  test "a Hash on the call crops that frame alone, with or without an app crop" do
    get "/footer_host/helpers"
    assert_select "#{frame_wrap('one-off')}.booking-frame-cropped", 1 do |wraps|
      assert_equal ONE_OFF_STYLE, wraps.first["style"]
    end
    assert_select "main .booking-frame-cropped", 1, "the other two frames are whole"

    Studio.booking_crop = CROP
    get "/footer_host/helpers"
    assert_select "#{frame_wrap('one-off')}.booking-frame-cropped", 1 do |wraps|
      assert_equal ONE_OFF_STYLE, wraps.first["style"], "the call's own crop wins over the app's"
    end
    assert_select "#{frame_wrap('config')}.booking-frame-cropped[style='#{CROP_STYLE}']", 1,
                  "and two crops share the page, each on its own wrapper"
  end

  test "the engine's booking page honours the app's crop" do
    draw_booking_routes!

    get "/schedule"
    assert_select "[data-booking-page] [data-booking-wrap]", 1
    assert_select "[data-booking-page] .booking-frame-cropped", 0

    Studio.booking_crop = CROP
    get "/schedule"
    assert_select "[data-booking-page] [data-booking-wrap].booking-frame-cropped[style='#{CROP_STYLE}']", 1
  end

  test "the popup is never cropped" do
    Studio.booking_crop = CROP

    get "/footer_host/landing"

    assert_select "dialog[data-booking-dialog]", 1
    assert_select "dialog[data-booking-dialog] iframe[data-booking-popup-frame]:not([style])", 1
    assert_select "dialog[data-booking-dialog][style], dialog[data-booking-dialog] [data-booking-crop]", 0
    assert_select ".booking-frame-cropped", 0, "this page has a popup and no inline frame"
  end

  test "a crop that cannot be one shows the frame whole and is reported once" do
    Studio.booking_crop = { top: 600, bottom: 200, frame_height: 720 }
    assert_equal 1, @booking_reports.size, "reported when it is assigned, which is boot"

    2.times { get "/footer_host/helpers" }

    assert_response :success
    assert_select "#{frame_wrap('config')}:not(.booking-frame-cropped):not([style])", 1
    assert_select "#{frame_wrap('one-off')}.booking-frame-cropped", 1, "a sound one-off on the same page still crops"
    assert_equal 1, @booking_reports.size, "and not again on any render"
    assert_match(/\[studio\.booking\] booking crop .* is ignored \(bottom is not below top\); the frame shows whole/,
                 @booking_reports.first)
  end

  test "booking_crop takes a Hash, nil or false, and refuses anything else when it is assigned" do
    Studio.booking_crop = CROP
    assert_equal CROP, Studio.booking_crop

    [true, "200-600", [200, 600, 720], 414].each do |bad|
      error = assert_raises(ArgumentError, bad.inspect) { Studio.booking_crop = bad }
      assert_match(/top:, bottom: and frame_height:/, error.message)
    end
    assert_equal CROP, Studio.booking_crop, "a refused value leaves the old one in place"

    Studio.booking_crop = false
    assert_nil Studio.booking_crop
  end

  # ---- 8. an app's own booking page -------------------------------------------

  OWN_PAGE = "/footer_host/schedule"

  test "with neither booking_path nor the engine's route, the app's page is an ordinary page" do
    Studio.site_footer = { columns: [["Contact", [["Schedule a call", OWN_PAGE]]]] }

    get "/footer_host/helpers"
    assert_select "#{footer} a[href='#{OWN_PAGE}']:not([data-booking-popup])", 1
    assert_select "[data-own-links] a[href='#{BOOKING_URL}']", "Schedule a call"

    get OWN_PAGE, headers: SIGNED_IN
    assert_select "h1", "Book a time"
    assert_select footer, 0, "a signed-in viewer's unlisted page keeps no footer"
  end

  test "booking_path makes a footer link to the app's page open the popup without being told to" do
    Studio.booking_path = OWN_PAGE
    Studio.site_footer = { columns: [["Contact", [["Schedule a call", OWN_PAGE], ["Contact", "/contact"]]]] }

    get "/footer_host/landing"

    assert_select "#{footer} a[href='#{OWN_PAGE}'][data-booking-popup][data-studio-booking]", 1
    assert_select "#{footer} a[href='/contact']:not([data-booking-popup])", 1
  end

  test "booking_path is where studio_booking_link falls back to" do
    Studio.booking_path = OWN_PAGE

    get "/footer_host/helpers"

    assert_select "[data-own-links] a[href='#{OWN_PAGE}'][data-booking-popup]", 2
    assert_select "[data-own-links] a.btn[href='/contact']", "Talk to us"
    assert_select "[data-own-links] a[href='#{BOOKING_URL}']", 0
  end

  test "booking_path keeps the footer on the app's page for a signed-in viewer, and only there" do
    Studio.booking_path = OWN_PAGE

    get OWN_PAGE, headers: SIGNED_IN
    assert_response :success
    assert_select "h1", "Book a time"
    assert_select footer, 1

    get "/footer_host/board", headers: SIGNED_IN
    assert_select footer, 0, "a working surface is still a working surface"
  end

  test "booking_path may be a callable that receives the view" do
    seen = []
    Studio.booking_path = lambda do |view|
      seen << view.controller_name
      view.url_for(controller: "/footer_host_schedule", action: "show", only_path: true)
    end
    Studio.site_footer = { columns: [["Contact", [["Schedule a call", OWN_PAGE]]]] }

    get "/footer_host/helpers", headers: SIGNED_IN
    assert_select "[data-own-links] a[href='#{OWN_PAGE}'][data-booking-popup]", 2
    assert_includes seen, "footer_host_landing"

    get OWN_PAGE, headers: SIGNED_IN
    assert_select footer, 1
    assert_select "#{footer} a[href='#{OWN_PAGE}'][data-booking-popup]", 1
  end

  test "the app's own page renders the frame with the app's crop and nothing special" do
    Studio.booking_path = OWN_PAGE
    Studio.booking_crop = CROP

    get OWN_PAGE

    assert_response :success
    assert_select "main [data-booking-wrap].booking-frame-cropped[style='#{CROP_STYLE}'] iframe[data-booking-frame]", 1 do |frames|
      assert_equal "#{BOOKING_URL}?gv=true", frames.first["data-src"]
    end
    assert_select footer, 1
  end

  test "a booking_path callable that returns a script or another host is never written into an href" do
    Studio.site_footer = { columns: [["Contact", [["Schedule a call", OWN_PAGE]]]] }

    ["javascript:alert(1)", "//evil.example/schedule"].each do |bad|
      Studio.booking_path = ->(_view) { bad }

      get "/footer_host/helpers"
      assert_response :success
      assert_no_match(/javascript:alert|evil\.example/, response.body, "#{bad} reached the page")
      assert_select "[data-own-links] a[href='#{BOOKING_URL}']", "Schedule a call"
      assert_select "#{footer} a[href='#{OWN_PAGE}']:not([data-booking-popup])", 1, "nor does it name the booking page"
    end
    assert_equal 2, @booking_reports.size, "each refused value is reported once"

    assert_raises(ArgumentError) { Studio.booking_path = "//evil.example/schedule" }
    assert_raises(ArgumentError) { Studio.booking_path = "javascript:alert(1)" }
  end

  test "booking_path wins over the engine's page, and is refused unless it is a path or a callable" do
    draw_booking_routes!
    Studio.booking_path = OWN_PAGE

    get "/footer_host/helpers"
    assert_select "[data-own-links] a[href='#{OWN_PAGE}'][data-booking-popup]", 2
    get "/schedule", headers: SIGNED_IN
    assert_select footer, 1, "the engine's own page keeps its exemption"

    assert_raises(ArgumentError) { Studio.booking_path = "footer_host/schedule" }
    assert_equal OWN_PAGE, Studio.booking_path, "a refused value leaves the old one in place"
    Studio.booking_path = " "
    assert_nil Studio.booking_path
  end
end
