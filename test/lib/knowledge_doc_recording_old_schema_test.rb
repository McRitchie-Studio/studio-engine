# frozen_string_literal: true

# [unit] Studio::KnowledgeDoc on a consumer that has NOT installed the
# recording migration: the table as it stood before, with no recording_*
# column. Everything the document page and intake already did keeps working,
# every recording reader answers "none" instead of raising, and the two attach
# methods refuse, naming the fix, before any byte moves.
#
# Its own file (and so its own process under bin/release-check) because the
# model caches its columns: this schema must be the only one this process sees.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"
require_relative "../support/knowledge_recording_fixture"

KnowledgeRecordingFixture.create_old_table!

class KnowledgeDocRecordingOldSchemaTest < ActiveSupport::TestCase
  include KnowledgeRecordingFixture

  Doc = Studio::KnowledgeDoc

  setup do
    Doc.reset_column_information
    Doc.delete_all
    stub_storage!
  end

  teardown { unstub_storage! }

  def doc! = Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls")

  test "the table has no recording column" do
    assert_empty Doc.column_names.grep(/recording/)
    refute Doc.recording_columns?
  end

  test "a document still creates, validates, updates, reloads and lists" do
    doc = doc!
    assert doc.valid?
    assert doc.update(title: "Renamed", status: "filed")
    assert_equal "Renamed", doc.reload.title
    assert_equal [doc], Doc.for_entity("example-co").filed.to_a
    assert_equal %w[calls], Doc.folders_under("")
    assert_equal doc, Doc.find(doc.id)
  end

  test "intake! still uploads and saves a document" do
    upload = Struct.new(:original_filename, :content_type, :payload) { def read = payload }.new("notes.txt", "text/plain", "hello")
    doc = Doc.intake!({ entity: "example-co", path: "calls" }, file: upload)
    assert doc.persisted?
    assert doc.file?
    assert_equal [:put_object], operations
  end

  test "every recording reader answers none, never an error" do
    doc = doc!
    assert_equal false, doc.recording?
    assert_nil doc.recording_kind
    assert_nil doc.recording_link
    assert_equal false, Doc.new.recording?
    assert_equal false, Doc.select(:id, :title).first.recording?, "a partial select has no such attribute either"
  end

  test "recording_url says there is no recording" do
    error = assert_raises(Studio::S3::Error) { doc!.recording_url }
    assert_match(/no recording attached/, error.message)
  end

  test "attach_recording! refuses, naming the migration, before reading the file or touching storage" do
    error = assert_raises(Studio::KnowledgeDoc::Recording::MissingRecordingColumns) do
      doc!.attach_recording!("/no/such/file.mp4")
    end
    assert_match(/studio_engine:install:migrations && bin\/rails db:migrate/, error.message)
    assert_raises(Studio::KnowledgeDoc::Recording::MissingRecordingColumns) { doc!.attach_recording!(recording_file) }
    assert_empty operations
  end

  test "attach_recording_from_url! refuses before any fetch" do
    original = Studio::KnowledgeRecording.method(:fetch)
    Studio::KnowledgeRecording.define_singleton_method(:fetch) { |*, **| raise "the fetch must not run" }
    assert_raises(Studio::KnowledgeDoc::Recording::MissingRecordingColumns) do
      doc!.attach_recording_from_url!("https://files.example.com/call.mp4")
    end
    assert_empty operations
  ensure
    Studio::KnowledgeRecording.define_singleton_method(:fetch, original) if original
  end
end
