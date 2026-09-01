# frozen_string_literal: true

# [unit] Studio::KnowledgeDoc — the knowledge layer's row: validations, path
# normalization (implicit folders), the per-agent access map, lifecycle
# (inbox -> filed -> superseded), and the storage seam. Boots the dummy app and
# defines its own table like board_rankable_test — the engine's real migration
# is installed per consumer, never run here.
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

class KnowledgeDocTest < ActiveSupport::TestCase
  Doc = Studio::KnowledgeDoc

  UploadStub = Struct.new(:original_filename, :content_type, :payload) do
    def read = payload
  end

  setup do
    Doc.delete_all
    @old_prefix = Studio.s3_bucket_prefix
    Studio.s3_bucket_prefix = nil
  end

  teardown { Studio.s3_bucket_prefix = @old_prefix }

  def doc!(title: "Doc", entity: "welding", **attrs)
    Doc.create!(title: title, entity: entity, **attrs)
  end

  # --- validations + normalization -------------------------------------------

  test "requires title and entity, and only known statuses" do
    assert_raises(ActiveRecord::RecordInvalid) { Doc.create!(entity: "welding") }
    assert_raises(ActiveRecord::RecordInvalid) { Doc.create!(title: "x") }
    assert_raises(ActiveRecord::RecordInvalid) { doc!(status: "pending") }
    assert doc!(status: "filed").persisted?
  end

  test "path normalizes slashes and entity downcases" do
    doc = doc!(entity: "Welding", path: "/financials//aging/")
    assert_equal "financials/aging", doc.path
    assert_equal "welding", doc.entity
    assert_equal %w[financials aging], doc.folder_segments
  end

  test "access map normalizes keys and rejects unknown levels" do
    doc = doc!(access: { "Samson " => "FULL", "dawn" => "aware" })
    assert_equal({ "samson" => "full", "dawn" => "aware" }, doc.access)

    invalid = Doc.new(title: "x", entity: "e", access: { "dawn" => "partial" })
    refute invalid.valid?
    assert invalid.errors[:access].any?
  end

  # --- the three access levels ----------------------------------------------

  test "access_for defaults to none and drives visibility" do
    doc = doc!(access: { "samson" => "full", "dawn" => "aware" })

    assert_equal "full",  doc.access_for(:samson)
    assert_equal "aware", doc.access_for("dawn")
    assert_equal "none",  doc.access_for("steffon")

    assert doc.full_for?(:samson)
    refute doc.full_for?(:dawn)
    assert doc.visible_to?(:dawn), "aware means the agent may know it exists"
    refute doc.visible_to?(:steffon)
  end

  # --- implicit folders ------------------------------------------------------

  test "folders_under derives immediate children from claimed paths" do
    doc!(title: "a", path: "financials/aging/2026-08")
    doc!(title: "b", path: "financials/aging/2026-09")
    doc!(title: "c", path: "financials/statements")
    doc!(title: "d", path: "equipment")
    doc!(title: "e", path: "")

    assert_equal %w[equipment financials], Doc.all.folders_under
    assert_equal %w[aging statements],     Doc.all.folders_under("financials")
    assert_equal %w[2026-08 2026-09],      Doc.all.folders_under("financials/aging")
    assert_equal [],                       Doc.all.folders_under("equipment")

    # The browser hands in a display-ordered scope. Postgres refuses
    # SELECT DISTINCT + foreign ORDER BY (SQLite does not, so this line alone
    # cannot fail here for the PG reason — the unscope(:order) inside
    # folders_under is what keeps the real consumer standing).
    assert_equal %w[equipment financials], Doc.order(created_at: :desc).folders_under
  end

  test "in_folder is exact and under is subtree" do
    root = doc!(title: "root", path: "")
    aging = doc!(title: "aging", path: "financials/aging")
    deep  = doc!(title: "deep",  path: "financials/aging/2026-08")

    assert_equal [root],        Doc.in_folder("").to_a
    assert_equal [aging],       Doc.in_folder("/financials/aging/").to_a
    assert_equal [aging, deep], Doc.under("financials").order(:title).to_a
    assert_equal Doc.count,     Doc.under("").count
  end

  # --- lifecycle -------------------------------------------------------------

  test "supersede_with! marks the old row and keeps the pointer" do
    old = doc!(title: "v1")
    new_doc = doc!(title: "v2")

    old.supersede_with!(new_doc)

    assert old.superseded?
    assert_equal new_doc.id, old.superseded_by_id
    refute Doc.active.include?(old)
    assert Doc.active.include?(new_doc)
  end

  # --- storage seam: FAIL LOUDLY when unconfigured ---------------------------

  test "attach! without a bucket raises NotConfigured instead of dropping the file" do
    doc = Doc.new(title: "cim", entity: "welding")
    upload = UploadStub.new("CIM Final.pdf", "application/pdf", "bytes")

    assert_raises(Studio::S3::NotConfigured) { doc.attach!(upload) }
    assert_nil doc.s3_key, "a failed upload must not leave a dangling pointer"
  end

  test "signed_url without a file, and without a bucket, both refuse" do
    doc = doc!
    assert_raises(Studio::S3::Error) { doc.signed_url }

    doc.update!(s3_key: "knowledge/welding/x.pdf")
    assert_raises(Studio::S3::NotConfigured) { doc.signed_url }
  end

  test "intake! files metadata-only records and defaults the title from the file" do
    doc = Doc.intake!({ entity: "welding", title: "LOI" })
    assert doc.persisted?
    refute doc.file?

    # No file and no title: validation refuses rather than inventing a name.
    assert_raises(ActiveRecord::RecordInvalid) { Doc.intake!({ entity: "welding" }) }
    assert_equal "CIM Final", Doc.default_title(UploadStub.new("CIM_Final.pdf", nil, ""))
  end

  test "sanitize_filename tames what uploads call themselves" do
    assert_equal "aging-report-aug.xlsx", Doc.sanitize_filename("Aging Report (Aug).xlsx")
    assert_equal "document", Doc.sanitize_filename("  ")
  end
end
