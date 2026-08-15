# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# [integration] `users.last_name` — the standard set's sixth column.
#
# WHY IT IS ITS OWN MIGRATION, which is the whole lesson here: I first added
# last_name to AddStandardUserProfileColumns, and turf-monster's and
# mcritchie-industries' consumer CI both went red. An engine migration is
# INSTALL-COPIED into each app's own db/migrate with the app's own timestamp, and
# `studio_engine:install:migrations` SKIPS a name that is already installed — so
# editing the gem side after a consumer has installed it does not update
# anything. The copy silently diverges, and if it has already run the app is
# stamped on a body that exists nowhere. Both apps guard for exactly that.
#
# A shipped migration is therefore immutable. The standard SET is expressed
# across however many files it took; adding a column means adding one.
#
# Asserted as SOURCE for the same reason its predecessor is: the engine's dummy
# has no users table (it stands in for a host, and hosts own theirs), so there is
# nothing here to run it against. The properties that matter are structural, and
# they are exactly what a careless edit would drop.
class LastNameColumnTest < ActiveSupport::TestCase
  MIGRATION = File.expand_path("../../db/migrate/20260815000000_add_last_name_to_users.rb", __dir__)
  STANDARD  = File.expand_path("../../db/migrate/20260813220000_add_standard_user_profile_columns.rb", __dir__)

  def source
    @source ||= File.read(MIGRATION)
  end

  test "the add is guarded, because two apps already own the column" do
    assert_includes source, "add_column :users, :last_name, :string, if_not_exists: true",
      "mcritchie-studio and turf-monster owned users.last_name first; an unguarded add raises there"
  end

  test "it no-ops on an app with no users table" do
    assert_includes source, "return unless table_exists?(:users)",
      "an app that names its accounts something else must be skipped, not raised on"
  end

  # Same reasoning as the standard-columns migration: `if_not_exists` records
  # nothing about who created the column, and the apps the `up` was careful not
  # to touch are the ones a DROP would rob.
  test "the down refuses rather than dropping host-owned data" do
    assert_includes source, "ActiveRecord::IrreversibleMigration"
    refute_includes source, "remove_column",
      "a reversible drop here destroys data on the apps that owned the column first"
  end

  # THE REGRESSION GUARD. Putting last_name back into the already-installed
  # migration is the mistake this file exists to stop being made twice — it reads
  # like the tidier option and it reddens every consumer that has installed it.
  test "last_name is NOT added to the already-installed standard migration" do
    standard = File.read(STANDARD)

    refute_includes standard, ":last_name",
      "AddStandardUserProfileColumns is installed in consumers — editing it there " \
      "diverges their copies silently. Add a NEW migration instead."
  end
end
