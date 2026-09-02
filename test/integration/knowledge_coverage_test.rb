# frozen_string_literal: true

# [integration] Markup contract for the coverage table — the ids and marks the
# operator's eye navigates by: per-expectation rows, per-month slot marks with
# MISSING named, the filled link, and the add-expectation form. Rendered
# through the bare-ActionView harness like the sibling knowledge tests.
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

class KnowledgeCoverageTest < ActiveSupport::TestCase
  Expectation = Studio::KnowledgeExpectation
  Doc = Studio::KnowledgeDoc

  module RouteStubs
    def admin_knowledge_path(**opts)
      query = opts.compact.map { |k, v| "#{k}=#{v}" }.join("&")
      query.empty? ? "/admin/knowledge" : "/admin/knowledge?#{query}"
    end

    def admin_knowledge_coverage_path(**opts)
      query = opts.compact.map { |k, v| "#{k}=#{v}" }.join("&")
      query.empty? ? "/admin/knowledge/coverage" : "/admin/knowledge/coverage?#{query}"
    end

    def admin_knowledge_doc_path(doc) = "/admin/knowledge/#{doc.respond_to?(:id) ? doc.id : doc}"
    def protect_against_forgery? = false
  end

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
                    .tap { |v| v.extend(RouteStubs) }
  end

  def render_coverage(expectations, entity: nil)
    view.render(partial: "studio/knowledge_docs/coverage_table",
                locals: { expectations: expectations, entity: entity,
                          entities: expectations.map(&:entity).uniq.sort })
  end

  setup do
    Expectation.delete_all
    Doc.delete_all
  end

  test "a filled once-expectation shows the check and links its doc" do
    row = Expectation.create!(entity: "welding", title: "Letter of Intent", path: "deal")
    doc = Doc.create!(title: "LOI signed", entity: "welding", status: "filed", expectation_id: row.id)

    html = render_coverage([row])
    assert_includes html, %(id="coverage-exp-#{row.id}")
    assert_includes html, "coverage-filled"
    assert_includes html, "/admin/knowledge/#{doc.id}", "the filled mark links to the fulfilling doc"
  end

  test "an unfilled once-expectation says MISSING" do
    row = Expectation.create!(entity: "welding", title: "Quality of Earnings")
    html = render_coverage([row])
    assert_includes html, "coverage-missing"
    assert_includes html, "MISSING"
  end

  test "monthly slots render per month with the gap named" do
    row = Expectation.create!(entity: "welding", title: "Aging inventory",
                              cadence: "monthly", start_on: Date.current.beginning_of_month.prev_month)
    Doc.create!(title: "prev", entity: "welding", status: "filed", expectation_id: row.id,
                document_date: Date.current.prev_month)

    html = render_coverage([row])
    prev_key = Date.current.prev_month.strftime("%Y-%m")
    this_key = Date.current.strftime("%Y-%m")
    assert_includes html, %(id="coverage-slot-#{row.id}-#{prev_key}")
    assert_includes html, %(id="coverage-slot-#{row.id}-#{this_key}")
    assert_includes html, "MISSING", "the current month has no doc and must say so"
  end

  test "the add-expectation form renders with cadence choices" do
    html = render_coverage([])
    assert_includes html, %(id="coverage-new")
    assert_includes html, "knowledge_expectation[cadence]"
    assert_includes html, %(id="coverage-empty")
  end
end
