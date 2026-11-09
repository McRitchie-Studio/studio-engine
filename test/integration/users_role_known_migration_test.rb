# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

require_relative "../../db/migrate/20261108170000_add_users_role_known_check"

# [unit] AddUsersRoleKnownCheck, the engine migration that installs CHECK
# users_role_known on a host's users table, run against the host shapes it
# meets: no users table, no role column, a host that already has its own CHECK
# (the hub and Turf), a host with a stray role, and a plain host. The dummy's
# in-memory sqlite enforces CHECK constraints, so the guard is exercised, not
# read as source.
class UsersRoleKnownMigrationTest < ActiveSupport::TestCase
  def connection = ActiveRecord::Base.connection

  def setup
    connection.drop_table(:users, if_exists: true)
  end

  def teardown
    connection.drop_table(:users, if_exists: true)
  end

  def create_users(role: true, check: nil)
    connection.create_table(:users) do |t|
      t.string :email
      t.string :role if role
    end
    connection.add_check_constraint(:users, check, name: "users_role_known") if check
  end

  def insert_role(role)
    connection.execute("INSERT INTO users (email, role) VALUES ('x#{rand(1_000_000)}@example.com', #{connection.quote(role)})")
  end

  def migrate_up
    ActiveRecord::Migration.suppress_messages { AddUsersRoleKnownCheck.new.migrate(:up) }
  end

  def check_names
    connection.check_constraints(:users).map(&:name)
  end

  test "skips an app with no users table" do
    migrate_up

    refute connection.table_exists?(:users)
  end

  test "skips a users table with no role column" do
    create_users(role: false)
    migrate_up

    assert_empty check_names
  end

  test "installs the CHECK, fills a NULL role with viewer, and sets NOT NULL" do
    create_users
    insert_role(nil)
    insert_role("member")

    migrate_up

    assert_includes check_names, "users_role_known"
    assert_equal %w[member viewer], connection.select_values("SELECT role FROM users ORDER BY role")
    refute connection.columns(:users).find { |c| c.name == "role" }.null
    assert_raises(ActiveRecord::StatementInvalid, "a mistyped role must be refused") { insert_role("amdin") }
    Studio::Roles.each { |role| insert_role(role) }
  end

  test "leaves a host's own narrower CHECK in place" do
    create_users(check: "role IN ('viewer', 'admin')")
    migrate_up

    assert_equal ["users_role_known"], check_names
    assert_raises(ActiveRecord::StatementInvalid, "the host's narrower CHECK still refuses member") { insert_role("member") }
  end

  test "refuses, writing nothing, when a row holds a role outside the list" do
    create_users
    insert_role("user")
    insert_role(nil)

    error = assert_raises(ActiveRecord::MigrationError) { migrate_up }

    assert_includes error.message, '"user"'
    assert_empty check_names
    assert_equal 1, connection.select_value("SELECT COUNT(*) FROM users WHERE role IS NULL"), "nothing was written"
  end

  test "spells its list out, and it matches Studio::Roles" do
    assert_equal Studio::Roles, AddUsersRoleKnownCheck::ROLES
  end
end
