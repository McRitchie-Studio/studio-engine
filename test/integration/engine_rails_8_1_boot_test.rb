# frozen_string_literal: true

# Boots studio-engine inside a real Rails app (test/dummy) and exercises the
# engine's Rails-version-sensitive surfaces — the Railtie, Zeitwerk autoload
# wiring, the route DSL, and the ActiveRecord models (ErrorLog + the Sluggable
# concern on ThemeSetting). This is the "engine vs Rails dummy app" check: when
# the gemspec rails bound is widened, run this against the new Rails line to
# prove the engine still boots and its DB/HTTP surfaces still work.
#
# Scope note: the dummy deliberately autoloads (config.eager_load = false) and
# never references the engine's omniauth / solana controllers, which depend on
# host-app-only gems. Those are covered by the consumer apps' own suites
# (Consumer CI). Here we prove the *self-contained* engine core is Rails-OK.

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

# Engine tables. The engine ships the models but the host app owns the schema
# (these tables are created by per-app migrations in production), so the dummy
# defines just the columns the exercised models read.
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :error_logs, force: true do |t|
    t.string  :slug
    t.text    :message
    t.text    :inspect
    t.text    :backtrace
    t.string  :target_type
    t.bigint  :target_id
    t.string  :parent_type
    t.bigint  :parent_id
    t.timestamps
  end

  create_table :theme_settings, force: true do |t|
    t.string :slug
    t.string :app_name
    t.string :primary
    t.string :dark
    t.string :light
    t.string :accent1
    t.string :warning
    t.string :danger
    t.string :accent2
    t.timestamps
  end
end

class EngineRails81BootTest < ActiveSupport::TestCase
  def setup
    ErrorLog.delete_all
    ThemeSetting.delete_all
  end

  test "the dummy host app boots on the Rails line under test" do
    assert Rails.application.initialized?, "expected the dummy Rails app to finish initializing"
    assert_operator Gem::Version.new(Rails.version), :>=, Gem::Version.new("8.1"),
                    "expected to be exercising Rails >= 8.1, got #{Rails.version}"
  end

  test "Studio::Engine is registered as a railtie of the host app" do
    railtie_classes = Rails.application.railties.map(&:class)
    assert_includes railtie_classes, Studio::Engine,
                    "expected Studio::Engine among the host app's railties"
  end

  test "the engine's app/models autoload into the host namespace (non-isolated)" do
    # Referencing the constant triggers Zeitwerk to load it from the engine's
    # app/models path, proving the engine's load paths wired into the host app.
    assert_equal "ErrorLog", ErrorLog.name
    source = ErrorLog.instance_method(:inspect_field).source_location.first
    assert_includes source, File.join("app", "models", "error_log.rb"),
                    "expected ErrorLog to load from the engine's app/models, got #{source}"
  end

  test "ErrorLog.create! persists under ActiveRecord on this Rails line" do
    log = ErrorLog.create!(message: "boom", inspect: "#<RuntimeError: boom>", backtrace: "[]")
    assert log.persisted?
    # The model exposes the reserved `inspect` column via read_attribute.
    assert_equal "#<RuntimeError: boom>", log.inspect_field
  end

  test "ErrorLog.capture! records an exception and slugs the row" do
    error = begin
      raise ArgumentError, "bad argument"
    rescue => e
      e
    end

    log = ErrorLog.capture!(error)
    assert log.persisted?
    assert_equal "bad argument", log.message
    assert_equal "error-log-#{log.id}", log.slug, "capture! should backfill the id-based slug"
    assert_includes log.inspect_field, "ArgumentError"
  end

  test "ErrorLog polymorphic target round-trips" do
    target = ThemeSetting.create!(app_name: "Boot Target")
    log = ErrorLog.create!(message: "with target", target: target)
    assert_equal target, log.reload.target
    assert_equal "ThemeSetting", log.target_type
  end

  test "Sluggable sets the slug via before_save on a real AR callback" do
    setting = ThemeSetting.create!(app_name: "Slug App")
    assert_equal "theme-slug-app", setting.slug
    assert_equal setting.slug, setting.to_param
  end

  test "ThemeSetting uniqueness validation runs a DB query on this Rails line" do
    ThemeSetting.create!(app_name: "Unique App")
    dup = ThemeSetting.new(app_name: "Unique App")
    refute dup.valid?
    assert_includes dup.errors[:app_name], "has already been taken"
  end

  test "ThemeSetting#resolved_colors merges DB values over Studio defaults" do
    setting = ThemeSetting.create!(app_name: "Colors App", primary: "#123456")
    colors = setting.resolved_colors
    assert_equal "#123456", colors[:primary], "DB value should win"
    assert_equal Studio.theme_dark, colors[:dark], "unset role should fall back to Studio default"
  end

  test "Studio.routes draws valid named routes under the host router" do
    routes = Rails.application.routes.url_helpers
    assert_equal "/login", routes.login_path
    assert_equal "/error_logs", routes.error_logs_path
  end

  # ---- the footer-only switch, from the ActiveRecord side ---------------------
  #
  # Every footer-only accommodation (test/integration/footer_only_consumer_test.rb)
  # is gated on Studio.active_record? reading false. This host loads
  # active_record/railtie, so each of them must be OFF here: the engine a
  # database-backed consumer gets is the engine it got before.

  test "a host that loads ActiveRecord reads Studio.active_record? as true" do
    assert Studio.active_record?
  end

  test "a host with ActiveRecord keeps every engine root in eager loading" do
    excluded = Rails.autoloaders.main.send(:eager_load_exclusions).to_a
    engine_root = Studio::Engine.root.to_s

    assert_empty excluded.select { |path| path.start_with?(engine_root) },
                 "the footer-only eager-load exclusion leaked into a host with ActiveRecord"
  end

  test "a host with ActiveRecord gets Rails' own install:migrations task, not the no-op" do
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("studio_engine:install:migrations")
    task = Rake::Task["studio_engine:install:migrations"]

    assert_equal 1, task.actions.size, "exactly one action: Rails' own"
    source = task.actions.first.source_location.first
    assert_includes source, File.join("rails", "engine.rb"),
                    "studio_engine:install:migrations must be Rails' installer here, not the footer-only no-op (#{source})"
  end
end
