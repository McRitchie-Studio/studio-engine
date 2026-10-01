# frozen_string_literal: true

require "test_helper"

# [unit] Studio::SiteFooter and Studio::Booking: the pure rules behind
# config.site_footer and config.booking_url. Rendering is
# test/integration/site_footer_test.rb; the scripts are the browser lane.
class SiteFooterTest < Minitest::Test
  View = Struct.new(:root_path)

  FULL = {
    name: "McRitchie Studio",
    tagline: "Software & Marketing Solutions",
    email: "team@example.com",
    address: { street: "3000 Lawrence St", city_line: "Denver, CO 80205", lat: 39.7614786, lng: "-104.978957" },
    social: [["LinkedIn", :linkedin, "https://www.linkedin.com/in/someone/"], ["Instagram", :instagram, nil]],
    columns: [["Company", [["Home", "/"], ["Career", nil], ["Blog", "https://blog.example.com"]]]],
    legal: [["Privacy Policy", "/privacy"]]
  }.freeze

  def resolve(declared, **options) = Studio::SiteFooter.resolve(declared, View.new("/"), **options)

  # ---- declared value ---------------------------------------------------------

  def test_nil_means_no_footer
    assert_nil resolve(nil)
    assert_nil resolve(->(_view) { nil }), "a callable may decline per request"
  end

  def test_a_callable_receives_the_view
    facts = resolve(->(view) { { columns: [["Site", [["Home", view.root_path]]]] } })

    assert_equal "/", facts[:columns][0][:links][0][:href]
  end

  def test_validate_accepts_nil_a_hash_and_a_callable_and_refuses_anything_else
    [nil, {}, ->(_view) { {} }].each { |ok| assert_nil Studio::SiteFooter.validate!(ok) }

    error = assert_raises(ArgumentError) { Studio::SiteFooter.validate!("McRitchie Studio") }
    assert_match(/Hash, or a callable/, error.message)
    assert_raises(ArgumentError) { Studio::SiteFooter.validate!([]) }
  end

  # ---- every part is optional -------------------------------------------------

  def test_an_empty_hash_resolves_to_a_footer_with_no_parts
    facts = resolve({})

    assert_nil facts[:address]
    assert_nil facts[:tagline]
    assert_nil facts[:email]
    assert_nil facts[:logo]
    assert_nil facts[:wordmark]
    assert_equal [], facts[:social]
    assert_equal [], facts[:columns]
    assert_equal [], facts[:legal]
    assert_equal "/", facts[:home_path]
    assert_equal "Schedule a call", facts[:booking_label]
  end

  def test_string_keys_and_blank_values_are_tolerated
    facts = resolve({ "tagline" => "  Built here  ", "email" => "", "name" => "Acme" })

    assert_equal "Built here", facts[:tagline]
    assert_nil facts[:email]
    assert_equal "Acme", facts[:name]
  end

  # ---- name, wordmark and logo: the engine's own sources are the default -------

  def test_name_and_logo_default_to_what_the_engine_resolved
    facts = resolve({}, name: "Site Identity Title", logo: "/navbar-logo.png")

    assert_equal "Site Identity Title", facts[:name]
    assert_equal "/navbar-logo.png", facts[:logo]
    assert_equal ["Site Identity", "Title"], facts[:wordmark]
  end

  def test_declared_name_and_logo_win_and_logo_false_removes_it
    facts = resolve({ name: "Acme", logo: "mark.svg", logo_invert: true }, name: "Other", logo: "/nav.png")

    assert_equal "Acme", facts[:name]
    assert_equal "mark.svg", facts[:logo]
    assert_equal true, facts[:logo_invert]
    assert_equal ["", "Acme"], facts[:wordmark], "a one-word name has no first part"
    assert_nil resolve({ logo: false }, logo: "/nav.png")[:logo]
    assert_nil resolve({ logo: nil }, logo: "/nav.png")[:logo]
  end

  def test_a_declared_wordmark_is_taken_as_its_two_parts
    assert_equal ["McRitchie", "Studio"], resolve({ wordmark: %w[McRitchie Studio] })[:wordmark]
    assert_equal ["Big Blue", "Co"], resolve({ wordmark: "Big Blue Co" })[:wordmark]
  end

  # ---- address ----------------------------------------------------------------

  def test_no_address_means_no_address
    assert_nil resolve(FULL.reject { |key, _| key == :address })[:address]
    assert_nil resolve({ address: { lat: 1.0, lng: 2.0 } })[:address], "coordinates alone are not an address"
  end

  def test_an_address_with_coordinates_has_a_map_and_default_directions
    address = resolve(FULL)[:address]

    assert_equal "3000 Lawrence St, Denver, CO 80205", address[:full]
    assert_equal true, address[:map]
    assert_in_delta 39.7614786, address[:lat]
    assert_in_delta(-104.978957, address[:lng], 1e-9, "a string coordinate is read as a number")
    assert_equal 15, address[:zoom]
    assert_equal "https://www.google.com/maps/dir/?api=1&destination=3000+Lawrence+St%2C+Denver%2C+CO+80205",
                 address[:directions_url]
  end

  def test_an_address_without_coordinates_has_no_map
    address = resolve({ address: { street: "1 Main St", city_line: "Town, ST" } })[:address]

    assert_equal false, address[:map]
    assert_nil address[:lat]
    refute resolve({ address: { street: "1 Main St", lat: "north", lng: 2 } })[:address][:map],
           "a coordinate that is not a number is no coordinate"
    refute resolve({ address: { street: "1 Main St", lat: 1 } })[:address][:map], "one coordinate is not two"
  end

  def test_the_address_may_be_written_flat_and_carry_its_own_directions
    address = resolve({ street: "1 Main St", lat: 1, lng: 2, zoom: 12, directions_url: "https://maps.example/x" })[:address]

    assert_equal "1 Main St", address[:full]
    assert_equal true, address[:map]
    assert_equal 12, address[:zoom]
    assert_equal "https://maps.example/x", address[:directions_url]
  end

  # ---- rows -------------------------------------------------------------------

  def test_social_rows_keep_a_nil_url_as_unlinked
    social = resolve(FULL)[:social]

    assert_equal({ label: "LinkedIn", icon: :linkedin, url: "https://www.linkedin.com/in/someone/" }, social[0])
    assert_equal({ label: "Instagram", icon: :instagram, url: nil }, social[1])
  end

  def test_social_rows_may_be_hashes_and_the_icon_defaults_to_the_label
    social = resolve({ social: [{ "label" => "YouTube", "url" => "https://youtube.com/@x" }, [nil, :x, "https://x.com"]] })[:social]

    assert_equal [{ label: "YouTube", icon: :youtube, url: "https://youtube.com/@x" }], social,
                 "a row with no label is dropped"
  end

  def test_links_disabled_external_and_internal
    home, career, blog = resolve(FULL)[:columns][0][:links]

    assert_equal({ label: "Home", href: "/", disabled: false, external: false, booking: false }, home)
    assert_equal({ label: "Career", href: nil, disabled: true, external: false, booking: false }, career)
    assert_equal({ label: "Blog", href: "https://blog.example.com", disabled: false, external: true, booking: false }, blog)
  end

  def test_a_mailto_link_is_not_external
    link = Studio::SiteFooter.link(["team@example.com", "mailto:team@example.com"])

    assert_equal false, link[:external]
  end

  def test_a_booking_link_is_flagged_by_option_or_by_the_booking_page_path
    by_option = Studio::SiteFooter.link(["Schedule a call", "/contact", { booking: true }])
    by_hash = Studio::SiteFooter.link({ label: "Schedule a call", href: "/contact", booking: true })
    by_path = Studio::SiteFooter.link(["Schedule a call", "/schedule"], "/schedule")
    other = Studio::SiteFooter.link(["Contact", "/contact"], "/schedule")
    disabled = Studio::SiteFooter.link(["Schedule a call", nil, { booking: true }])

    assert by_option[:booking]
    assert by_hash[:booking]
    assert by_path[:booking]
    refute other[:booking]
    refute disabled[:booking], "a link with nowhere to go opens nothing"
  end

  def test_columns_may_be_hashes_and_an_empty_column_is_dropped
    columns = resolve({ columns: [{ heading: "Site", links: [{ label: "Home", href: "/" }] }, [nil, []], ["Empty", []]] })[:columns]

    assert_equal ["Site", "Empty"], columns.map { |column| column[:heading] }
    assert_equal "/", columns[0][:links][0][:href]
  end

  def test_booking_copy_is_declared_under_booking
    facts = resolve({ booking: { label: "Book a call", title: "Book a call with Alex" } })

    assert_equal "Book a call", facts[:booking_label]
    assert_equal "Book a call with Alex", facts[:booking_title]
  end

  # ---- where it shows ---------------------------------------------------------

  def test_a_visitor_always_sees_the_footer
    assert Studio::SiteFooter.visible?(logged_in: false, controller_name: "tasks", controllers: [])
  end

  def test_a_signed_in_viewer_sees_it_only_on_listed_controllers
    listed = %w[landing admin/reports]

    assert Studio::SiteFooter.visible?(logged_in: true, controller_name: "landing", controller_path: "landing", controllers: listed)
    refute Studio::SiteFooter.visible?(logged_in: true, controller_name: "tasks", controller_path: "tasks", controllers: listed)
    assert Studio::SiteFooter.visible?(logged_in: true, controller_name: "reports", controller_path: "admin/reports", controllers: listed),
           "a namespaced controller is listed by its path"
    refute Studio::SiteFooter.visible?(logged_in: true, controller_name: "reports", controller_path: "public/reports", controllers: listed)
    assert Studio::SiteFooter.visible?(logged_in: true, controller_name: "landing", controllers: [:landing]), "symbols are fine"
    refute Studio::SiteFooter.visible?(logged_in: true, controller_name: "landing", controllers: nil)
  end
