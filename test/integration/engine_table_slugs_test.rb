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

# The engine's settings and log tables take the first half of the hub's slug
# standard: a unique `slug` index, a NULL slug backfilled the way its model
# writes one (database audit 2026-11-07, finding 6). The column stays nullable
# this release, so old dynos' NULL-slug inserts keep working through a deploy or
# a rollback; NOT NULL lands in the release after every host runs a Sluggable
# ErrorLog.
#
# The host shapes are the ones host_tables_migrations_test.rb records: the hub's
# error_logs has a unique slug index, turf-monster's has none; theme_settings has
# no slug index on any host.
class EngineTableSlugsTest < ActiveSupport::TestCase
  TABLES = RequireSlugsOnEngineTables::TABLES
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

  def drop_all = TABLES.each { |table| connection.drop_table(table, if_exists: true) }

  def migrate = RequireSlugsOnEngineTables.new.migrate(:up)

  def engine_tables
    EnsureErrorLogsTable.new.migrate(:up)
    EnsureThemeSettingsTable.new.migrate(:up)
    CreateStudioGeoSettings.new.migrate(:up)
    CreateStudioSiteIdentities.new.migrate(:up)
  end

  # turf-monster's error_logs: NOT NULL message, no slug index.
  def turf_error_logs
    connection.create_table(:error_logs) do |t|
      t.text :message, null: false
      t.text :inspect
      t.text :backtrace
      t.string :slug
      %w[target parent].each do |side|
        t.string :"#{side}_type"
        t.bigint :"#{side}_id"
        t.string :"#{side}_name"
      end
      t.timestamps
    end
  end

  def insert(table, attributes)
    row = attributes.merge("created_at" => STAMP, "updated_at" => STAMP)
    cols = row.keys.map { |c| connection.quote_column_name(c) }.join(", ")
    vals = row.values.map { |v| connection.quote(v) }.join(", ")
    connection.insert("INSERT INTO #{connection.quote_table_name(table)} (#{cols}) VALUES (#{vals})")
  end

  def slugs(table) = connection.select_rows("SELECT id, slug FROM #{table} ORDER BY id").to_h

  def slug_column(table) = connection.columns(table).find { |c| c.name == "slug" }

  def slug_indexes(table)
    connection.indexes(table).select { |i| Array(i.columns) == ["slug"] }.map { |i| [i.name, i.unique] }
  end

  def assert_standard(table)
    assert slug_column(table).null, "#{table}.slug stays nullable this release (NOT NULL waits for the next)"
    assert_equal [["index_#{table}_on_slug", true]], slug_indexes(table), "#{table} has one unique slug index"
  end

  test "[unit] the derived slugs follow each model's name_slug" do
    engine_tables
    migration = RequireSlugsOnEngineTables.new
    assert_equal "error-log-7", migration.send(:derived_slug, "error_logs", 7, nil)
    assert_equal ThemeSetting.new(app_name: "Turf Monster").send(:name_slug),
                 migration.send(:derived_slug, "theme_settings", 1, "Turf Monster")
    assert_equal Studio::GeoSetting.new(app_name: "Turf Monster").send(:name_slug),
                 migration.send(:derived_slug, "studio_geo_settings", 1, "Turf Monster")
    assert_equal Studio::SiteIdentity.new(app_name: "Turf Monster").send(:name_slug),
                 migration.send(:derived_slug, "studio_site_identities", 1, "Turf Monster")
    assert_equal "theme-4", migration.send(:derived_slug, "theme_settings", 4, nil), "no app name falls back to the id"
  end

  test "[integration] fresh engine tables end unique and still nullable, and a second run changes nothing" do
    engine_tables
    migrate
    TABLES.each { |table| assert_standard(table) }

    shapes = TABLES.to_h { |table| [table, [connection.columns(table).map { |c| [c.name, c.null] }, slug_indexes(table)]] }
    migrate
    assert_equal shapes, TABLES.to_h { |table| [table, [connection.columns(table).map { |c| [c.name, c.null] }, slug_indexes(table)]] }
  end

  test "[integration] NULL and blank slugs are backfilled by the model's rule; a taken slug takes the id" do
    engine_tables
    insert("error_logs", "message" => "a", "slug" => nil)
    insert("error_logs", "message" => "b", "slug" => "")
    insert("error_logs", "message" => "c", "slug" => "error-log-4")
    insert("error_logs", "message" => "d", "slug" => nil)
    insert("theme_settings", "app_name" => "Turf Monster", "slug" => nil)
    insert("studio_geo_settings", "app_name" => "Turf Monster", "slug" => nil)
    insert("studio_site_identities", "app_name" => "Turf Monster", "slug" => "")
    insert("studio_site_identities", "app_name" => "Other", "slug" => "site-identity-turf-monster-x")

    migrate

    assert_equal({ 1 => "error-log-1", 2 => "error-log-2", 3 => "error-log-4", 4 => "error-log-4-4" }, slugs("error_logs"))
    assert_equal({ 1 => "theme-turf-monster" }, slugs("theme_settings"))
    assert_equal({ 1 => "geo-turf-monster" }, slugs("studio_geo_settings"))
    assert_equal({ 1 => "site-identity-turf-monster", 2 => "site-identity-turf-monster-x" }, slugs("studio_site_identities"))
    TABLES.each { |table| assert_standard(table) }
  end

  test "[integration] turf-monster's error_logs: duplicates after the first take the id, then the unique index is added" do
    turf_error_logs
    insert("error_logs", "message" => "a", "slug" => "error-log-1")
    insert("error_logs", "message" => "b", "slug" => "error-log-1")
    insert("error_logs", "message" => "c", "slug" => "error-log-3")
    assert_empty slug_indexes("error_logs")

    migrate

    assert_equal({ 1 => "error-log-1", 2 => "error-log-1-2", 3 => "error-log-3" }, slugs("error_logs"))
    assert_standard("error_logs")
    refute connection.columns("error_logs").find { |c| c.name == "message" }.null, "the host's own NOT NULL stays"
  end

  test "[integration] a non-unique slug index is replaced by the unique one" do
    turf_error_logs
    connection.add_index :error_logs, :slug, name: "idx_error_logs_slug_plain"

    migrate

    assert_standard("error_logs")
  end

  test "[integration] a host without a table is skipped" do
    EnsureErrorLogsTable.new.migrate(:up)

    migrate

    assert_standard("error_logs")
    (TABLES - ["error_logs"]).each { |table| refute connection.table_exists?(table), table }
  end

  # The deploy window: old dynos run the shipped ErrorLog.capture!, which inserts
  # a NULL slug and sets it after. That insert must still succeed once this
  # migration has run, and two of them must not collide on the unique index.
  test "[integration] an old-style NULL-slug insert still succeeds, and a duplicate slug is refused" do
    engine_tables
    migrate

    insert("error_logs", "message" => "old dyno", "slug" => nil)
    insert("error_logs", "message" => "old dyno again", "slug" => nil)
    insert("theme_settings", "app_name" => "A", "slug" => "theme-a")
    assert_raises(ActiveRecord::RecordNotUnique) { insert("theme_settings", "app_name" => "B", "slug" => "theme-a") }
  end

  test "[integration] down changes nothing and keeps the index" do
    engine_tables
    migrate
    RequireSlugsOnEngineTables.new.migrate(:down)

    TABLES.each do |table|
      assert slug_column(table).null, table
      assert_equal [["index_#{table}_on_slug", true]], slug_indexes(table), table
    end
  end

  test "[integration] ErrorLog writes error-log-<id> on capture! and on a host's bare create!" do
    engine_tables
    migrate
    ErrorLog.reset_column_information

    captured = ErrorLog.capture!(RuntimeError.new("boom"))
    bare = ErrorLog.create!(message: "Solana reconciliation: drift", inspect: "{}")

    assert_equal "error-log-#{captured.id}", captured.reload.slug
    assert_equal "error-log-#{bare.id}", bare.reload.slug
    assert_equal bare.slug, bare.to_param
  end
end
