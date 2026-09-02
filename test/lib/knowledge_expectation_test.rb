# frozen_string_literal: true

# [unit] Studio::KnowledgeExpectation — the coverage view's "what SHOULD exist"
# row: validations, once/monthly coverage math, slot derivation, and the rule
# that superseded documents never fill a slot. Boots the dummy app and defines
# its own tables like the sibling knowledge tests.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"

ActiveRecord::Schema.define(version: 1) do
  create_table :studio_knowledge_expectations, force: true do |t|
    t.string :entity, null: false
    t.string :title, null: false
    t.string :path, null: false, default: ""
    t.string :category
    t.string :cadence, null: false, default: "once"
    t.date :start_on
    t.string :source_note
    t.boolean :active, null: false, default: true
    t.timestamps
  end

  create_table :studio_knowledge_docs, force: true do |t|
    t.string :title, null: false
    t.string :entity, null: false
    t.string :path, null: false, default: ""
    t.string :status, null: false, default: "inbox"
    t.json :access, null: false, default: {}
    t.date :document_date
    t.string :s3_key
    t.bigint :expectation_id
    t.timestamps
  end
end

class KnowledgeExpectationTest < ActiveSupport::TestCase
  Expectation = Studio::KnowledgeExpectation
  Doc = Studio::KnowledgeDoc

  setup do
    Expectation.delete_all
    Doc.delete_all
  end

  def expect!(title: "LOI", entity: "welding", **attrs)
    Expectation.create!(title: title, entity: entity, **attrs)
  end

  def fill!(expectation, title: "doc", date: nil, status: "filed")
    Doc.create!(title: title, entity: expectation.entity, status: status,
                document_date: date, expectation_id: expectation.id)
  end

  test "requires entity, title, and a known cadence; normalizes like docs do" do
    assert_raises(ActiveRecord::RecordInvalid) { Expectation.create!(title: "x") }
    assert_raises(ActiveRecord::RecordInvalid) { expect!(cadence: "weekly") }

    row = expect!(entity: " Welding ", path: "/deal//docs/")
    assert_equal "welding", row.entity
    assert_equal "deal/docs", row.path
  end

  test "once: unfilled until a linked doc exists, and superseded docs never fill" do
    row = expect!
    refute row.filled?
    assert_equal({ filled: false, docs: [] }, row.coverage)

    ghost = fill!(row, status: "superseded")
    refute row.filled?, "a superseded doc must not satisfy an expectation"

    real = fill!(row)
    assert row.filled?
    assert_equal [real], row.coverage[:docs]
    refute_includes row.coverage[:docs], ghost
  end

  test "an unlinked doc counts for nothing" do
    row = expect!
    Doc.create!(title: "stray", entity: "welding", status: "filed")
    refute row.filled?
  end

  test "monthly: slots run start_on through as_of, gaps named by month" do
    row = expect!(cadence: "monthly", start_on: Date.new(2026, 7, 1))
    fill!(row, title: "jul", date: Date.new(2026, 7, 31))
    fill!(row, title: "aug", date: Date.new(2026, 8, 15))

    as_of = Date.new(2026, 9, 10)
    assert_equal [Date.new(2026, 7, 1), Date.new(2026, 8, 1), Date.new(2026, 9, 1)],
                 row.slot_months(as_of: as_of)

    result = row.coverage(as_of: as_of)
    assert_equal [Date.new(2026, 9, 1)], result[:missing_months],
      "September has no linked doc — it is THE gap the view exists to show"
    refute row.filled?(as_of: as_of)
    assert row.filled?(as_of: Date.new(2026, 8, 20)), "through August it was fully covered"
  end

  test "monthly without start_on begins at the creation month, and once has no slots" do
    row = expect!(cadence: "monthly")
    first = row.created_at.to_date.beginning_of_month
    assert_equal [first], row.slot_months(as_of: first.end_of_month)

    assert_nil expect!(title: "one-shot").slot_months
  end
end