end

class BookingUrlTest < Minitest::Test
  URL = "https://calendar.google.com/calendar/appointments/schedules/AcZss"

  def test_unset_is_nil_everywhere
    [nil, "", "  "].each do |blank|
      assert_nil Studio::Booking.page_url(blank)
      assert_nil Studio::Booking.embed_url(blank)
      assert_nil Studio::Booking.validate!(blank)
    end
  end

  def test_the_embed_url_adds_gv_true_and_the_page_url_does_not
    assert_equal URL, Studio::Booking.page_url(URL)
    assert_equal "#{URL}?gv=true", Studio::Booking.embed_url(URL)
  end

  def test_a_url_pasted_with_gv_true_is_not_doubled
    assert_equal URL, Studio::Booking.page_url("#{URL}?gv=true")
    assert_equal "#{URL}?gv=true", Studio::Booking.embed_url("#{URL}?gv=true")
  end

  def test_other_query_parameters_survive
    assert_equal "#{URL}?hl=en", Studio::Booking.page_url("#{URL}?gv=true&hl=en")
    assert_equal "#{URL}?hl=en&gv=true", Studio::Booking.embed_url("#{URL}?hl=en")
  end

  def test_only_https_is_accepted
    assert_nil Studio::Booking.validate!(URL)
    ["http://calendar.google.com/x", "calendar.google.com/x", "javascript:alert(1)", "https://a b"].each do |bad|
      assert_raises(ArgumentError, bad) { Studio::Booking.validate!(bad) }
    end
  end
end
