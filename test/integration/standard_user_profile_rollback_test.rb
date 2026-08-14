# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

require_relative "../../db/migrate/20260813220000_add_standard_user_profile_columns"

# [integration] `add_standard_user_profile_columns` is the engine's FIRST migration
# against a HOST-owned table. Its `up` guards every add with `if_not_exists` so it
# can run against apps that already disagree — and that guard is exactly what makes
# an honest `down` impossible: the migration records nothing about which columns it
# actually created here.
#
# Rails' auto-inverse does not care. `INVERT_METHODS` maps `add_column` to
# `remove_column` and passes the same options through; `remove_column` honours only
# `if_exists`, and a stray `if_not_exists:` is silently DISCARDED rather than
# raising. So the pre-fix `def change` reversed into an unconditional `DROP COLUMN`
# against columns the host owned before the engine ever shipped this.
#
# Measured blast radius at the time of the fix: mcritchie-studio owned
# `users.first_name`; turf-monster owned `first_name` AND `birth_year`. The two apps
# the `up` was careful not to touch are the two a rollback would have robbed.
#
# `if_exists` is NOT the fix and this file exists partly to pin that: it asks "does
# this column exist?", and on those apps it does. It protects only a SECOND
# rollback, after the data is already gone.
#
# So the `down` refuses. These tests pin BOTH halves — that the refusal actually
# fires and destroys nothing, and that the guard did not quietly neuter the `up`.
class StandardUserProfileRollbackTest < ActiveSupport::TestCase
  ADDED = %w[birth_day birth_month birth_year ip_locations].freeze

  def connection = ActiveRecord::Base.connection

  setup do
    @was_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    connection.drop_table(:users, if_exists: true)
  end

  teardown do
    ActiveRecord::Migration.verbose = @was_verbose
    connection.drop_table(:users, if_exists: true)
  end

  # mcritchie-studio's real shape: the host already owns first_name, with data in it.
  def create_host_users_table_owning_first_name
    connection.create_table :users do |t|
      t.string :email
      t.string :first_name
    end
    connection.execute("INSERT INTO users (email, first_name) VALUES ('ada@example.com', 'Ada')")
  end

  def first_names = connection.select_values("SELECT first_name FROM users ORDER BY id")

  def column_names = connection.columns(:users).map(&:name)

  test "up adds the standard columns and leaves a host-owned first_name and its data alone" do
    create_host_users_table_owning_first_name
    assert_equal ["Ada"], first_names, "precondition: the host's first_name carries data"

    AddStandardUserProfileColumns.new.migrate(:up)

    ADDED.each { |c| assert_includes column_names, c, "up must add #{c}" }
    assert_includes column_names, "first_name"
    assert_equal ["Ada"], first_names, "the host's pre-existing first_name data must survive the up"
  end

  # THE REGRESSION. Pre-fix this dropped first_name and Ada with it, silently.
  test "down refuses instead of dropping a column the host owned" do
    create_host_users_table_owning_first_name
    AddStandardUserProfileColumns.new.migrate(:up)
    assert_equal ["Ada"], first_names, "precondition: data present before the rollback"

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      AddStandardUserProfileColumns.new.migrate(:down)
    end
    assert_match(/cannot be reversed safely/, error.message)

    assert_includes column_names, "first_name", "the host-owned column must survive a refused rollback"
    assert_equal ["Ada"], first_names, "the host's data must survive a refused rollback"
    ADDED.each do |c|
      assert_includes column_names, c, "a refused rollback must drop NOTHING, including #{c}"
    end
  end

  # The guard must not have turned the migration into a no-op everywhere.
  test "up still adds every standard column on a host that owned none of them" do
    connection.create_table(:users) { |t| t.string :email }

    AddStandardUserProfileColumns.new.migrate(:up)

    (ADDED + %w[first_name]).each { |c| assert_includes column_names, c, "up must add #{c}" }
  end

  test "both directions no-op on an app with no users table" do
    assert_not connection.table_exists?(:users), "precondition: table must be absent"

    AddStandardUserProfileColumns.new.migrate(:up)
    AddStandardUserProfileColumns.new.migrate(:down)

    assert_not connection.table_exists?(:users), "neither direction may create the table"
  end
end
