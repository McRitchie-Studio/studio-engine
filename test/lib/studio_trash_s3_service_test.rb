# frozen_string_literal: true

require_relative "../test_helper"
require "active_storage"
require "active_storage/service"
require "active_storage/service/studio_trash_s3_service"

# [unit] ActiveStorage::Service::StudioTrashS3Service: Active Storage's S3
# service with delete turned into a move under trash/.
#
# What each test pins, against a real Aws::S3::Client with stub_responses:
#   - delete(key) is head, copy, delete, in that order (Blob#purge ends here);
#   - a failed trash RE-RAISES and sends no delete (the row is already gone, so
#     a raise leaks the object; swallowing it would be a silent loss later);
#   - delete_prefixed stays the inherited HARD delete (variants are derived);
#   - both refuse a "*-production" bucket from a non-production process.
#
# The Rails accessor is the s3_qa_environment_test.rb seam; each file runs in
# its own process under bin/release-check.
module Rails
  class << self
    attr_accessor :env
  end

  FakeEnv = Struct.new(:name) do
    def production? = name == "production"
    def to_s = name
  end
end

class StudioTrashS3ServiceTest < Minitest::Test
  def setup
    @previous_qa = ENV["QA_ENV"]
    ENV.delete("QA_ENV")
    Rails.env = Rails::FakeEnv.new("production")
  end

  def teardown
    @previous_qa.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = @previous_qa
    Rails.env = nil
  end

  def service(bucket: "turf-monster-production")
    @service = ActiveStorage::Service::StudioTrashS3Service.new(bucket: bucket, stub_responses: true, region: "auto")
    @client = @service.client.client
    @client.stub_responses(:head_object, { content_length: 5, content_type: "image/jpeg" })
    @service
  end

  def operations
    @client.api_requests.map { |request| request[:operation_name] }
  end

  def test_it_is_an_s3_service
    assert_operator ActiveStorage::Service::StudioTrashS3Service, :<, ActiveStorage::Service::S3Service
  end

  def test_delete_moves_the_blob_under_trash
    service.delete("k3y")

    assert_equal %i[head_object copy_object delete_object], operations
    copy = @client.api_requests[1][:params]
    assert_match %r{\Atrash/\d{4}-\d{2}-\d{2}/\d+/k3y\z}, copy[:key]
    assert_equal "turf-monster-production/k3y", copy[:copy_source]
    assert_equal "image/jpeg", copy[:metadata]["blob-content-type"]
    assert_equal "5", copy[:metadata]["blob-byte-size"]
    assert_equal "production", copy[:metadata]["deleted-env"]
  end

  def test_a_failed_trash_raises_and_never_deletes
    service
    @client.stub_responses(:copy_object, "InternalError")

    _out, err = capture_io do
      assert_raises(Aws::S3::Errors::InternalError) { @service.delete("k3y") }
    end
    refute_includes operations, :delete_object
    assert_match(/trash of turf-monster-production\/k3y failed, object left in place/, err)
  end

  def test_delete_prefixed_stays_a_hard_delete
    service
    @client.stub_responses(:list_objects, { contents: [{ key: "variants/k3y/a" }, { key: "variants/k3y/b" }] })
    @client.stub_responses(:list_objects_v2, { contents: [{ key: "variants/k3y/a" }, { key: "variants/k3y/b" }] })

    @service.delete_prefixed("variants/k3y/")
    assert_includes operations, :delete_objects
    refute_includes operations, :copy_object, "variants are regenerable; they are not trashed"
  end

  def test_a_non_production_process_may_not_delete_from_a_production_bucket
    Rails.env = Rails::FakeEnv.new("development")
    service

    assert_raises(Studio::S3::Trash::ProductionBucketRefused) do
      capture_io { @service.delete("k3y") }
    end
    assert_raises(Studio::S3::Trash::ProductionBucketRefused) { @service.delete_prefixed("variants/k3y/") }
    assert_empty operations
  end

  def test_a_qa_process_may_delete_from_its_dev_bucket
    ENV["QA_ENV"] = "true"
    service(bucket: "turf-monster-dev").delete("k3y")

    assert_equal %i[head_object copy_object delete_object], operations
    assert_equal "qa", @client.api_requests[1][:params][:metadata]["deleted-env"]
  end
end
