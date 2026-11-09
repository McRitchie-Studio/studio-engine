# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"

require_relative "../../db/migrate/20261108160001_add_engine_state_checks"

# The engine's two state columns hold the hub's state standard, pinned the way
# the hub's test/models/state_check_constraints_test.rb pins its own: each
# column's model validates against one constant, the migration's frozen list
# equals that constant, and the CHECK `<table>_<column>_known` holds the same
# values, refuses a value outside them and takes every value inside.
class EngineStateChecksTest < ActiveSupport::TestCase
  # "table.column" => [model, the constant its validation reads].
  REGISTRY = {
    "studio_links.kind" => [Studio::Link, -> { Studio::LinkToken::KINDS }],
    "studio_knowledge_docs.status" => [Studio::KnowledgeDoc, -> { Studio::KnowledgeDoc::STATUSES }]
  }.freeze

  def connection = ActiveRecord::Base.connection

  setup do
    @was_verbose = ActiveRecord::Migration.verbose
    ActiveRecord::Migration.verbose = false
    drop_all
  end

  teardown do
    drop_all
    ActiveRecord::Migration.verbose = @was_verbose
  end

  def drop_all = REGISTRY.each_key { |key| connection.drop_table(key.split(".").first, if_exists: true) }

  # The columns the constraints touch, NOT NULL as the engine's create migrations
  # make them. SQLite has no jsonb, so the rest of each table is left out.
  def build_tables
    connection.create_table(:studio_links) do |t|
      t.string :token, null: false
      t.string :kind, null: false
      t.timestamps
    end
    connection.create_table(:studio_knowledge_docs) do |t|
      t.string :title, null: false
      t.string :entity, null: false
      t.string :status, null: false, default: "inbox"
      t.timestamps
    end
  end

  def migrate = AddEngineStateChecks.new.migrate(:up)

  def constraint(key)
    table, = key.split(".")
    connection.check_constraints(table).find { |c| c.name == AddEngineStateChecks.constraint_name(key) }
  end

  # The quoted values in a constraint's stored expression. It reads both forms:
  # `kind IN ('a', 'b')` as SQLite keeps it, and Postgres's
  # `ARRAY['a'::character varying::text, ...]`.
  def constraint_values(key)
    constraint(key)&.expression.to_s.scan(/'((?:[^']|'')*)'/).flatten.map { |v| v.gsub("''", "'") }
  end

  # Each registered column whose constraint is missing or holds another list than
  # its constant.
  def constraint_problems(registry = REGISTRY)
    registry.filter_map do |key, (_model, constant)|
      values = constraint_values(key)
      next "#{key}: missing" if values.nil? || values.empty?

      "#{key}: differs" unless values == constant.call
    end
  end

  def insert(table, attributes)
    stamp = "2026-01-01 00:00:00"
    row = attributes.merge("created_at" => stamp, "updated_at" => stamp)
    cols = row.keys.map { |c| connection.quote_column_name(c) }.join(", ")
    vals = row.values.map { |v| connection.quote(v) }.join(", ")
    ActiveRecord::Base.transaction(requires_new: true) do
      connection.insert("INSERT INTO #{connection.quote_table_name(table)} (#{cols}) VALUES (#{vals})")
    end
  end

  def row_for(key, value)
    case key
    when "studio_links.kind" then { "token" => SecureRandom.hex(8), "kind" => value }
    else { "title" => "Doc", "entity" => "studio", "status" => value }
    end
  end

  test "[unit] the migration's frozen lists equal the models' constants" do
    assert_equal REGISTRY.keys.sort, AddEngineStateChecks::CHECKS.keys.sort
    REGISTRY.each do |key, (_model, constant)|
      assert_equal constant.call, AddEngineStateChecks::CHECKS.fetch(key), key
    end
  end

  test "[unit] each model's validation reads the registered constant" do
    REGISTRY.each do |key, (model, constant)|
      table, column = key.split(".")
      assert_equal table, model.table_name, "#{model} is the model of #{table}"
      validator = model.validators_on(column.to_sym).grep(ActiveModel::Validations::InclusionValidator).first
      assert validator, "#{key}: no inclusion validation"
      assert_same constant.call, validator.options.fetch(:in), "#{key}: validates another list than its constant"
    end
  end

  test "[unit] the constraint names follow <table>_<column>_known" do
    assert_equal %w[studio_links_kind_known studio_knowledge_docs_status_known],
                 AddEngineStateChecks::CHECKS.keys.map { |key| AddEngineStateChecks.constraint_name(key) }
  end

  # Checked against a scratch Postgres on 2026-11-08: this spelling dumps the same
  # before and after a schema.rb load, as the hub's db_baseline_mark_test needs.
  test "[unit] on Postgres the constraint is written in the spelling a schema load settles on" do
    migration = AddEngineStateChecks.new
    migration.define_singleton_method(:postgres?) { true }

    assert_equal %q{("kind")::text = ANY (ARRAY['magic_link'::character varying::text, 'referral'::character varying::text])},
                 migration.send(:expression, "kind", AddEngineStateChecks::CHECKS.fetch("studio_links.kind"))
  end

  test "[integration] registry_matches_constraint: every registered column has a CHECK holding its list" do
    build_tables
    migrate

    assert_empty constraint_problems
  end

  test "[integration] control: a value in the constant alone reads as a mismatch" do
    build_tables
    migrate
    widened = REGISTRY.merge("studio_links.kind" => [Studio::Link, -> { Studio::LinkToken::KINDS + %w[limbo] }])

    assert_equal ["studio_links.kind: differs"], constraint_problems(widened)
  end

  test "[integration] each constraint refuses a value outside its list and takes every listed value" do
    build_tables
    migrate

    REGISTRY.each do |key, (_model, constant)|
      table, column = key.split(".")
      assert_raises(ActiveRecord::CheckViolation, key) { insert(table, row_for(key, "no-such-#{column}")) }
      constant.call.each { |value| insert(table, row_for(key, value)) }
      assert_equal constant.call.size, connection.select_value("SELECT COUNT(*) FROM #{table}"), key
    end
  end

  test "[integration] a second run changes nothing, and a host without a table is skipped" do
    build_tables
    migrate
    before = REGISTRY.keys.map { |key| constraint(key).expression }
    migrate
    assert_equal before, REGISTRY.keys.map { |key| constraint(key).expression }

    drop_all
    connection.create_table(:studio_links) { |t| t.string :kind, null: false }
    migrate
    assert constraint("studio_links.kind")
    refute connection.table_exists?(:studio_knowledge_docs)
  end

  test "[integration] a stray value stops the migration before any change, naming it" do
    build_tables
    insert("studio_knowledge_docs", row_for("studio_knowledge_docs.status", "archived"))

    error = assert_raises(StandardError) { migrate }

    assert_match(/studio_knowledge_docs\.status holds values outside .*"archived" \(1\)/, error.message)
    assert_nil constraint("studio_knowledge_docs.status")
  end

  test "[integration] down removes both constraints" do
    build_tables
    migrate
    AddEngineStateChecks.new.migrate(:down)

    REGISTRY.each_key { |key| assert_nil constraint(key), key }
  end
end
