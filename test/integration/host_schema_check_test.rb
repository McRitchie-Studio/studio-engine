# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "tmpdir"
require "fileutils"

# [integration] A fresh database builds error_logs, theme_settings and
# image_caches from the engine's migrations alone, and the boot schema check
# (Studio::HostSchema) passes on it; then the check names a missing column,
# raises in development and test, and only logs in production.
#
# The dummy's database is an empty in-memory SQLite and this file runs in its own
# process, so "fresh" is literal. The engine's migrations that name one of the
# three tables run here, in version order, through the same MigrationContext
# db:migrate uses. They are selected by reading every file in db/migrate, so a
# later engine migration that touches these tables joins the run on its own. The
# other engine migrations build studio_* tables with jsonb columns, which SQLite
# lacks; the consumer CI lanes run the whole set on Postgres.
class HostSchemaCheckTest < ActiveSupport::TestCase
  ENGINE_MIGRATIONS = File.expand_path("../../db/migrate", __dir__)
  TABLES = %w[error_logs theme_settings image_caches].freeze

  class RecordingLogger
    attr_reader :errors

    def initialize = @errors = []
    def error(text) = @errors << text
    def debug(_text) = nil
  end

  def connection = ActiveRecord::Base.connection

  def host_table_migrations
    Dir[File.join(ENGINE_MIGRATIONS, "*.rb")].select do |path|
      source = File.read(path)
      TABLES.any? { |table| source.include?(":#{table}") }
    end
  end

  def migrate_fresh!
    ActiveRecord::Migration.verbose = false
    dir = Dir.mktmpdir("host-table-migrations")
    host_table_migrations.each { |path| FileUtils.cp(path, dir) }
    context = ActiveRecord::MigrationContext.new(dir)
    context.migrate
    context
  end

  setup do
    @was_verbose = ActiveRecord::Migration.verbose
  end

  teardown { ActiveRecord::Migration.verbose = @was_verbose }

  # The whole fresh-install story in one test, because migrating is once per
  # process: absent before, built by the engine's migrations, check passes,
  # and a ThemeSetting save works.
  test "a fresh database builds the three tables from engine migrations alone and passes the boot check" do
    TABLES.each { |t| assert_not connection.table_exists?(t), "precondition: #{t} absent" }
    assert_not_empty Studio::HostSchema.missing_columns(connection), "control: the check fails before migrating"

    assert_equal %w[20260620000002 20261006120001 20261006120002 20261006120003],
                 host_table_migrations.map { |p| File.basename(p)[0, 14] }.sort,
                 "the engine migrations that own these tables"
    context = migrate_fresh!

    assert_empty context.migrations.map(&:version) - context.get_all_versions,
                 "every engine migration ran"
    TABLES.each { |t| assert connection.table_exists?(t), "#{t} built by the engine" }
    assert_equal({}, Studio::HostSchema.check!(connection: connection, mode: :raise))

    ThemeSetting.reset_column_information
    setting = ThemeSetting.create!(app_name: "Fresh Host", primary: "#000000")
    assert_equal "theme-fresh-host", setting.reload.slug

    image = ImageCache.create!(owner: nil, purpose: "email_banner", variant: "welcome", s3_key: "k/1.png")
    assert_nil image.reload.owner_type, "an app-global image needs no owner"

    log = ErrorLog.capture!(RuntimeError.new("fresh"))
    assert_equal "error-log-#{log.id}", log.slug

    assert_check_catches_a_missing_column
    assert_extra_columns_are_harmless
  end

  test "the mode follows the environment unless the host sets one" do
    env = ->(name) { ActiveSupport::EnvironmentInquirer.new(name) }

    assert_equal :raise, Studio::HostSchema.mode(setting: nil, env: env.("development"))
    assert_equal :raise, Studio::HostSchema.mode(setting: nil, env: env.("test"))
    assert_equal :log, Studio::HostSchema.mode(setting: nil, env: env.("production"))
    assert_equal :log, Studio::HostSchema.mode(setting: nil, env: env.("staging"))
    assert_equal false, Studio::HostSchema.mode(setting: false, env: env.("development"))
    assert_equal :raise, Studio::HostSchema.mode(setting: :raise, env: env.("production"))
  end

  test "an unreachable database skips the check instead of failing boot" do
    broken = Object.new
    def broken.table_exists?(_) = raise(ActiveRecord::ConnectionNotEstablished, "no database")

    assert_equal({}, Studio::HostSchema.check!(connection: broken, mode: :raise, logger: RecordingLogger.new))
  end

  test "mode false never reads the schema" do
    untouchable = Object.new # any call on it raises NoMethodError

    assert_equal({}, Studio::HostSchema.check!(connection: untouchable, mode: false))
  end

  test "the boot hook skips inside a rake task" do
    require "rake"
    app = Rake.application
    was = app.top_level_tasks.dup
    app.top_level_tasks.replace(["db:migrate"])
    assert Studio::HostSchema.inside_rake_task?
    app.top_level_tasks.clear
    assert_not Studio::HostSchema.inside_rake_task?
  ensure
    Rake.application.top_level_tasks.replace(was) if was
  end

  private

  # [integration] the check catches a missing required column: raise names the
  # table and column; log mode logs the same text and returns the gap.
  def assert_check_catches_a_missing_column
    connection.remove_column :theme_settings, :slug

    error = assert_raises(Studio::HostSchemaError) do
      Studio::HostSchema.check!(connection: connection, mode: :raise)
    end
    assert_match(/theme_settings: missing slug/, error.message)
    assert_match(/studio_engine:install:migrations/, error.message)

    logger = RecordingLogger.new
    missing = Studio::HostSchema.check!(connection: connection, mode: :log, logger: logger)
    assert_equal({ "theme_settings" => ["slug"] }, missing, "production logs, never raises")
    assert_match(/theme_settings: missing slug/, logger.errors.join)

    connection.drop_table :image_caches
    error = assert_raises(Studio::HostSchemaError) { Studio::HostSchema.check!(connection: connection, mode: :raise) }
    assert_match(/image_caches: the table is missing/, error.message)

    # Re-running the engine's migrations heals both gaps.
    ActiveRecord::Migration.verbose = false
    require_relative "../../db/migrate/20261006120002_ensure_theme_settings_table"
    require_relative "../../db/migrate/20261006120003_ensure_image_caches_table"
    EnsureThemeSettingsTable.new.migrate(:up)
    EnsureImageCachesTable.new.migrate(:up)
    assert_equal({}, Studio::HostSchema.check!(connection: connection, mode: :raise))
  end

  # CONTROL for the other direction: a host column the engine does not know
  # (turf's extra index, an app's own column) is never reported.
  def assert_extra_columns_are_harmless
    connection.add_column :error_logs, :request_id, :string
    connection.add_index :error_logs, :created_at
    connection.add_column :theme_settings, :font_family, :string

    assert_equal({}, Studio::HostSchema.check!(connection: connection, mode: :raise))
  end
end
