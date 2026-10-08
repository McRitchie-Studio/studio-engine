# frozen_string_literal: true

# [unit] Studio::KnowledgeDoc's recording: the streaming attach, replacement,
# the playback URL and the stored link. Boots the dummy app and defines its own
# table (the engine's migration is installed per consumer, never run here);
# test/integration/knowledge_recording_migration_test.rb runs the real one.
# Storage is a stubbed client, so the assertions read the requests the SDK
# would have sent. All names are invented.
require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"
require "active_support/testing/time_helpers"
require_relative "../support/knowledge_recording_fixture"

KnowledgeRecordingFixture.create_old_table!
ActiveRecord::Schema.define do
  add_column :studio_knowledge_docs, :recording_key, :string
  add_column :studio_knowledge_docs, :recording_mime_type, :string
  add_column :studio_knowledge_docs, :recording_byte_size, :bigint
  add_column :studio_knowledge_docs, :recording_source_url, :text
  add_index :studio_knowledge_docs, :recording_key, unique: true
end

class KnowledgeDocRecordingTest < ActiveSupport::TestCase
  include KnowledgeRecordingFixture
  include ActiveSupport::Testing::TimeHelpers

  Doc = Studio::KnowledgeDoc
  MP4 = KnowledgeRecordingFixture::MP4
  KEY = %r{\Aknowledge/example-co/calls/2026-10/\d{14}-\h{8}-recording-[a-z0-9._-]+\z}

  setup do
    Doc.reset_column_information
    Doc.delete_all
    stub_storage!
    # No real DNS: every name these tests fetch resolves to one made-up public address.
    @previous_resolver = Studio::ImageCache.instance_variable_get(:@resolver)
    Studio::ImageCache.resolver = ->(_host) { ["93.184.216.34"] }
  end

  teardown do
    unstub_storage!
    Studio::ImageCache.resolver = @previous_resolver
  end

  def doc!(**attrs)
    Doc.create!(title: "Weekly standup", entity: "example-co", path: "calls/2026-10", **attrs)
  end

  test "the table carries the recording columns" do
    assert Doc.recording_columns?
  end

  test "a document has no recording until one is attached" do
    doc = doc!
    refute doc.recording?
    assert_nil doc.recording_kind
    assert_nil doc.recording_link
    assert_raises(Studio::S3::Error) { doc.recording_url }
  end

  test "attach_recording! uploads in parts, records key, type and size, and saves" do
    doc = doc!
    path = recording_file
    assert_same doc, doc.attach_recording!(path)

    assert_equal %i[create_multipart_upload upload_part complete_multipart_upload head_object], operations
    doc.reload
    assert doc.recording?
    assert_match KEY, doc.recording_key
    assert doc.recording_key.end_with?(".mp4")
    assert_equal "video/mp4", doc.recording_mime_type
    assert_equal MP4.bytesize, doc.recording_byte_size
    assert_equal :video, doc.recording_kind

    create = requests(:create_multipart_upload).first
    assert_equal "example-app-dev", create[:bucket]
    assert_equal doc.recording_key, create[:key]
    assert_equal "video/mp4", create[:content_type], "the object is stored under the type the bytes earned"
    assert_equal MP4, requests(:upload_part).first[:body]
  end

  test "the recording sits beside the document and leaves the document's own file alone" do
    doc = doc!(s3_key: "knowledge/example-co/calls/2026-10/20261008000000-aaaaaaaa-standup.txt", mime_type: "text/plain", byte_size: 9)
    doc.attach_recording!(recording_file)
    doc.reload

    assert_equal "knowledge/example-co/calls/2026-10/20261008000000-aaaaaaaa-standup.txt", doc.s3_key
    assert_equal "text/plain", doc.mime_type
    assert_equal 9, doc.byte_size
    assert_equal File.dirname(doc.s3_key), File.dirname(doc.recording_key)
    refute_includes operations, :delete_object
  end

  test "same-second attaches of the same file name get distinct keys" do
    a = doc!(title: "a")
    b = doc!(title: "b")
    travel_to Time.utc(2026, 10, 8, 9, 0, 0) do
      a.attach_recording!(recording_file, filename: "standup.mp4")
      b.attach_recording!(recording_file, filename: "standup.mp4")
    end
    refute_equal a.recording_key, b.recording_key
    assert_equal a.recording_key[0, 50], b.recording_key[0, 50]
  end

  test "the key keeps a sanitized, bounded name with the extension the bytes earned" do
    doc = doc!
    doc.attach_recording!(recording_file, filename: "Q3 Review (final)  #{'x' * 300}.MP4")
    name = doc.recording_key.split("-recording-").last
    assert_match(/\Aq3-review-final-x+\.mp4\z/, name)
    assert_operator name.size, :<=, 84

    audio = doc!(title: "audio")
    audio.attach_recording!(recording_file(KnowledgeRecordingFixture::OGG, name: ["call", ""]), filename: "call")
    assert audio.recording_key.end_with?("-recording-call.ogg")
    assert_equal "audio/ogg", audio.recording_mime_type
    assert_equal :audio, audio.recording_kind
  end

  test "replacing a recording trashes the old object after the row points at the new one" do
    doc = doc!
    doc.attach_recording!(recording_file)
    first = doc.recording_key
    @client.api_requests.clear

    doc.attach_recording!(recording_file(MP4 + "more"))
    doc.reload
    refute_equal first, doc.recording_key
    assert_equal MP4.bytesize + 4, doc.recording_byte_size

    assert_equal %i[create_multipart_upload upload_part complete_multipart_upload head_object
                    head_object copy_object delete_object], operations,
                 "the new object is complete before the old one is touched"
    copy = requests(:copy_object).first
    assert_equal "example-app-dev/#{first}", copy[:copy_source]
    assert_match %r{\Atrash/\d{4}-\d{2}-\d{2}/\d+/#{Regexp.escape(first)}\z}, copy[:key], "a recoverable delete: trash/, not gone"
    assert_equal first, requests(:delete_object).first[:key]
  end

  test "a first attach deletes nothing" do
    doc!.attach_recording!(recording_file)
    refute_includes operations, :copy_object
    refute_includes operations, :delete_object
  end

  test "source_url is stored as the link, and a later attach without one keeps it" do
    doc = doc!
    doc.attach_recording!(recording_file, source_url: " https://notes.example.com/calls/abc ")
    assert_equal "https://notes.example.com/calls/abc", doc.reload.recording_source_url
    assert_equal "https://notes.example.com/calls/abc", doc.recording_link

    doc.attach_recording!(recording_file)
    assert_equal "https://notes.example.com/calls/abc", doc.reload.recording_link

    doc.attach_recording!(recording_file, source_url: "https://notes.example.com/calls/def")
    assert_equal "https://notes.example.com/calls/def", doc.reload.recording_link
  end

  test "a source_url that is not an http link is refused before anything is written" do
    doc = doc!
    ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "notes.example.com/abc"].each do |link|
      assert_raises(ArgumentError, link) { doc.attach_recording!(recording_file, source_url: link) }
      assert_raises(ArgumentError, link) { doc.attach_recording_from_url!("https://files.example.com/a.mp4", source_url: link) }
    end
    assert_empty operations
    refute doc.reload.recording?
  end

  test "a file that is not a recording is refused and nothing is written" do
    doc = doc!
    [["<html><body>sign in</body></html>", ".mp4"], ["%PDF-1.7 not a recording", ".pdf"], ["", ".mp4"],
     ["plain text notes about the call", ".txt"]].each do |bytes, ext|
      assert_raises(Studio::KnowledgeRecording::NotARecording) { doc.attach_recording!(recording_file(bytes, name: ["x", ext])) }
    end
    assert_raises(Studio::KnowledgeRecording::NotARecording, "an mp4 renamed .html") do
      doc.attach_recording!(recording_file(MP4, name: ["x", ".html"]))
    end
    assert_raises(Studio::KnowledgeRecording::Refused) { doc.attach_recording!("/no/such/file.mp4") }
    assert_empty operations
    refute doc.reload.recording?
  end

  test "an invalid row is refused before any bytes move" do
    doc = doc!
    doc.title = ""
    assert_raises(ActiveRecord::RecordInvalid) { doc.attach_recording!(recording_file) }
    assert_empty operations
  end

  test "an app with no bucket raises NotConfigured and the row is untouched" do
    doc = doc!
    Studio.s3_bucket_prefix = nil
    assert_raises(Studio::S3::NotConfigured) { doc.attach_recording!(recording_file) }
    refute doc.reload.recording?
  end

  test "a failed upload leaves the row and the old recording as they were" do
    doc = doc!
    doc.attach_recording!(recording_file)
    first = doc.recording_key
    @client.api_requests.clear
    @client.stub_responses(:upload_part, "InternalError")

    assert_raises(Aws::S3::Errors::InternalError) { doc.attach_recording!(recording_file) }
    assert_equal first, doc.reload.recording_key
    assert_equal :abort_multipart_upload, operations.last
    refute_includes operations, :copy_object
  end

  test "a failed save trashes the new object, keeps the old one, and re-raises" do
    doc = doc!
    doc.attach_recording!(recording_file)
    first = doc.recording_key
    @client.api_requests.clear
    doc.define_singleton_method(:update!) { |*| raise ActiveRecord::StatementInvalid, "the database went away" }

    error = assert_raises(ActiveRecord::StatementInvalid) { doc.attach_recording!(recording_file) }
    assert_match(/went away/, error.message)
    assert_equal first, Doc.find(doc.id).recording_key

    new_key = requests(:create_multipart_upload).first[:key]
    assert_equal ["example-app-dev/#{new_key}"], requests(:copy_object).map { |copy| copy[:copy_source] }
    assert_equal [new_key], requests(:delete_object).map { |delete| delete[:key] }, "only the unreferenced object is removed"
  end

  test "a failed trash of the old recording raises with the row already on the new one" do
    doc = doc!
    doc.attach_recording!(recording_file)
    first = doc.recording_key
    @client.stub_responses(:copy_object, "InternalError")

    assert_raises(Studio::S3::Error, Aws::S3::Errors::InternalError) { doc.attach_recording!(recording_file) }
    refute_equal first, doc.reload.recording_key
    refute_includes operations, :delete_object, "a failed copy never deletes"
  end

  # --- playback URL -----------------------------------------------------------

  test "recording_url is a presigned GET of the recording, good for six hours by default" do
    doc = doc!
    doc.attach_recording!(recording_file)
    url = doc.recording_url

    assert_equal 21_600, Doc::RECORDING_URL_TTL
    assert_includes url, doc.recording_key
    assert_match(/X-Amz-Expires=21600(&|\z)/, url)
    assert_match(/X-Amz-Signature=/, url)
    assert_operator Doc::RECORDING_URL_TTL, :>, 900, "longer than the document link, which would stop a seek past minute fifteen"
    assert_match(/X-Amz-Expires=60(&|\z)/, doc.recording_url(expires_in: 60))
    assert_match(/X-Amz-Expires=604800(&|\z)/, doc.recording_url(expires_in: Doc::MAX_RECORDING_URL_TTL))
  end

  test "recording_url refuses a lifetime outside what a presigned URL can carry" do
    doc = doc!
    doc.attach_recording!(recording_file)
    [0, -1, Doc::MAX_RECORDING_URL_TTL + 1, nil, "soon"].each do |value|
      assert_raises(ArgumentError, value.inspect) { doc.recording_url(expires_in: value) }
    end
  end

  # --- the stored link --------------------------------------------------------

  test "a recording_source_url that is not an http link fails validation" do
    doc = doc!
    refute doc.update(recording_source_url: "javascript:alert(1)")
    assert doc.errors[:recording_source_url].any?
    assert doc.update(recording_source_url: "https://notes.example.com/calls/abc")
    assert doc.update(recording_source_url: nil)
  end

  test "recording_link never answers a stored value a page could not safely render" do
    doc = doc!
    doc.update_column(:recording_source_url, "javascript:alert(1)")
    assert_nil doc.reload.recording_link
    doc.update_column(:recording_source_url, "https://notes.example.com/calls/abc")
    assert_equal "https://notes.example.com/calls/abc", doc.reload.recording_link
  end

  test "a link without a recording is legal: the external page, before the copy exists" do
    doc = doc!(recording_source_url: "https://notes.example.com/calls/abc")
    refute doc.recording?
    assert_equal "https://notes.example.com/calls/abc", doc.recording_link
  end

  # --- from a URL -------------------------------------------------------------

  def with_fetch(path, name)
    asked = []
    original = Studio::KnowledgeRecording.method(:fetch)
    Studio::KnowledgeRecording.define_singleton_method(:fetch) do |url, **options, &block|
      asked << [url, options]
      block.call(path, name)
    end
    yield asked
  ensure
    Studio::KnowledgeRecording.define_singleton_method(:fetch, original)
  end

  test "attach_recording_from_url! attaches what the guarded fetch stored and never stores the download URL" do
    doc = doc!
    with_fetch(recording_file(MP4, name: ["fetched", ".part"]), "download.php") do |asked|
      doc.attach_recording_from_url!("https://files.example.com/download.php?token=SECRET",
                                     source_url: "https://notes.example.com/calls/abc")
      assert_equal [["https://files.example.com/download.php?token=SECRET", {}]], asked
    end
    doc.reload
    assert doc.recording_key.end_with?("-recording-download.mp4"), "the server's .php is ignored; the bytes are MP4"
    assert_equal "video/mp4", doc.recording_mime_type
    assert_equal "https://notes.example.com/calls/abc", doc.recording_source_url
    refute_match(/SECRET|files\.example\.com/, doc.attributes.values.join(" "))
  end

  test "attach_recording_from_url! with no source_url stores no link" do
    doc = doc!
    with_fetch(recording_file, "call.mp4") { doc.attach_recording_from_url!("https://files.example.com/call.mp4?token=SECRET") }
    assert_nil doc.reload.recording_source_url
  end

  test "a fetched file whose name contradicts its bytes is still refused" do
    doc = doc!
    with_fetch(recording_file, "call.mp3") do
      assert_raises(Studio::KnowledgeRecording::NotARecording) { doc.attach_recording_from_url!("https://files.example.com/call.mp3") }
    end
    assert_empty operations
  end

  test "attach_recording_from_url! goes through the real guard: an internal URL never reaches storage" do
    doc = doc!
    ["http://files.example.com/a.mp4", "https://127.0.0.1/a.mp4", "https://169.254.169.254/a.mp4", "https://localhost/a.mp4"].each do |url|
      assert_raises(Studio::KnowledgeRecording::Refused, url) { doc.attach_recording_from_url!(url) }
    end
    assert_empty operations
    refute doc.reload.recording?
  end

  test "a resolver handed in reaches the fetch" do
    doc = doc!
    resolver = ->(_host) { ["93.184.216.34"] }
    with_fetch(recording_file, "call.mp4") do |asked|
      doc.attach_recording_from_url!("https://files.example.com/call.mp4", resolver: resolver)
      assert_same resolver, asked.first.last[:resolver]
    end
  end
end
