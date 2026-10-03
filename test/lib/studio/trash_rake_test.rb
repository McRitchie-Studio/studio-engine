# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/s3"
require "aws-sdk-s3"
require "rake"

# [unit] rake studio:trash:list and studio:trash:restore, loaded from the
# engine's own .rake file against Studio::S3 with a stubbed client.
#
# The mapping these pin: list finds a key's trash copies whether you name the
# LOGICAL key (what you passed to Studio::S3.delete) or the real one, and
# restore copies trash/<date>/<ms>/<key> back to <key> and prints the blob
# rebuild for Active Storage.
class TrashRakeTest < Minitest::Test
  RAKE_FILE = File.expand_path("../../../lib/tasks/studio_trash.rake", __dir__)
  TRASH_KEY = "trash/2026-10-01/1790875805123/mcritchie-industries/banners/a.png"

  def setup
    @previous_bucket_prefix = Studio.s3_bucket_prefix
    @previous_key_prefix = Studio.s3_key_prefix
    Studio.s3_bucket_prefix = "mcritchie-studio"
    Studio.s3_key_prefix = "mcritchie-industries/"
    @client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    Studio::S3.instance_variable_set(:@client, @client)

    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load RAKE_FILE
  end

  def teardown
    Studio.s3_bucket_prefix = @previous_bucket_prefix
    Studio.s3_key_prefix = @previous_key_prefix
    Studio::S3.reset!
    Rake.application = Rake::Application.new
  end

  def test_list_finds_a_logical_keys_trash_copies
    @client.stub_responses(:list_objects_v2, {
      contents: [{ key: TRASH_KEY, size: 9 }, { key: "trash/2026-10-01/2/mcritchie-industries/banners/b.png", size: 1 }]
    })

    out, = capture_io { Rake::Task["studio:trash:list"].invoke("banners/a.png") }
    assert_match(/1 trashed object\(s\) in mcritchie-studio-dev for banners\/a\.png/, out)
    assert_includes out, TRASH_KEY
    refute_includes out, "banners/b.png"
  end

  def test_restore_maps_the_trash_key_back_to_its_original
    @client.stub_responses(:head_object, [
      { content_length: 9, content_type: "image/png", etag: '"0cc175b9c0f1b6a831c399e269772661"' },
      "NotFound",
      { content_length: 9, content_type: "image/png",
        metadata: { "blob-checksum" => "DMF1ucDxtqgxw5niaXcmYQ==", "blob-byte-size" => "9" } }
    ])

    out, = capture_io { Rake::Task["studio:trash:restore"].invoke(TRASH_KEY) }
    copy = @client.api_requests.find { |request| request[:operation_name] == :copy_object }[:params]
    assert_equal "mcritchie-industries/banners/a.png", copy[:key]
    assert_equal "mcritchie-studio-dev/#{TRASH_KEY}", copy[:copy_source]
    assert_includes out, "Restored mcritchie-studio-dev/mcritchie-industries/banners/a.png"
    assert_includes out, 'checksum: "DMF1ucDxtqgxw5niaXcmYQ=="'
    assert_includes out, "byte_size: 9"
  end

  def test_restore_of_a_non_trash_key_aborts_without_writing
    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["studio:trash:restore"].invoke("banners/a.png") }
    end
    assert_match(/not a trash key/, err)
    assert_empty @client.api_requests
  end
end
