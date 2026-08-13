# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/studio/ip_locations"

# [unit] Studio::IpLocations — the shape, dedupe rule and growth cap for
# users.ip_locations, the jsonb array recording where an account has been seen
# from.
#
# Pure by design (array in, array out), so the rules that must be identical in
# every Studio app are tested without a database, a clock, or a geo lookup.
#
# The properties that matter:
#   1. A place is recorded ONCE, however many addresses it arrives from.
#   2. The array cannot grow without bound — it is loaded with every user row.
#   3. It round-trips through jsonb: string keys, ISO-8601 times.
#   4. Junk in (loopback, blanks, symbol keys, pre-existing rows) does not
#      corrupt the record or start duplicating what is already there.
class IpLocationsTest < Minitest::Test
  IP = Studio::IpLocations

  def entry(overrides = {})
    { "ip" => "203.0.113.7", "country" => "US", "region" => "TX", "city" => "Austin" }
      .merge(overrides)
  end

  # --- 1. one place, recorded once -------------------------------------------

  def test_a_new_location_is_appended
    result = IP.push([], **entry.transform_keys(&:to_sym), at: "2026-08-13T21:00:00Z")

    assert_equal 1, result.size
    assert_equal "US", result.first["country"]
    assert_equal "Austin", result.first["city"]
    assert_equal 1, result.first["count"]
    assert_equal "2026-08-13T21:00:00Z", result.first["first_seen_at"]
  end

  def test_the_same_place_from_a_different_address_is_not_a_second_location
    # The point of tracking PLACES rather than addresses: a consumer IP rotates
    # constantly, and an append-per-address would fill the cap with one city.
    first  = IP.push([], ip: "203.0.113.7", country: "US", region: "TX", city: "Austin",
                         at: "2026-08-13T21:00:00Z")
    second = IP.push(first, ip: "198.51.100.9", country: "US", region: "TX", city: "Austin",
                            at: "2026-08-14T09:00:00Z")

    assert_equal 1, second.size, "same city, one entry"
    assert_equal 2, second.first["count"]
    assert_equal "2026-08-13T21:00:00Z", second.first["first_seen_at"], "first sighting is kept"
    assert_equal "2026-08-14T09:00:00Z", second.first["last_seen_at"], "last sighting moves"
    assert_equal "198.51.100.9", second.first["ip"], "the freshest address for the place"
  end

  def test_a_genuinely_new_place_is_a_second_entry
    first  = IP.push([], ip: "203.0.113.7", country: "US", region: "TX", city: "Austin")
    second = IP.push(first, ip: "203.0.113.7", country: "US", region: "NY", city: "New York")

    assert_equal 2, second.size
    assert_equal %w[New\ York Austin].sort, second.map { |e| e["city"] }.sort
  end

  def test_seen_answers_before_a_write_is_attempted
    existing = IP.push([], ip: "203.0.113.7", country: "US", region: "TX", city: "Austin")

    assert IP.seen?(existing, ip: "198.51.100.9", country: "US", region: "TX", city: "Austin"),
           "same place, different address — already seen"
    refute IP.seen?(existing, ip: "203.0.113.7", country: "US", region: "NY", city: "New York")
    refute IP.seen?([], ip: "203.0.113.7", country: "US")
  end

  # --- 2. the cap -------------------------------------------------------------

  def test_the_array_cannot_grow_past_the_cap
    entries = []
    60.times do |i|
      entries = IP.push(entries, ip: "203.0.113.#{i}", country: "US", region: "TX",
                                 city: "City#{i}", at: "2026-08-#{format('%02d', (i % 28) + 1)}T00:00:00Z")
    end

    assert_equal Studio::IpLocations::MAX_ENTRIES, entries.size
  end

  def test_the_cap_drops_the_stalest_place_not_the_newest
    entries = []
    Studio::IpLocations::MAX_ENTRIES.times do |i|
      entries = IP.push(entries, ip: "203.0.113.#{i}", country: "US", region: "TX",
                                 city: "City#{i}", at: "2026-06-01T00:00:0#{i % 10}Z")
    end
    entries = IP.push(entries, ip: "198.51.100.1", country: "GB", region: "ENG",
                               city: "London", at: "2026-08-13T21:00:00Z")

    assert_equal Studio::IpLocations::MAX_ENTRIES, entries.size
    assert_equal "London", entries.first["city"], "most recent first"
    assert_includes entries.map { |e| e["city"] }, "London", "the new place survived the cap"
  end

  # --- 3. jsonb round-trip ----------------------------------------------------

  def test_entries_use_string_keys_so_they_survive_jsonb
    # A symbol-keyed hash written today comes back string-keyed tomorrow; if the
    # dedupe read symbols, every location would re-append after one round trip.
    result = IP.push([], ip: "203.0.113.7", country: "US")

    assert result.first.keys.all? { |k| k.is_a?(String) }, "got: #{result.first.keys.inspect}"
  end

  def test_a_symbol_keyed_row_already_in_the_column_still_dedupes
    stored = [{ ip: "203.0.113.7", country: "US", region: "TX", city: "Austin" }]
    result = IP.push(stored, ip: "203.0.113.7", country: "US", region: "TX", city: "Austin")

    assert_equal 1, result.size, "must not duplicate a row it already holds"
  end

  def test_rows_written_before_the_dedupe_key_existed_are_backfilled
    # An upgrade in place: the column already holds entries with no "key". If the
    # backfill did not happen, every existing location would re-append once.
    legacy = [{ "ip" => "203.0.113.7", "country" => "US", "region" => "TX", "city" => "Austin",
                "first_seen_at" => "2026-01-01T00:00:00Z" }]
    result = IP.push(legacy, ip: "198.51.100.9", country: "US", region: "TX", city: "Austin")

    assert_equal 1, result.size, "the legacy row was recognised as the same place"
    assert_equal 2, result.first["count"]
  end

  def test_times_are_iso8601_strings
    result = IP.push([], ip: "203.0.113.7", country: "US", at: Time.utc(2026, 8, 13, 21, 0, 0))

    assert_equal "2026-08-13T21:00:00Z", result.first["last_seen_at"]
  end

  # --- 4. junk in ------------------------------------------------------------

  def test_loopback_and_private_addresses_are_not_recorded
    # Every dev session signs in from 127.0.0.1 and every container from 10.x.
    # Recording them buys nothing and crowds real entries out of the cap.
    %w[127.0.0.1 10.0.0.4 192.168.1.10 172.16.5.2 169.254.1.1 ::1].each do |ip|
      assert_equal [], IP.push([], ip: ip), "#{ip} should not be recorded"
    end
  end

  def test_a_private_address_WITH_a_resolved_location_is_still_recorded
    # The address is uninteresting; the place is not. A proxied setup can present
    # a private remote_ip while the geo lookup (or an edge header) still knows the
    # country — throwing that away would silently record nothing in production.
    result = IP.push([], ip: "10.0.0.4", country: "US", region: "TX", city: "Austin")

    assert_equal 1, result.size
    assert_equal "Austin", result.first["city"]
  end

  def test_an_ip_with_no_geo_at_all_is_recorded_by_address
    result = IP.push([], ip: "203.0.113.7")

    assert_equal 1, result.size
    assert_equal "203.0.113.7", result.first["ip"]
    assert_nil result.first["country"]
  end

  def test_nothing_to_record_leaves_the_column_untouched
    assert_equal [], IP.push([], ip: "")
    assert_equal [], IP.push([], ip: nil)
    assert_equal [], IP.push([], ip: "   ", country: "  ")
  end

  def test_blank_geo_values_do_not_create_a_phantom_location
    # "" and nil must dedupe to the SAME place, or a lookup that intermittently
    # returns a blank region appends a duplicate every time it fails.
    first  = IP.push([], ip: "203.0.113.7", country: "US", region: "", city: nil)
    second = IP.push(first, ip: "203.0.113.7", country: "US", region: nil, city: "")

    assert_equal 1, second.size
    assert_equal 2, second.first["count"]
  end

  def test_a_junk_column_value_does_not_raise
    assert_equal 1, IP.push(nil, ip: "203.0.113.7", country: "US").size
    assert_equal 1, IP.push("not an array", ip: "203.0.113.7", country: "US").size
  end
end
