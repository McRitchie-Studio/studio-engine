# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [integration] The standard user profile columns — the engine's FIRST migration
# against a host-owned table, and the ActiveRecord wrapper that writes one of
# them.
#
# Studio::IpLocations' rules are covered as pure logic in test/lib/ip_locations_test.rb.
# What only shows up here is (a) whether the migration is safe to run in apps
# that already disagree about these columns, and (b) whether the wrapper writes
# without taking a request down.
#
# WHY THE MIGRATION IS ASSERTED AS SOURCE: the engine's dummy app has no users
# table (it stands in for a host, and hosts own theirs), so there is nothing here
# to run it against. The properties that matter are structural — every add
# guarded, the table guarded — and they are exactly what a careless edit would
# drop.
class StandardProfileColumnsTest < ActiveSupport::TestCase
  MIGRATION = File.expand_path(
    "../../db/migrate/20260813220000_add_standard_user_profile_columns.rb", __dir__
  )

  STANDARD_COLUMNS = %w[first_name last_name birth_day birth_month birth_year ip_locations].freeze

  def source
    @source ||= File.read(MIGRATION)
  end

  # --- the migration is safe in apps that already disagree ---------------------

  # REGRESSION GUARD. The three apps do NOT agree today: mcritchie-studio and
  # turf-monster already have first_name, and turf already has birth_year. An
  # unguarded add raises there — which, for a migration the engine pushes into
  # every consumer, means the engine breaking apps that did nothing wrong.
  test "EVERY column add is guarded with if_not_exists" do
    adds = source.scan(/add_column :users, :(\w+).*$/)

    assert_equal STANDARD_COLUMNS.sort, adds.flatten.sort,
      "the standard set changed — update this test deliberately, not by accident"

    source.each_line do |line|
      next unless line.include?("add_column :users")

      assert_includes line, "if_not_exists: true",
        "unguarded add raises in apps that already have the column: #{line.strip}"
    end
  end

  test "the migration no-ops on an app with no users table" do
    assert_includes source, "return unless table_exists?(:users)",
      "an app that names its accounts something else must be skipped, not raised on"
  end

  test "the birth columns are three integers, not one date" do
    # The operator's call (2026-08-13): age needs the year and the month/day for
    # the boundary case; "whose birthday is today" needs month + day and no year.
    # Storing no single date-of-birth column is the point.
    %w[birth_day birth_month birth_year].each do |col|
      assert_match(/add_column :users, :#{col},\s+:integer/, source)
    end
    refute_includes source, ":date_of_birth"
  end

  test "ip_locations is a jsonb array that defaults to empty and is never null" do
    assert_match(/add_column :users, :ip_locations, :jsonb, default: \[\], null: false/, source)
  end

  # --- the wrapper ------------------------------------------------------------

  # Stands in for the host's User. Records what update_columns was called with,
  # and BLOWS UP on save/save!/valid? so a test proves the write path never takes
  # the validation route — an analytics write must not be blocked by an unrelated
  # validation failure on a half-onboarded account.
  class FakeUser
    attr_reader :ip_locations, :written

    def initialize(ip_locations = [])
      @ip_locations = ip_locations
      @written = nil
    end

    def blank? = false

    def update_columns(attrs)
      @written = attrs
      @ip_locations = attrs[:ip_locations]
      true
    end

    def save!  = raise("must not validate on an analytics write")
    def valid? = raise("must not validate on an analytics write")
  end

  # An app that has not run the migration yet.
  class ColumnlessUser
    def blank? = false
  end

  test "a new location is written" do
    user = FakeUser.new([])

    assert Studio.record_ip_location!(user, ip: "203.0.113.7", country: "US",
                                            region: "TX", city: "Austin"),
      "recording a place never seen before returns true"
    assert_equal 1, user.ip_locations.size
    assert_equal "Austin", user.ip_locations.first["city"]
    assert user.written.key?(:ip_locations), "written through update_columns"
  end

  test "a place already recorded is NOT written again" do
    # This runs on the request path. A write per request would be a database
    # write per page view for no analytic gain.
    user = FakeUser.new([])
    Studio.record_ip_location!(user, ip: "203.0.113.7", country: "US", region: "TX", city: "Austin")
    user.instance_variable_set(:@written, nil)

    refute Studio.record_ip_location!(user, ip: "198.51.100.9", country: "US",
                                            region: "TX", city: "Austin"),
      "same place from a different address is not a new location"
    assert_nil user.written, "no write at all on a repeat visit"
  end

  test "a second, genuinely different place is written" do
    user = FakeUser.new([])
    Studio.record_ip_location!(user, ip: "203.0.113.7", country: "US", region: "TX", city: "Austin")

    assert Studio.record_ip_location!(user, ip: "198.51.100.9", country: "GB",
                                            region: "ENG", city: "London")
    assert_equal 2, user.ip_locations.size
  end

  test "an app that has not run the migration records nothing instead of raising" do
    # The gem reaches an app before its migration does — mcritchie-industries is
    # in exactly that state. Raising here would take down every signed-in request.
    refute Studio.record_ip_location!(ColumnlessUser.new, ip: "203.0.113.7", country: "US")
  end

  test "a signed-out visitor records nothing" do
    refute Studio.record_ip_location!(nil, ip: "203.0.113.7", country: "US")
  end

  test "a loopback address on a dev session records nothing" do
    user = FakeUser.new([])

    refute Studio.record_ip_location!(user, ip: "127.0.0.1")
    assert_nil user.written
  end
end
