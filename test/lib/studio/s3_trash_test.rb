# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/s3"
require "aws-sdk-s3"

# [unit] The three-day grace period on a delete (Studio::S3::Trash) and the
# Studio::S3 surface over it: delete moves, purge! deletes, list hides trash,
# and a non-production process never deletes from a production bucket.
#
# Every client here is a real Aws::S3::Client with stub_responses, so the
# assertions read the REQUESTS the SDK would have sent (api_requests), in order,
# with their params. Nothing reaches a network.
#
# THE ORDER IS THE CONTRACT. Copy, THEN delete; a failed copy never deletes.
# Reverse it, or drop the raise, and a user's photo is gone the first time R2
# refuses a copy. The copy-failure test is the one that bites on that.
#
# Rails carries no `env` in the engine's unit env (only rails-html-sanitizer's
# namespace-only module, sometimes). The accessor below is the same seam
# s3_qa_environment_test.rb uses; bin/release-check runs each file in its own
# process, so it cannot leak into a sibling.
module Rails
  class << self
    attr_accessor :env
  end

  FakeEnv = Struct.new(:name) do
    def production? = name == "production"
    def to_s = name
  end
end

class S3TrashTest < Minitest::Test
  BUCKET = "turf-monster-dev"
  KEY = "avatars/user 7/photo.png"
  NOW = Time.utc(2026, 10, 1, 17, 30, 5, 123_456)
  SETTINGS = %i[s3_bucket_prefix s3_key_prefix s3_region s3_endpoint
                s3_access_key_id s3_secret_access_key s3_public_url].freeze

  def setup
    @previous = SETTINGS.to_h { |name| [name, Studio.public_send(name)] }
    @previous_qa = ENV["QA_ENV"]
    ENV.delete("QA_ENV")
    Studio.s3_bucket_prefix = "turf-monster"
    Studio.s3_key_prefix = nil
    Studio.s3_region = "auto"
    Studio::S3.reset!
    Rails.env = Rails::FakeEnv.new("development")
    @client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    @client.stub_responses(:head_object, {
      content_length: 2048,
      content_type: "image/png",
      cache_control: "public, max-age=31536000",
      etag: '"0cc175b9c0f1b6a831c399e269772661"',
      metadata: { "uploaded-by" => "alex" }
    })
  end

  def teardown
    @previous.each { |name, value| Studio.public_send("#{name}=", value) }
    @previous_qa.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = @previous_qa
    Studio::S3.reset!
    Rails.env = nil
  end

  def operations
    @client.api_requests.map { |request| request[:operation_name] }
  end

  def params_for(operation)
    @client.api_requests.find { |request| request[:operation_name] == operation }&.dig(:params)
  end

  def use_stub_client!
    Studio::S3.instance_variable_set(:@client, @client)
  end

  # --- Trash.trash! ---------------------------------------------------------

  def test_trash_copies_then_deletes_in_that_order
    trash_key = Studio::S3::Trash.trash!(client: @client, bucket: BUCKET, key: KEY, env: "production", now: NOW)

    assert_equal %i[head_object copy_object delete_object], operations,
                 "the copy must land BEFORE the delete is sent"
    assert_equal "trash/2026-10-01/1790875805123/#{KEY}", trash_key
    assert_equal({ bucket: BUCKET, key: KEY }, params_for(:delete_object))
  end

  def test_the_copy_names_an_escaped_source_and_replaces_metadata
    Studio::S3::Trash.trash!(client: @client, bucket: BUCKET, key: KEY, env: "qa", now: NOW)
    copy = params_for(:copy_object)

    assert_equal "#{BUCKET}/avatars/user%207/photo.png", copy[:copy_source],
                 "CopySource is url-encoded per segment, slashes kept"
    assert_equal BUCKET, copy[:bucket], "trash lives in the SAME bucket, so the lifecycle rule covers it"
    assert_equal "REPLACE", copy[:metadata_directive]
    assert_equal "image/png", copy[:content_type], "REPLACE drops the content type unless it is carried"
    assert_equal "public, max-age=31536000", copy[:cache_control]
    meta = copy[:metadata]
    assert_equal KEY, meta["original-key"]
    assert_equal "2026-10-01T17:30:05Z", meta["deleted-at"]
    assert_equal "qa", meta["deleted-env"]
    assert_equal "alex", meta["uploaded-by"], "the object's own metadata rides along"
    assert_equal "2048", meta["blob-byte-size"]
    assert_equal "image/png", meta["blob-content-type"]
    assert_equal "DMF1ucDxtqgxw5niaXcmYQ==", meta["blob-checksum"],
                 "a single-part ETag is the hex MD5; Active Storage wants it base64"
  end

  def test_a_failed_copy_raises_and_never_deletes
    @client.stub_responses(:copy_object, "AccessDenied")

    assert_raises(Aws::S3::Errors::AccessDenied) do
      Studio::S3::Trash.trash!(client: @client, bucket: BUCKET, key: KEY, env: "production", now: NOW)
    end
    refute_includes operations, :delete_object, "a copy that failed must leave the original in place"
  end

  def test_an_object_already_gone_is_a_quiet_no_op
    @client.stub_responses(:head_object, "NotFound")

    assert_nil Studio::S3::Trash.trash!(client: @client, bucket: BUCKET, key: KEY, env: "production", now: NOW)
    assert_equal %i[head_object], operations
  end

  def test_an_object_over_five_gib_is_refused_and_left_in_place
    @client.stub_responses(:head_object, { content_length: Studio::S3::Trash::MAX_COPY_BYTES + 1 })

    error = assert_raises(Studio::S3::Trash::TooLarge) do
      Studio::S3::Trash.trash!(client: @client, bucket: BUCKET, key: KEY, env: "production", now: NOW)
    end
    assert_match(/NOT trashed and NOT deleted/, error.message)
    assert_equal %i[head_object], operations
  end

  def test_a_multipart_etag_records_no_checksum
    @client.stub_responses(:head_object, { content_length: 10, etag: '"0cc175b9c0f1b6a831c399e269772661-3"' })

    Studio::S3::Trash.trash!(client: @client, bucket: BUCKET, key: KEY, env: "production", now: NOW)
    refute params_for(:copy_object)[:metadata].key?("blob-checksum"),
           "a multipart ETag is not an MD5 of the object; recording it would fail the blob's integrity check"
  end

  def test_a_non_ascii_filename_is_stored_encoded_and_read_back
    @client.stub_responses(:head_object, {
      content_length: 10,
      content_disposition: "attachment; filename=\"r?sum?.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"
    })

    Studio::S3::Trash.trash!(client: @client, bucket: BUCKET, key: KEY, env: "production", now: NOW)
    stored = params_for(:copy_object)[:metadata]["blob-filename"]
    assert stored.ascii_only?, "metadata travels as headers and must be ASCII"

    @client.stub_responses(:head_object, { content_length: 10, metadata: { "blob-filename" => stored } })
    attributes = Studio::S3::Trash.blob_attributes(client: @client, bucket: BUCKET, trash_key: "trash/2026-10-01/1/#{KEY}")
    assert_equal "résumé.pdf", attributes[:filename]
    assert_equal KEY, attributes[:key]
  end

  # --- key mapping ------------------------------------------------------------

  def test_original_key_is_read_from_the_trash_key_path
    trash_key = Studio::S3::Trash.key_for(KEY, now: NOW)

    assert_equal KEY, Studio::S3::Trash.original_key(trash_key)
    assert_equal "mcritchie-industries/a/b.png",
                 Studio::S3::Trash.original_key("trash/2026-10-01/42/mcritchie-industries/a/b.png")
    assert_raises(Studio::S3::Trash::NotTrash) { Studio::S3::Trash.original_key(KEY) }
    assert_raises(Studio::S3::Trash::NotTrash) { Studio::S3::Trash.original_key("trash/2026-10-01/42/") }
  end

  # --- restore! ---------------------------------------------------------------

  def test_restore_copies_back_to_the_original_key_without_the_trash_record
    trash_key = "trash/2026-10-01/1759339805123/#{KEY}"
    @client.stub_responses(:head_object, [
      { content_length: 10, content_type: "image/png",
        metadata: { "original-key" => KEY, "deleted-at" => "x", "deleted-env" => "production",
                    "blob-byte-size" => "10", "uploaded-by" => "alex" } },
      "NotFound" # nothing at the original key
    ])

    assert_equal KEY, Studio::S3::Trash.restore!(client: @client, bucket: BUCKET, trash_key: trash_key)
    copy = params_for(:copy_object)
    assert_equal KEY, copy[:key]
    assert_equal "#{BUCKET}/trash/2026-10-01/1759339805123/avatars/user%207/photo.png", copy[:copy_source]
    assert_equal "image/png", copy[:content_type]
    assert_equal({ "uploaded-by" => "alex" }, copy[:metadata])
    refute_includes operations, :delete_object, "the trash copy stays until the lifecycle rule expires it"
  end

  def test_restore_refuses_to_overwrite_a_live_object_unless_told
    trash_key = "trash/2026-10-01/1/#{KEY}"

    assert_raises(Studio::S3::Trash::RestoreConflict) do
      Studio::S3::Trash.restore!(client: @client, bucket: BUCKET, trash_key: trash_key)
    end
    refute_includes operations, :copy_object

    Studio::S3::Trash.restore!(client: @client, bucket: BUCKET, trash_key: trash_key, overwrite: true)
    assert_includes operations, :copy_object
  end

  # --- list -------------------------------------------------------------------

  def test_trash_list_pages_and_filters_by_original_key
    @client.stub_responses(:list_objects_v2, [
      { contents: [{ key: "trash/2026-10-01/2/#{KEY}" }, { key: "trash/2026-10-01/3/other.png" }],
        is_truncated: true, next_continuation_token: "t1" },
      { contents: [{ key: "trash/2026-09-30/1/#{KEY}" }, { key: "trash/stray" }], is_truncated: false }
    ])

    keys = Studio::S3::Trash.list(client: @client, bucket: BUCKET, key: KEY).map(&:key)
    assert_equal ["trash/2026-09-30/1/#{KEY}", "trash/2026-10-01/2/#{KEY}"], keys
    assert_equal "t1", @client.api_requests.last[:params][:continuation_token]
  end

  # --- Studio::S3 -------------------------------------------------------------

  def test_studio_s3_delete_trashes_the_full_key
    use_stub_client!
    Studio.s3_key_prefix = "mcritchie-industries/"

    trash_key = Studio::S3.delete(key: "banners/a.png")
    assert_equal %i[head_object copy_object delete_object], operations
    assert_match %r{\Atrash/\d{4}-\d{2}-\d{2}/\d+/mcritchie-industries/banners/a\.png\z}, trash_key.to_s,
                 "trash sits at the bucket root so one lifecycle rule covers every app sharing it"
    assert_equal "development", params_for(:copy_object)[:metadata]["deleted-env"]
  end

  def test_studio_s3_purge_is_a_hard_delete
    use_stub_client!

    Studio::S3.purge!(key: "banners/a.png")
    assert_equal %i[delete_object], operations
    assert_equal({ bucket: "turf-monster-dev", key: "banners/a.png" }, params_for(:delete_object))
  end

  def test_studio_s3_list_hides_trash_unless_asked
    use_stub_client!
    @client.stub_responses(:list_objects_v2, {
      contents: [{ key: "banners/a.png" }, { key: "trash/2026-10-01/1/banners/b.png" }]
    })

    assert_equal ["banners/a.png"], Studio::S3.list
    assert_equal ["banners/a.png", "trash/2026-10-01/1/banners/b.png"], Studio::S3.list(include_trash: true)
  end

  # --- the production guard ---------------------------------------------------

  def test_qa_and_dev_processes_may_not_touch_a_production_bucket
    ENV["QA_ENV"] = "true"
    Rails.env = Rails::FakeEnv.new("production") # a QA app runs Rails as production
    assert_raises(Studio::S3::Trash::ProductionBucketRefused) do
      Studio::S3.guard_production_bucket!("turf-monster-production")
    end

    ENV.delete("QA_ENV")
    Rails.env = Rails::FakeEnv.new("development")
    error = assert_raises(Studio::S3::Trash::ProductionBucketRefused) do
      Studio::S3.guard_production_bucket!("turf-monster-production")
    end
    assert_match(/development/, error.message)
  end

  def test_production_may_touch_production_and_anyone_may_touch_dev
    Rails.env = Rails::FakeEnv.new("production")
    assert_nil Studio::S3.guard_production_bucket!("turf-monster-production")

    Rails.env = Rails::FakeEnv.new("development")
    assert_nil Studio::S3.guard_production_bucket!("turf-monster-dev")
  end

  # delete and purge! both pass through the guard BEFORE any request. Studio::S3
  # derives its bucket from the same environment, so a mismatch takes a forced
  # bucket name — which is exactly the case the guard exists for.
  def test_delete_and_purge_refuse_before_sending_anything
    use_stub_client!
    Studio::S3.singleton_class.alias_method(:__real_bucket, :bucket)
    Studio::S3.define_singleton_method(:bucket) { "turf-monster-production" }

    assert_raises(Studio::S3::Trash::ProductionBucketRefused) { Studio::S3.delete(key: "a.png") }
    assert_raises(Studio::S3::Trash::ProductionBucketRefused) { Studio::S3.purge!(key: "a.png") }
    assert_empty operations
  ensure
    Studio::S3.singleton_class.alias_method(:bucket, :__real_bucket)
  end
end
