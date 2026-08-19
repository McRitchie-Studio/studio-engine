# frozen_string_literal: true

require "test_helper"

# [unit] Studio::Geo — the pure half of the geo primitive: normalization, the
# region-token vocabulary, flag glyphs, the freshness policy, and the blocking
# policy itself.
#
# The policy tests are the load-bearing ones. Every branch of `blocked?` decides
# whether a real person can use the product, and the FAIL-CLOSED branch decides
# it for someone the app cannot even place — so each branch is asserted on its
# own rather than through a single "a blocked visitor is blocked" case.
class StudioGeoTest < Minitest::Test
  Geo = Studio::Geo

  # --- normalization --------------------------------------------------------

  def test_country_normalizes_to_upcased_alpha2
    assert_equal "US", Geo.normalize_country("us")
    assert_equal "CA", Geo.normalize_country(" ca ")
  end

  # A full country name is not a code. Returning it anyway would put "United
  # States" into a ban list that only ever compares codes — an entry that can
  # never match, in a list whose whole job is to match.
  def test_country_rejects_anything_that_is_not_two_letters
    assert_nil Geo.normalize_country("United States")
    assert_nil Geo.normalize_country("USA")
    assert_nil Geo.normalize_country("")
    assert_nil Geo.normalize_country(nil)
  end

  def test_subdivision_maps_a_us_state_name_to_its_code
    assert_equal "WA", Geo.normalize_subdivision("Washington")
    assert_equal "DC", Geo.normalize_subdivision("District of Columbia")
  end

  def test_subdivision_upcases_a_bare_code
    assert_equal "WA", Geo.normalize_subdivision("wa")
  end

  # Outside the US the provider's region string is frequently the only
  # identifier there is. Dropping it would blank the visitor's location — and a
  # blank location is the one the fail-closed rule treats as suspicious.
  def test_subdivision_passes_an_unknown_region_name_through_unchanged
    assert_equal "Alberta", Geo.normalize_subdivision("Alberta")
  end

  def test_subdivision_is_nil_for_blank_input
    assert_nil Geo.normalize_subdivision(nil)
    assert_nil Geo.normalize_subdivision("   ")
  end

  # --- the region-token vocabulary -----------------------------------------

  def test_region_token_joins_both_halves
    assert_equal "US-WA", Geo.region_token("us", "Washington")
  end

  # A half-address is not a region. Storing one would match every visitor from
  # that country, which is what banned_countries is for.
  def test_region_token_needs_both_halves
    assert_nil Geo.region_token("US", nil)
    assert_nil Geo.region_token(nil, "WA")
  end

  def test_bare_code_parses_as_a_subdivision_of_the_home_country
    assert_equal %w[US WA], Geo.parse_region("WA", home_country: "US")
    assert_equal ["CA", "AB"], Geo.parse_region("AB", home_country: "CA")
  end

  def test_qualified_token_parses_both_halves
    assert_equal %w[CA AB], Geo.parse_region("CA-AB", home_country: "US")
  end

  # THE AMBIGUITY THIS VOCABULARY EXISTS FOR: "CA" is California and Canada. As a
  # bare token it is read as a subdivision of home; qualified, it is unambiguous.
  def test_ca_means_california_bare_and_canada_qualified
    assert_equal %w[US CA], Geo.parse_region("CA", home_country: "US")
    assert_equal ["CA", nil], Geo.parse_region("CA-", home_country: "US")
  end

  def test_country_only_token_parses_with_no_subdivision
    assert_equal ["CU", nil], Geo.parse_region("CU-", home_country: "US")
  end

  def test_normalize_region_token_canonicalises_legacy_bare_entries
    assert_equal "US-WA", Geo.normalize_region_token("wa")
    assert_equal "US-WA", Geo.normalize_region_token("Washington")
    assert_equal "US-WA", Geo.normalize_region_token("US-WA")
  end

  # --- presentation ---------------------------------------------------------

  def test_country_flag_emoji_is_the_regional_indicator_pair
    assert_equal "🇨🇦", Geo.country_flag_emoji("CA")
    assert_equal "🇺🇸", Geo.country_flag_emoji("us")
  end

  # Garbage in must not become garbage codepoints out — a badge renders this
  # straight into the page.
  def test_country_flag_emoji_is_nil_for_anything_that_is_not_a_code
    assert_nil Geo.country_flag_emoji("Canada")
    assert_nil Geo.country_flag_emoji("")
    assert_nil Geo.country_flag_emoji(nil)
  end

  def test_foreign_compares_against_the_home_country
    refute Geo.foreign?("US", home_country: "US")
    assert Geo.foreign?("CA", home_country: "US")
    refute Geo.foreign?("CA", home_country: "CA")
  end

  # An UNKNOWN country is not a foreign one. Reading it as foreign would hand a
  # visitor the wrong flag and, worse, skip the home-country fail-closed rule.
  def test_unknown_country_is_not_foreign
    refute Geo.foreign?(nil, home_country: "US")
    refute Geo.foreign?("", home_country: "US")
  end

  def test_subdivision_name_reads_back_the_us_state
    assert_equal "Washington", Geo.subdivision_name("WA")
    assert_nil Geo.subdivision_name("AB", country: "CA")
  end

  # --- freshness ------------------------------------------------------------

  def test_never_detected_is_stale
    assert Geo.stale?(detected_at: nil, resolved: false)
    assert Geo.stale?(detected_at: "", resolved: true)
  end

  def test_a_resolved_region_is_trusted_for_the_full_ttl
    now = Time.now
    hour_ago = (now - 3600).to_s

    refute Geo.stale?(detected_at: hour_ago, resolved: true, now: now, ttl: 86_400, retry_ttl: 300)
  end

  # THE SELF-HEALING HALF. A blank is usually a provider timeout or a rate limit;
  # trusting it for a day fails every gate closed until the visitor's IP changes.
  def test_a_blank_result_is_retried_within_minutes
    now = Time.now
    hour_ago = (now - 3600).to_s

    assert Geo.stale?(detected_at: hour_ago, resolved: false, now: now, ttl: 86_400, retry_ttl: 300)
  end

  def test_a_fresh_blank_result_is_not_retried_on_every_request
    now = Time.now
    minute_ago = (now - 60).to_s

    refute Geo.stale?(detected_at: minute_ago, resolved: false, now: now, ttl: 86_400, retry_ttl: 300)
  end

  # --- policy ---------------------------------------------------------------

  def blocked(**overrides)
    Geo.blocked?(**{ country: "US", subdivision: "CO", banned_countries: [],
                     banned_subdivisions: ["US-WA"], home_country: "US",
                     enforcing: true, fail_closed: true }.merge(overrides))
  end

  # The kill switch has to mean OFF — including for visitors the app cannot
  # place, which is the case an operator turning the gate off is usually trying
  # to unbreak.
  def test_nothing_is_blocked_when_the_gate_is_off
    refute blocked(enforcing: false, subdivision: "WA")
    refute blocked(enforcing: false, subdivision: nil)
    refute blocked(enforcing: false, country: "CU", banned_countries: ["CU"])
  end

  def test_an_allowed_region_is_allowed
    refute blocked(subdivision: "CO")
  end

  def test_a_banned_subdivision_is_blocked
    assert blocked(subdivision: "WA")
  end

  def test_a_legacy_bare_ban_entry_still_matches
    assert blocked(subdivision: "WA", banned_subdivisions: ["WA"])
  end

  def test_a_banned_country_blocks_every_region_in_it
    assert blocked(country: "CU", subdivision: "HAV", banned_countries: ["CU"])
    assert blocked(country: "cu", subdivision: nil, banned_countries: ["CU"])
  end

  # THE TRAP THE TOKEN VOCABULARY EXISTS FOR: a Canadian visitor whose region
  # code normalises to "CA" must not be caught by a ban on CALIFORNIA.
  def test_a_foreign_region_colliding_with_a_us_state_code_is_not_blocked
    refute blocked(country: "CA", subdivision: "CA", banned_subdivisions: ["US-CA"])
  end

  def test_the_same_code_is_blocked_when_the_token_names_that_country
    assert blocked(country: "CA", subdivision: "AB", banned_subdivisions: ["CA-AB"])
  end

  # FAIL CLOSED. An unplaceable home-country visitor could be sitting in any of
  # the blocked regions behind a VPN, so they cannot be waved through.
  def test_an_undetectable_home_country_visitor_is_blocked
    assert blocked(country: "US", subdivision: nil)
  end

  def test_fail_closed_can_be_turned_off_for_an_app_whose_rules_are_advisory
    refute blocked(country: "US", subdivision: nil, fail_closed: false)
  end

  # Narrower than "block every blank" ON PURPOSE: an app that blocks no
  # subdivision of its own country is hiding nothing at that grain, so failing
  # its unplaceable visitors closed would cost real access to protect no rule.
  def test_a_blank_is_allowed_when_no_subdivision_rules_exist
    refute blocked(country: "US", subdivision: nil, banned_subdivisions: [])
    refute blocked(country: "US", subdivision: nil, banned_subdivisions: [], banned_countries: ["CU"])
  end

  # Only the HOME-country ambiguity is dangerous. A resolved foreign country with
  # no region is a known place this app does not restrict.
  def test_a_blank_region_in_a_resolved_foreign_country_is_allowed
    refute blocked(country: "CA", subdivision: nil)
  end
end
