# frozen_string_literal: true

# [integration] Guard for the knowledge browser's MARKUP contract — the ids and
# structure the operator's eye (and any future JS) navigates by: folder links,
# breadcrumbs, doc rows, access chips, the inbox badge, the upload form, and
# the storage warning. Renders the partials through a bare ActionView with the
# engine's helpers, mirroring board_primitive_test — this asserts the CONTRACT,
# not styling.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"

ActiveRecord::Schema.define(version: 1) do
  create_table :studio_knowledge_docs, force: true do |t|
    t.string :title, null: false
    t.string :entity, null: false
    t.string :path, null: false, default: ""
    t.string :category
    t.string :mime_type
    t.date :document_date
    t.string :status, null: false, default: "inbox"
    t.json :access, null: false, default: {}
    t.json :tags, null: false, default: []
    t.text :summary
    t.string :source_note
    t.string :uploaded_by
    t.string :s3_key
    t.bigint :byte_size
    t.bigint :superseded_by_id
    t.timestamps
  end
end

class KnowledgePrimitiveTest < ActiveSupport::TestCase
  Doc = Studio::KnowledgeDoc

  # Route helpers the partials call, stubbed to inspectable paths — the partial
  # renders outside a router here, exactly like the board harness renders
  # outside a controller.
  module RouteStubs
    def admin_knowledge_path(**opts)
      query = opts.compact.map { |k, v| "#{k}=#{v}" }.join("&")
      query.empty? ? "/admin/knowledge" : "/admin/knowledge?#{query}"
    end

    def admin_knowledge_doc_path(doc) = "/admin/knowledge/#{doc.respond_to?(:id) ? doc.id : doc}"
    def admin_knowledge_doc_download_path(doc) = "/admin/knowledge/#{doc.id}/download"

    def admin_knowledge_coverage_path(**opts)
      query = opts.compact.map { |k, v| "#{k}=#{v}" }.join("&")
      query.empty? ? "/admin/knowledge/coverage" : "/admin/knowledge/coverage?#{query}"
    end

    def protect_against_forgery? = false
  end

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths(["app/views"])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
                    .tap { |v| v.extend(RouteStubs) }
  end

  def render_browser(docs:, folders: [], view_mode: "folders", folder: "", entity: nil, status: nil, inbox_size: 0)
    view.render(partial: "studio/knowledge_docs/browser",
                locals: { view: view_mode, folder: folder, entity: entity, status: status,
                          entities: docs.map(&:entity).uniq.sort, folders: folders,
                          docs: docs, inbox_size: inbox_size })
  end

  setup do
    Doc.delete_all
    @old_prefix = Studio.s3_bucket_prefix
    @old_agents = Studio.knowledge_agents
    Studio.s3_bucket_prefix = "mcritchie-industries"
    Studio.knowledge_agents = %w[samson dawn]
  end

  teardown do
    Studio.s3_bucket_prefix = @old_prefix
    Studio.knowledge_agents = @old_agents
  end

  def doc!(title:, **attrs)
    Doc.create!({ title: title, entity: "welding" }.merge(attrs))
  end

  # --- rows + chips ----------------------------------------------------------

  test "each doc row carries id=knowledge-doc-<id> and its access chips" do
    doc = doc!(title: "LOI", access: { "samson" => "full", "dawn" => "aware" }, status: "filed")
    html = render_browser(docs: [doc])

    assert_includes html, %(id="knowledge-doc-#{doc.id}")
    assert_includes html, "knowledge-chip-full"
    assert_includes html, "knowledge-chip-aware"
    assert_includes html, "samson · full"
    assert_includes html, "dawn · aware"
    assert_includes html, "knowledge-status-filed"
  end

  test "chip styles come from the shared partial, defined exactly once" do
    doc = doc!(title: "LOI", access: { "samson" => "full" })
    html = render_browser(docs: [doc])

    assert_equal 1, html.scan("border-radius: 9999px").size,
      "the chip style block must render once — a second copy means the shared partial split again"
    assert_includes html, "knowledge-chip-full", "chips still render against the shared definition"
  end

  test "a doc with no access map says so instead of rendering nothing" do
    doc = doc!(title: "Untriaged")
    html = view.render(partial: "studio/knowledge_docs/access_chips", locals: { doc: doc })

    assert_includes html, "no agents"
    assert_includes html, "knowledge-chip-none"
  end

  # --- folders vs flat -------------------------------------------------------

  test "folder view renders breadcrumbs and folder links" do
    doc = doc!(title: "Aug", path: "financials/aging")
    html = render_browser(docs: [doc], folders: %w[aging], folder: "financials")

    assert_includes html, %(id="knowledge-breadcrumbs")
    assert_includes html, %(id="knowledge-folder-aging")
    assert_includes html, "folder=financials/aging", "the folder link must descend from the current folder"
  end

  test "flat view shows the folder column and no folder grid" do
    doc = doc!(title: "Aug", path: "financials/aging")
    html = render_browser(docs: [doc], view_mode: "flat")

    assert_includes html, "financials/aging", "flat rows name their folder"
    refute_includes html, %(id="knowledge-breadcrumbs"), "flat view has no breadcrumbs"
  end

  test "the view toggle links both modes" do
    html = render_browser(docs: [])
    assert_includes html, %(id="knowledge-view-toggle")
    assert_includes html, "view=folders"
    assert_includes html, "view=flat"
  end

  # --- inbox + upload + storage warning --------------------------------------

  test "inbox badge renders only when something waits" do
    quiet = render_browser(docs: [])
    refute_includes quiet, %(id="knowledge-inbox-badge")

    loud = render_browser(docs: [], inbox_size: 3)
    assert_includes loud, %(id="knowledge-inbox-badge")
    assert_includes loud, "status=inbox", "the badge links to the inbox filter"
  end

  test "upload form is multipart, uploads to inbox, and offers a select per configured agent" do
    html = render_browser(docs: [])

    assert_includes html, %(id="knowledge-upload")
    assert_includes html, "multipart/form-data"
    assert_includes html, %(id="knowledge-access-samson")
    assert_includes html, %(id="knowledge-access-dawn")
    assert_includes html, "knowledge_doc[access][samson]"
  end

  test "an unconfigured bucket renders the loud warning instead of a working form" do
    Studio.s3_bucket_prefix = nil
    html = render_browser(docs: [])

    assert_includes html, %(id="knowledge-storage-warning")
    assert_includes html, "Studio.s3_bucket_prefix"
  end
end
