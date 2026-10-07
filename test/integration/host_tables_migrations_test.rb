# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

require_relative "../../db/migrate/20261006120001_ensure_error_logs_table"
require_relative "../../db/migrate/20261006120002_ensure_theme_settings_table"
require_relative "../../db/migrate/20261006120003_ensure_image_caches_table"

# [unit] The engine's Ensure*Table migrations run on hosts that ALREADY have
# these tables, each built by the host's own migration and each a little
# different. Every migration must leave such a table exactly as it found it,
# except for adding an engine column the host lacks.
#
# The shapes below are the hosts' tables as their db/schema.rb on accepted
# declares them (2026-10-06), columns, NOT NULLs and indexes included. "engine"
# is the shape a fresh install creates.
class HostTablesMigrationsTest < ActiveSupport::TestCase
  MIGRATIONS = {
    "error_logs" => EnsureErrorLogsTable,
    "theme_settings" => EnsureThemeSettingsTable,
    "image_caches" => EnsureImageCachesTable
  }.freeze

  ERROR_LOGS_COMMON = lambda do |t, message_null: true|
    t.text :backtrace
    t.text :inspect
    t.text :message, null: message_null
    t.bigint :parent_id
    t.string :parent_name
    t.string :parent_type
    t.string :slug
    t.bigint :target_id
    t.string :target_name
    t.string :target_type
    t.timestamps
  end

  THEME_COMMON = lambda do |t, app_name_null:, slug:|
    t.string :accent1
    t.string :accent2
    t.string :app_name, null: app_name_null
    t.string :danger
    t.string :dark
    t.string :light
    t.string :primary
    t.string :slug if slug
    t.string :warning
    t.timestamps
  end

  IMAGE_CACHES = lambda do |c|
    c.create_table :image_caches do |t|
      t.integer :bytes
      t.string :content_type
      t.bigint :owner_id
      t.string :owner_type
      t.string :purpose, null: false
      t.string :s3_key, null: false
      t.string :source_url
      t.string :variant, null: false
      t.timestamps
    end
    c.add_index :image_caches, %i[owner_type owner_id purpose variant], unique: true,
                name: "idx_image_caches_owner_purpose_variant"
    c.add_index :image_caches, %i[owner_type owner_id], name: "index_image_caches_on_owner"
    c.add_index :image_caches, :s3_key, unique: true
  end

  # error_logs: hub has slug unique + target + parent indexes; turf has NOT NULL
  # message, a created_at index and NO slug index; cyvasse, industries and moms
  # have the slug index alone.
  ERROR_LOGS_SHAPES = {
    "mcritchie-studio" => lambda do |c|
      c.create_table(:error_logs) { |t| ERROR_LOGS_COMMON.call(t) }
      c.add_index :error_logs, %i[parent_type parent_id]
      c.add_index :error_logs, :slug, unique: true
      c.add_index :error_logs, %i[target_type target_id]
    end,
    "turf-monster" => lambda do |c|
      c.create_table(:error_logs) { |t| ERROR_LOGS_COMMON.call(t, message_null: false) }
      c.add_index :error_logs, :created_at
      c.add_index :error_logs, %i[parent_type parent_id]
      c.add_index :error_logs, %i[target_type target_id]
    end,
    "cyvasse/industries/moms" => lambda do |c|
      c.create_table(:error_logs) { |t| ERROR_LOGS_COMMON.call(t) }
      c.add_index :error_logs, :slug, unique: true
    end
  }.freeze

  # theme_settings: hub and turf have slug and NOT NULL app_name; cyvasse,
  # industries and moms have neither (the slug gap is the bug this fixes).
  THEME_SHAPES = {
    "mcritchie-studio/turf-monster" => lambda do |c|
      c.create_table(:theme_settings) { |t| THEME_COMMON.call(t, app_name_null: false, slug: true) }
      c.add_index :theme_settings, :app_name, unique: true
    end,
    "cyvasse/industries/moms" => lambda do |c|
      c.create_table(:theme_settings) { |t| THEME_COMMON.call(t, app_name_null: true, slug: false) }
      c.add_index :theme_settings, :app_name, unique: true
    end
  }.freeze

  # image_caches: hub, turf and industries share one shape; cyvasse and moms
  # have no table (covered by the fresh-install suite).
  IMAGE_SHAPES = { "mcritchie-studio/turf-monster/industries" => IMAGE_CACHES }.freeze

  SEED_ROWS = {
    "error_logs" => { "message" => "boom", "inspect" => "#<RuntimeError: boom>", "backtrace" => "[]",
                      "slug" => "error-log-1", "target_name" => "contest" },
    "theme_settings" => { "app_name" => "Probe", "primary" => "#123456", "accent1" => "#abcdef" },
    "image_caches" => { "purpose" => "email_banner", "variant" => "welcome", "s3_key" => "email_banners/welcome-1.png",
                        "bytes" => 42 }
  }.freeze

  def connection = ActiveRecord::Base.connection

  setup do
    @was_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    MIGRATIONS.each_key { |table| connection.drop_table(table, if_exists: true) }
  end

  teardown do
    ActiveRecord::Migration.verbose = @was_verbose
    MIGRATIONS.each_key { |table| connection.drop_table(table, if_exists: true) }
  end

  # A full fingerprint of a table: every column's definition, every index and
  # every row. Two equal snapshots mean the migration changed nothing.
  def snapshot(table)
    {
      columns: connection.columns(table).to_h { |c| [c.name, [c.sql_type, c.null, c.default]] },
      indexes: connection.indexes(table).map { |i| [i.name, i.columns, i.unique] }.sort,
      rows: connection.select_all("SELECT * FROM #{connection.quote_table_name(table)} ORDER BY id").to_a
    }
  end

  def seed(table)
    row = SEED_ROWS.fetch(table).merge("created_at" => Time.utc(2026, 1, 1), "updated_at" => Time.utc(2026, 1, 1))
    row = row.select { |col, _| connection.column_exists?(table, col) }
    cols = row.keys.map { |c| connection.quote_column_name(c) }.join(", ")
    vals = row.values.map { |v| connection.quote(v) }.join(", ")
    connection.execute("INSERT INTO #{connection.quote_table_name(table)} (#{cols}) VALUES (#{vals})")
  end

  def required(table) = Studio::HostSchema::REQUIRED_COLUMNS.fetch(table)

  # Run `migration` against a table built by `builder` and assert the baseline
  # rule: pre-existing columns, indexes and rows are untouched, and the only
  # change is the engine columns the host lacked. Returns the columns added.
  def assert_baseline(table, builder, migration)
    builder.call(connection)
    seed(table)
    before = snapshot(table)

    migration.new.migrate(:up)
    after = snapshot(table)

    before[:columns].each do |name, definition|
      assert_equal definition, after[:columns][name], "#{table}.#{name} must keep its definition"
    end
    assert_equal before[:indexes], after[:indexes], "#{table}: the host's indexes are its own"
    added = after[:columns].keys - before[:columns].keys
    assert_equal (required(table) - before[:columns].keys).sort, added.sort,
                 "#{table}: the migration adds exactly the engine columns the host lacked"
    added.each { |name| assert after[:columns][name][1], "#{table}.#{name} is added nullable" }
    before[:rows].zip(after[:rows]).each do |was, now|
      assert_equal was, now.slice(*was.keys), "#{table}: existing rows keep every value"
    end
    assert_empty Studio::HostSchema.missing_columns(connection).slice(table),
                 "#{table} satisfies the engine's contract afterwards"

    # Idempotent: a second run is a no-op.
    migration.new.migrate(:up)
    assert_equal after, snapshot(table), "#{table}: a second run changes nothing"

    added
  end

  {
    "error_logs" => ERROR_LOGS_SHAPES,
    "theme_settings" => THEME_SHAPES,
    "image_caches" => IMAGE_SHAPES
  }.each do |table, shapes|
    shapes.each do |host, builder|
      test "#{table}: baseline holds on the #{host} shape" do
        assert_baseline(table, builder, MIGRATIONS.fetch(table))
      end
    end

    test "#{table}: no-op on the engine's own shape" do
      MIGRATIONS.fetch(table).new.migrate(:up)
      seed(table)
      fresh = snapshot(table)

      MIGRATIONS.fetch(table).new.migrate(:up)

      assert_equal fresh, snapshot(table)
    end
  end

  test "every shape that already conforms is a strict no-op" do
    conforming = [
      ["error_logs", ERROR_LOGS_SHAPES.fetch("mcritchie-studio")],
      ["error_logs", ERROR_LOGS_SHAPES.fetch("turf-monster")],
      ["error_logs", ERROR_LOGS_SHAPES.fetch("cyvasse/industries/moms")],
      ["theme_settings", THEME_SHAPES.fetch("mcritchie-studio/turf-monster")],
      ["image_caches", IMAGE_SHAPES.fetch("mcritchie-studio/turf-monster/industries")]
    ]
    conforming.each do |table, builder|
      connection.drop_table(table, if_exists: true)
      assert_empty assert_baseline(table, builder, MIGRATIONS.fetch(table)), "#{table} gained a column"
    end
  end

  # The bug this card fixes, end to end: on the cyvasse/industries/moms shape a
  # ThemeSetting save raises before the migration and succeeds after it.
  test "theme_settings: the slug the Sluggable save writes lands after the migration" do
    THEME_SHAPES.fetch("cyvasse/industries/moms").call(connection)
    ThemeSetting.reset_column_information
    error = assert_raises(NoMethodError) { ThemeSetting.create!(app_name: "Cyvasse") }
    assert_match(/slug=/, error.message)

    EnsureThemeSettingsTable.new.migrate(:up)
    ThemeSetting.reset_column_information
    setting = ThemeSetting.create!(app_name: "Cyvasse", primary: "#112233")

    assert_equal "theme-cyvasse", setting.reload.slug
  ensure
    ThemeSetting.reset_column_information
  end

  # CONTROL: the harness bites. A migration that skips the slug add (the
  # setup doc's hand-copied shape, as a migration) leaves the cyvasse shape
  # short, and the very assertion the baseline tests rely on catches it. A
  # second control: an unguarded create, the reflex this design avoids, raises
  # on any host that already has the table.
  test "control: a migration missing the slug add fails the baseline assertion" do
    source = File.read(File.expand_path("../../db/migrate/20261006120002_ensure_theme_settings_table.rb", __dir__))
    mutant = source.sub(/^\s*add_column :theme_settings, :slug,.*\n/, "")
                   .sub("class EnsureThemeSettingsTable", "class EnsureThemeSettingsTableWithoutSlug")
    refute_equal source.length, mutant.length, "precondition: the mutant must drop the slug line"
    Object.class_eval(mutant)

    failure = assert_raises(Minitest::Assertion) do
      assert_baseline("theme_settings", THEME_SHAPES.fetch("cyvasse/industries/moms"),
                      Object.const_get(:EnsureThemeSettingsTableWithoutSlug))
    end
    assert_match(/exactly the engine columns the host lacked/, failure.message)
  ensure
    Object.send(:remove_const, :EnsureThemeSettingsTableWithoutSlug) if Object.const_defined?(:EnsureThemeSettingsTableWithoutSlug)
  end

  test "control: an unguarded create raises on a host that already has the table" do
    THEME_SHAPES.fetch("cyvasse/industries/moms").call(connection)
    unguarded = Class.new(ActiveRecord::Migration[7.2]) do
      def change
        create_table(:theme_settings) { |t| t.string :app_name }
      end
    end

    assert_raises(ActiveRecord::StatementInvalid) { unguarded.new.migrate(:up) }
  end

  test "down refuses rather than dropping a table it may not own" do
    THEME_SHAPES.fetch("mcritchie-studio/turf-monster").call(connection)

    assert_raises(ActiveRecord::IrreversibleMigration) { EnsureThemeSettingsTable.new.migrate(:down) }
    assert connection.table_exists?(:theme_settings)
    EnsureErrorLogsTable.new.migrate(:down) # no table: nothing to refuse
  end
end
