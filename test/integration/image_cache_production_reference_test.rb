# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "aws-sdk-s3"
require "tmpdir"

require_relative "../../db/migrate/20261006120003_ensure_image_caches_table"
require_relative "../../db/migrate/20261010120000_add_stored_in_to_image_caches"

# [integration] Seed assets REFERENCE production. A non-production process
# records an ImageCache row pointing at production's copy of an object instead
# of uploading a duplicate into the dev bucket; uploads still land in, and
# resolve on, the process's own bucket; production apps are untouched.
#
# Real ActiveRecord against the dummy app's database, the engine's migrations
# building the table; a stubbed Aws::S3::Client (stub_responses) whose recorded
# requests are the assertions. No network.
class ImageCacheProductionReferenceTest < ActiveSupport::TestCase
  PROD_HOST = "https://assets.turfmonster.media"
  DEV_HOST = "https://assets-dev.turfmonster.media"
  PREFIX = "headshots/nfl/seattle-seahawks/kenneth-walker-iii"
  SOURCE_URL = "https://a.espncdn.com/i/headshots/nfl/players/full/4567048.png"
  SETTINGS = %i[s3_bucket_prefix s3_key_prefix s3_region s3_endpoint s3_public_url s3_production_public_url].freeze

  # label => [Rails.env, QA_ENV, the process's own public host]
  ENVIRONMENTS = {
    "production" => ["production", nil, PROD_HOST],
    "qa" => ["production", "true", DEV_HOST],
    "development" => ["development", nil, DEV_HOST]
  }.freeze

  def connection = ActiveRecord::Base.connection

  def migrate(migration, direction = :up)
    ActiveRecord::Migration.suppress_messages { migration.new.migrate(direction) }
    ImageCache.reset_column_information
  end

  setup do
    @previous = SETTINGS.to_h { |name| [name, Studio.public_send(name)] }
    @previous_qa = ENV["QA_ENV"]
    @previous_env = Rails.env
    connection.drop_table(:image_caches, if_exists: true)
    migrate(EnsureImageCachesTable)
    migrate(AddStoredInToImageCaches)

    Studio.s3_bucket_prefix = "turf-monster"
    Studio.s3_key_prefix = nil
    Studio.s3_region = "auto"
    Studio.s3_endpoint = "https://account.r2.cloudflarestorage.com"
    Studio.s3_production_public_url = PROD_HOST
    as("development")
    Studio::S3.reset!
    @client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    Studio::S3.instance_variable_set(:@client, @client)

    @dir = Dir.mktmpdir
    @source = File.join(@dir, "headshot.png")
    File.binwrite(@source, "\x89PNG fake bytes".b)
  end

  teardown do
    @previous.each { |name, value| Studio.public_send("#{name}=", value) }
    @previous_qa.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = @previous_qa
    Rails.env = @previous_env
    Studio::S3.reset!
    connection.drop_table(:image_caches, if_exists: true)
    ImageCache.reset_column_information
    FileUtils.rm_rf(@dir)
  end

  # Sets the process up as `label`: Rails.env, QA_ENV, and the own public host
  # that environment's R2_PUBLIC_URL names.
  def as(label)
    rails_env, qa, host = ENVIRONMENTS.fetch(label)
    Rails.env = rails_env
    qa ? ENV["QA_ENV"] = qa : ENV.delete("QA_ENV")
    Studio.s3_public_url = host
  end

  def operations = @client.api_requests.map { |r| r[:operation_name] }
  def requests_for(op) = @client.api_requests.select { |r| r[:operation_name] == op }.map { |r| r[:params] }

  def found = { content_length: 4096, content_type: "image/png" }

  def seed!(widths: [], source_path: @source)
    Studio::ImageCache.reference_or_cache!(owner: nil, purpose: "headshot", key_prefix: PREFIX, widths: widths,
                                           source_url: SOURCE_URL, source_path: source_path)
  end

  # ─── the migration installs cleanly ──────────────────────────────────────

  test "migration adds a nullable stored_in and leaves existing rows reading as own" do
    connection.drop_table(:image_caches)
    migrate(EnsureImageCachesTable)
    ImageCache.create!(purpose: "headshot", variant: "400", s3_key: "#{PREFIX}/400.png")

    migrate(AddStoredInToImageCaches)
    column = connection.columns(:image_caches).find { |c| c.name == "stored_in" }
    assert column, "stored_in added"
    assert column.null, "nullable"
    assert_nil column.default, "no default: no row is rewritten"

    row = ImageCache.sole
    assert_nil row.stored_in
    refute row.production_reference?
    assert_equal "#{DEV_HOST}/#{PREFIX}/400.png", row.url
  end

  test "migration is idempotent, reversible, and a no-op on a host without the table" do
    migrate(AddStoredInToImageCaches) # second run
    assert_equal 1, connection.columns(:image_caches).count { |c| c.name == "stored_in" }

    migrate(AddStoredInToImageCaches, :down)
    refute ImageCache.stored_in_column?

    connection.drop_table(:image_caches)
    migrate(AddStoredInToImageCaches)
    migrate(AddStoredInToImageCaches, :down)
    refute connection.table_exists?(:image_caches), "the guard must not create the table"
  end

  # ─── URL resolution: environment x marker ────────────────────────────────

  test "url resolves for every environment and marker" do
    expected = {
      ["production", nil] => PROD_HOST, ["production", "own"] => PROD_HOST, ["production", "production"] => PROD_HOST,
      ["qa", nil] => DEV_HOST, ["qa", "own"] => DEV_HOST, ["qa", "production"] => PROD_HOST,
      ["development", nil] => DEV_HOST, ["development", "own"] => DEV_HOST, ["development", "production"] => PROD_HOST
    }
    rows = [nil, "own", "production"].to_h do |marker|
      [marker, ImageCache.create!(purpose: "headshot", variant: marker || "unset", s3_key: "#{PREFIX}/#{marker}.png",
                                  stored_in: marker)]
    end

    expected.each do |(label, marker), host|
      as(label)
      assert_equal "#{host}/#{PREFIX}/#{marker}.png", rows.fetch(marker).url, "#{label} x #{marker.inspect}"
    end
  end

  test "a production reference off production with no production host raises rather than guess" do
    row = ImageCache.create!(purpose: "headshot", variant: "400", s3_key: "#{PREFIX}/400.png", stored_in: "production")
    Studio.s3_production_public_url = nil
    assert_raises(Studio::S3::NotConfigured) { row.url }
  end

  test "stored_in accepts only own and production" do
    row = ImageCache.new(purpose: "headshot", variant: "400", s3_key: "#{PREFIX}/400.png", stored_in: "dev")
    refute row.valid?
    assert row.errors.of_kind?(:stored_in, :inclusion)
  end

  test "url and validation work on a host that has not installed the migration" do
    migrate(AddStoredInToImageCaches, :down)
    row = ImageCache.create!(purpose: "headshot", variant: "400", s3_key: "#{PREFIX}/400.png")
    refute row.production_reference?
    assert_equal "#{DEV_HOST}/#{PREFIX}/400.png", row.url
  end

  # ─── reference_or_cache!: the seeder helper ──────────────────────────────

  test "every variant production holds is referenced; nothing is fetched or uploaded" do
    @client.stub_responses(:head_object, found)
    rows = seed!(widths: [400], source_path: File.join(@dir, "absent.png")) # reading it would raise

    assert_equal %i[head_object head_object], operations
    assert_equal %w[turf-monster-production], requests_for(:head_object).map { |p| p[:bucket] }.uniq
    assert_equal %W[#{PREFIX}/original.png #{PREFIX}/400.png], requests_for(:head_object).map { |p| p[:key] }

    assert_equal %w[original 400], rows.keys
    rows.each_value do |row|
      assert_equal "production", row.reload.stored_in
      assert_equal 4096, row.bytes
      assert_equal SOURCE_URL, row.source_url
      assert row.url.start_with?("#{PROD_HOST}/#{PREFIX}/"), row.url
    end
  end

  test "a variant production lacks falls back to an upload into the own bucket" do
    @client.stub_responses(:head_object, ["NotFound", found])
    rows = seed!(widths: [400])

    assert_equal %i[head_object head_object put_object], operations
    put = requests_for(:put_object).sole
    assert_equal "turf-monster-dev", put[:bucket]
    assert_equal "#{PREFIX}/original.png", put[:key]

    original = rows.fetch("original").reload
    assert_nil original.stored_in, "an upload is the process's own object"
    assert_equal "#{DEV_HOST}/#{PREFIX}/original.png", original.url
    assert_equal "production", rows.fetch("400").reload.stored_in
    assert_equal "#{PROD_HOST}/#{PREFIX}/400.png", rows.fetch("400").url
  end

  test "rows already cached are left alone and asked about no further" do
    @client.stub_responses(:head_object, found)
    seed!
    @client.api_requests.clear
    seed!
    assert_empty operations
    assert_equal 1, ImageCache.count
  end

  test "a HEAD refused for any reason but not-found raises and uploads nothing" do
    @client.stub_responses(:head_object, "Forbidden")
    assert_raises(Aws::S3::Errors::Forbidden) { seed! }
    refute_includes operations, :put_object
    assert_equal 0, ImageCache.count
  end

  test "in production it is exactly cache!: no HEAD, own upload, own URL" do
    as("production")
    rows = seed!

    assert_equal %i[put_object], operations
    assert_equal "turf-monster-production", requests_for(:put_object).sole[:bucket]
    row = rows.fetch("original").reload
    assert_nil row.stored_in
    assert_equal "#{PROD_HOST}/#{PREFIX}/original.png", row.url
  end

  test "with no production host configured it is exactly cache! off production" do
    Studio.s3_production_public_url = nil
    rows = seed!

    assert_equal %i[put_object], operations
    assert_equal "turf-monster-dev", requests_for(:put_object).sole[:bucket]
    assert_nil rows.fetch("original").reload.stored_in
  end

  test "references enabled on a host without the column refuse before any request" do
    migrate(AddStoredInToImageCaches, :down)
    error = assert_raises(Studio::ImageCache::MissingStoredInColumn) { seed! }
    assert_match(/install:migrations/, error.message)
    assert_empty operations
  end

  test "cache! itself never references production" do
    @client.stub_responses(:head_object, found)
    rows = Studio::ImageCache.cache!(owner: nil, purpose: "headshot", key_prefix: PREFIX, widths: [],
                                     source_url: SOURCE_URL, source_path: @source)
    assert_equal %i[put_object], operations
    assert_nil rows.fetch("original").reload.stored_in
  end

  # ─── reads and deletes ───────────────────────────────────────────────────

  test "download reads the bucket that holds the object" do
    @client.stub_responses(:get_object, { body: "bytes" })
    ref = ImageCache.create!(purpose: "headshot", variant: "400", s3_key: "#{PREFIX}/400.png", stored_in: "production")
    own = ImageCache.create!(purpose: "headshot", variant: "100", s3_key: "#{PREFIX}/100.png")

    assert_equal "bytes", ref.download
    assert_equal "bytes", own.download
    assert_equal %w[turf-monster-production turf-monster-dev], requests_for(:get_object).map { |p| p[:bucket] }
  end

  # The production-referenced object is production's. Off production, deleting
  # the row's object sends no request to EITHER bucket (the dev bucket may hold
  # an unrelated object under the same key); the row itself destroys normally.
  test "a non-production process never deletes a production reference's object" do
    ref = ImageCache.create!(purpose: "headshot", variant: "400", s3_key: "#{PREFIX}/400.png", stored_in: "production")
    %w[qa development].each do |label|
      as(label)
      assert_nil ref.delete_object!, label
    end
    assert_empty operations
    ref.destroy!
    assert_empty operations
  end

  test "an own row's object is deleted from the own bucket only" do
    @client.stub_responses(:head_object, found)
    own = ImageCache.create!(purpose: "headshot", variant: "400", s3_key: "#{PREFIX}/400.png")
    own.delete_object!
    assert_equal %w[turf-monster-dev], @client.api_requests.map { |r| r[:params][:bucket] }.uniq
  end

  test "the production bucket a reference names is refused by the delete guard off production" do
    %w[qa development].each do |label|
      as(label)
      assert_raises(Studio::S3::Trash::ProductionBucketRefused, label) do
        Studio::S3.guard_production_bucket!(Studio::S3.production_bucket)
      end
    end
  end
end
