# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/s3"
require "aws-sdk-s3"

# [unit] Studio::S3's read-only production surface, which lets a non-production
# process REFERENCE a seed asset in the production bucket instead of uploading a
# copy: production_url, production_references?, production_head and
# production_download. And the other half of the contract: no non-production
# process can delete from the production bucket.
#
# A real Aws::S3::Client with stub_responses; the assertions read the requests
# the SDK would have sent. Nothing reaches a network. The Rails.env seam is the
# one s3_trash_test.rb uses; bin/release-check runs each file in its own process.
module Rails
  class << self
    attr_accessor :env
  end

  FakeEnv = Struct.new(:name) do
    def production? = name == "production"
    def to_s = name
  end
end

class S3ProductionReferenceTest < Minitest::Test
  PROD_HOST = "https://assets.turfmonster.media"
  DEV_HOST = "https://assets-dev.turfmonster.media"
  KEY = "headshots/nfl/seattle-seahawks/jaxon-smith-njigba/400.png"
  SETTINGS = %i[s3_bucket_prefix s3_key_prefix s3_region s3_endpoint s3_access_key_id
                s3_secret_access_key s3_public_url s3_production_public_url].freeze

  # Every process this runs as: the label, Rails.env, QA_ENV.
  ENVIRONMENTS = {
    "production" => ["production", nil],
    "qa" => ["production", "true"],
    "development" => ["development", nil]
  }.freeze

  def setup
    @previous = SETTINGS.to_h { |name| [name, Studio.public_send(name)] }
    @previous_qa = ENV["QA_ENV"]
    Studio.s3_bucket_prefix = "turf-monster"
    Studio.s3_key_prefix = nil
    Studio.s3_region = "auto"
    Studio.s3_endpoint = "https://account.r2.cloudflarestorage.com"
    Studio.s3_public_url = DEV_HOST
    Studio.s3_production_public_url = PROD_HOST
    Studio::S3.reset!
    as("development")
    @client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    Studio::S3.instance_variable_set(:@client, @client)
  end

  def teardown
    @previous.each { |name, value| Studio.public_send("#{name}=", value) }
    @previous_qa.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = @previous_qa
    Studio::S3.reset!
    Rails.env = nil
  end

  def as(label)
    rails_env, qa = ENVIRONMENTS.fetch(label)
    Rails.env = Rails::FakeEnv.new(rails_env)
    qa ? ENV["QA_ENV"] = qa : ENV.delete("QA_ENV")
  end

  def requests = @client.api_requests

  # ─── production_url ───────────────────────────────────────────────────────

  def test_production_url_is_the_production_host_off_production
    %w[qa development].each do |label|
      as(label)
      assert_equal "#{PROD_HOST}/#{KEY}", Studio::S3.production_url(key: KEY), label
      assert_equal "#{DEV_HOST}/#{KEY}", Studio::S3.url(key: KEY), "#{label}: own URLs are unchanged"
    end
  end

  # Production's own host IS production's: production_url is exactly url, and
  # the knob is never read (an app may set it, or not, without effect).
  def test_production_url_in_production_is_url_whatever_the_knob_says
    as("production")
    Studio.s3_public_url = PROD_HOST
    [PROD_HOST, nil, "https://somewhere-else.example"].each do |knob|
      Studio.s3_production_public_url = knob
      assert_equal Studio::S3.url(key: KEY), Studio::S3.production_url(key: KEY), knob.inspect
      assert_equal "#{PROD_HOST}/#{KEY}", Studio::S3.production_url(key: KEY)
    end
  end

  def test_production_url_keeps_the_key_namespace_and_tolerates_a_trailing_slash
    Studio.s3_key_prefix = "mcritchie-industries"
    Studio.s3_production_public_url = "#{PROD_HOST}/"
    assert_equal "#{PROD_HOST}/mcritchie-industries/#{KEY}", Studio::S3.production_url(key: KEY)
  end

  # Never fall back to this environment's host: the object is not there, and the
  # result would be a broken image nobody is told about.
  def test_production_url_raises_off_production_without_the_knob
    Studio.s3_production_public_url = nil
    error = assert_raises(Studio::S3::NotConfigured) { Studio::S3.production_url(key: KEY) }
    assert_match(/s3_production_public_url not set/, error.message)
  end

  # ─── production_references? ───────────────────────────────────────────────

  def test_production_references_needs_a_non_production_process_and_the_knob
    { "production" => false, "qa" => true, "development" => true }.each do |label, expected|
      as(label)
      assert_equal expected, Studio::S3.production_references?, label
    end
    as("development")
    ["", nil].each do |blank|
      Studio.s3_production_public_url = blank
      refute Studio::S3.production_references?, "knob #{blank.inspect} turns references off"
    end
  end

  # ─── production_head / production_exists? (read-only) ─────────────────────

  def test_production_bucket_is_production_in_every_environment
    ENVIRONMENTS.each_key do |label|
      as(label)
      assert_equal "turf-monster-production", Studio::S3.production_bucket, label
    end
    as("development")
    assert_equal "turf-monster-dev", Studio::S3.bucket, "the own bucket is untouched"
  end

  def test_production_head_reads_the_production_bucket_and_answers_metadata
    @client.stub_responses(:head_object, { content_length: 4096, content_type: "image/png" })
    head = Studio::S3.production_head(key: KEY)

    assert_equal 4096, head.content_length
    assert_equal [:head_object], requests.map { |r| r[:operation_name] }
    assert_equal({ bucket: "turf-monster-production", key: KEY }, requests.first[:params])
    assert Studio::S3.production_exists?(key: KEY)
  end

  def test_production_head_is_nil_when_production_lacks_the_key
    @client.stub_responses(:head_object, "NotFound")
    assert_nil Studio::S3.production_head(key: KEY)
    refute Studio::S3.production_exists?(key: KEY)
  end

  # A 403 (a token without Item Read on production) is not "absent". Read as
  # absent, it would quietly upload a dev copy of every seed asset.
  def test_production_head_raises_on_anything_but_not_found
    @client.stub_responses(:head_object, "Forbidden")
    assert_raises(Aws::S3::Errors::Forbidden) { Studio::S3.production_head(key: KEY) }
  end

  def test_production_download_reads_production_and_download_reads_own
    @client.stub_responses(:get_object, { body: "bytes" })
    assert_equal "bytes", Studio::S3.production_download(key: KEY, max_bytes: 10)
    assert_equal "bytes", Studio::S3.download(key: KEY)

    gets = requests.select { |r| r[:operation_name] == :get_object }.map { |r| r[:params].slice(:bucket, :key, :range) }
    assert_equal({ bucket: "turf-monster-production", key: KEY, range: "bytes=0-9" }, gets[0])
    assert_equal({ bucket: "turf-monster-dev", key: KEY }, gets[1])
  end

  # ─── no non-production delete reaches production ──────────────────────────

  # The engine's existing guard, proved against the bucket a production
  # reference names. Off production it refuses before any request is sent.
  def test_production_bucket_delete_guard_refuses_qa_and_development
    %w[qa development].each do |label|
      as(label)
      error = assert_raises(Studio::S3::Trash::ProductionBucketRefused, label) do
        Studio::S3.guard_production_bucket!(Studio::S3.production_bucket)
      end
      assert_match(/refusing to delete from turf-monster-production/, error.message)
    end
    assert_empty requests
  end

  # delete and purge! target the process's own bucket, which off production is
  # the dev bucket, even for a key production also holds.
  def test_delete_and_purge_off_production_never_name_the_production_bucket
    @client.stub_responses(:head_object, { content_length: 1, content_type: "image/png" })
    %w[qa development].each do |label|
      as(label)
      Studio::S3.delete(key: KEY)
      Studio::S3.purge!(key: KEY)
    end
    buckets = requests.map { |r| r[:params][:bucket] }.uniq
    assert_equal ["turf-monster-dev"], buckets
  end

  # And if a non-production process is ever POINTED at the production bucket
  # (a hand-edited bucket name), delete and purge! refuse before any request.
  def test_delete_refuses_when_the_own_bucket_resolves_to_production_off_production
    original = Studio::S3.method(:bucket)
    Studio::S3.define_singleton_method(:bucket) { "turf-monster-production" }
    %w[qa development].each do |label|
      as(label)
      assert_raises(Studio::S3::Trash::ProductionBucketRefused, label) { Studio::S3.delete(key: KEY) }
      assert_raises(Studio::S3::Trash::ProductionBucketRefused, label) { Studio::S3.purge!(key: KEY) }
    end
    assert_empty requests
  ensure
    Studio::S3.singleton_class.send(:define_method, :bucket, original)
  end
end
