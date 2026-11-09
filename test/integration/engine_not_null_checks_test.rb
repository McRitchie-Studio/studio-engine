# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

require_relative "../../db/migrate/20261006120001_ensure_error_logs_table"
require_relative "../../db/migrate/20261006120002_ensure_theme_settings_table"
require_relative "../../db/migrate/20260818120000_create_studio_geo_settings"
require_relative "../../db/migrate/20260930120000_create_studio_site_identities"
require_relative "../../db/migrate/20261108160000_require_slugs_on_engine_tables"
require_relative "../../db/migrate/20261109180000_add_engine_not_null_checks"

# AddEngineNotNullChecks: the NOT NULL step RequireSlugsOnEngineTables and
# AddUsersRoleKnownCheck deferred, as validated `<column> IS NOT NULL` CHECKs
# (the form the release's schema-dump guard accepts: an added line, nothing
# rewritten). The dummy's sqlite enforces CHECK constraints, so each refusal is
# exercised, not read as source.
class EngineNotNullChecksTest < ActiveSupport::TestCase
  SLUG_TABLES = AddEngineNotNullChecks::SLUG_TABLES
  STAMP = "2026-01-01 00:00:00"

  def connection = ActiveRecord::Base.connection

  setup do
    @was_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    drop_all
  end

  teardown do
    drop_all
    ActiveRecord::Migration.verbose = @was_verbose
    [ErrorLog, ThemeSetting, Studio::GeoSetting, Studio::SiteIdentity].each(&:reset_column_information)
  end

  def drop_all = (SLUG_TABLES + ["users"]).each { |table| connection.drop_table(table, if_exists: true) }

  def migrate_up = AddEngineNotNullChecks.new.migrate(:up)
  def migrate_down = AddEngineNotNullChecks.new.migrate(:down)

  # The engine tables as a host has them after 0.141.0: created, then given the
  # unique slug index with the column still nullable.
  def engine_tables
    EnsureErrorLogsTable.new.migrate(:up)
    EnsureThemeSettingsTable.new.migrate(:up)
    CreateStudioGeoSettings.new.migrate(:up)
    CreateStudioSiteIdentities.new.migrate(:up)
    RequireSlugsOnEngineTables.new.migrate(:up)
  end

  # cyvasse, moms-app, industries: role defaults to viewer and is nullable.
  def nullable_users
    connection.create_table(:users) do |t|
      t.string :email
      t.string :role, default: "viewer"
    end
  end

  def insert(table, attributes)
    row = attributes.merge("created_at" => STAMP, "updated_at" => STAMP)
    cols = row.keys.map { |c| connection.quote_column_name(c) }.join(", ")
    vals = row.values.map { |v| connection.quote(v) }.join(", ")
    connection.insert("INSERT INTO #{connection.quote_table_name(table)} (#{cols}) VALUES (#{vals})")
  end

  def insert_user(attributes)
    cols = attributes.keys.join(", ")
    vals = attributes.values.map { |v| connection.quote(v) }.join(", ")
    connection.execute("INSERT INTO users (#{cols}) VALUES (#{vals})")
  end

  def slugs(table) = connection.select_rows("SELECT id, slug FROM #{table} ORDER BY id").to_h
  def check_names(table) = connection.check_constraints(table).map(&:name)

  test "[unit] each CHECK is named <table>_<column>_present" do
    assert_equal "error_logs_slug_present", AddEngineNotNullChecks.constraint_name("error_logs", "slug")
    assert_equal "users_role_present", AddEngineNotNullChecks.constraint_name("users", "role")
  end

  test "[unit] the backfill derives slugs by the same rule as RequireSlugsOnEngineTables" do
    ours = AddEngineNotNullChecks.new
    theirs = RequireSlugsOnEngineTables.new
    [["error_logs", 7, nil], ["theme_settings", 1, "Turf Monster"], ["studio_geo_settings", 2, "Turf Monster"],
     ["studio_site_identities", 3, "Turf Monster"], ["theme_settings", 4, nil]].each do |args|
      assert_equal theirs.send(:derived_slug, *args), ours.send(:derived_slug, *args), args.inspect
    end
  end

  test "[integration] every engine table refuses a NULL slug after the migration" do
    engine_tables
    migrate_up

    SLUG_TABLES.each do |table|
      assert_includes check_names(table), "#{table}_slug_present"
      attributes = table == "error_logs" ? { "message" => "x", "slug" => nil } : { "app_name" => "A", "slug" => nil }
      assert_raises(ActiveRecord::StatementInvalid, "#{table} refuses a NULL slug") { insert(table, attributes) }
    end
  end

  # A NULL row an old capture! left behind (it inserts NULL and fills it after;
  # a crash between the two leaves the NULL) must not stop the migration.
  test "[integration] a NULL slug left by an old capture! is backfilled first" do
    engine_tables
    insert("error_logs", "message" => "old dyno", "slug" => nil)
    insert("error_logs", "message" => "taken", "slug" => "error-log-3")
    insert("error_logs", "message" => "old dyno again", "slug" => nil)
    insert("theme_settings", "app_name" => "Turf Monster", "slug" => nil)

    migrate_up

    assert_equal({ 1 => "error-log-1", 2 => "error-log-3", 3 => "error-log-3-3" }, slugs("error_logs"))
    assert_equal({ 1 => "theme-turf-monster" }, slugs("theme_settings"))
  end

  test "[integration] the code that is live now still writes: ErrorLog.capture!, a bare create! and a ThemeSetting" do
    engine_tables
    migrate_up
    ErrorLog.reset_column_information
    ThemeSetting.reset_column_information

    captured = ErrorLog.capture!(RuntimeError.new("boom"))
    bare = ErrorLog.create!(message: "drift", inspect: "{}")
    theme = ThemeSetting.create!(app_name: "Turf Monster")

    assert_equal "error-log-#{captured.id}", captured.reload.slug
    assert_equal "error-log-#{bare.id}", bare.reload.slug
    assert_equal "theme-turf-monster", theme.reload.slug
  end

  test "[integration] users: a NULL role is filled with viewer, then refused; a write without a role takes the default" do
    nullable_users
    insert_user("email" => "null@example.com", "role" => nil)

    migrate_up

    assert_includes check_names(:users), "users_role_present"
    assert_equal ["viewer"], connection.select_values("SELECT role FROM users WHERE email = 'null@example.com'")
    insert_user("email" => "default@example.com")
    assert_equal ["viewer"], connection.select_values("SELECT role FROM users WHERE email = 'default@example.com'")
    assert_raises(ActiveRecord::StatementInvalid) { insert_user("email" => "x@example.com", "role" => nil) }
  end

  test "[integration] a role column that is already NOT NULL (the hub, Turf) gets no CHECK" do
    connection.create_table(:users) { |t| t.string :role, default: "viewer", null: false }

    migrate_up

    assert_empty check_names(:users)
  end

  test "[integration] a host without a table or column is skipped" do
    EnsureErrorLogsTable.new.migrate(:up)
    connection.create_table(:users) { |t| t.string :email }

    migrate_up

    assert_equal ["error_logs_slug_present"], check_names(:error_logs)
    assert_empty check_names(:users)
    (SLUG_TABLES - ["error_logs"]).each { |table| refute connection.table_exists?(table), table }
  end

  test "[integration] the columns themselves stay nullable, so the schema dump only gains lines" do
    engine_tables
    nullable_users
    migrate_up

    SLUG_TABLES.each { |table| assert connection.columns(table).find { |c| c.name == "slug" }.null, table }
    assert connection.columns(:users).find { |c| c.name == "role" }.null
  end

  test "[integration] a second run changes nothing" do
    engine_tables
    nullable_users
    migrate_up
    before = (SLUG_TABLES + ["users"]).to_h { |table| [table, check_names(table).sort] }

    migrate_up

    assert_equal before, (SLUG_TABLES + ["users"]).to_h { |table| [table, check_names(table).sort] }
  end

  test "[integration] down removes the CHECKs, so a NULL insert works again" do
    engine_tables
    nullable_users
    migrate_up
    migrate_down

    SLUG_TABLES.each { |table| refute_includes check_names(table), "#{table}_slug_present" }
    assert_empty check_names(:users)
    insert("error_logs", "message" => "0.137 dyno", "slug" => nil)
    insert_user("email" => "y@example.com", "role" => nil)
  end
end
