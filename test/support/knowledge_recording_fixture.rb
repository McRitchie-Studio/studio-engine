# frozen_string_literal: true

require "aws-sdk-s3"
require "tempfile"
# Loaded lazily by the model in production; the tests replace its methods, so
# they need the constant before any attach has run.
require "studio/knowledge_recording"

# Shared by the knowledge recording tests: the documents table as a consumer
# has it BEFORE the recording migration, a synthetic MP4, and a stubbed S3
# client wired into both Studio::S3 and Studio::S3::Multipart. Nothing reaches
# a bucket. Every name is invented.
module KnowledgeRecordingFixture
  # 28 bytes that open like an MP4 (an `ftyp` box, brand isom), then filler.
  MP4 = ("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00".b + "isomiso2mp41".b + ("\x00" * 2048)).freeze
  OGG = ("OggS\x00\x02".b + ("\x00" * 512)).freeze

  def self.create_old_table!(connection = ActiveRecord::Base.connection)
    connection.create_table :studio_knowledge_docs, force: true do |t|
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
      t.bigint :expectation_id
      t.timestamps
    end
    connection.add_index :studio_knowledge_docs, :s3_key, unique: true
  end

  def stub_storage!
    @previous_bucket_prefix = Studio.s3_bucket_prefix
    @previous_key_prefix = Studio.s3_key_prefix
    Studio.s3_bucket_prefix = "example-app"
    Studio.s3_key_prefix = nil
    @client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    @client.stub_responses(:create_multipart_upload, { upload_id: "upload-1" })
    @client.stub_responses(:upload_part, { etag: '"etag"' })
    @client.stub_responses(:head_object, ->(context) { { content_length: stored_size(context.params[:key]) } })
    Studio::S3.instance_variable_set(:@client, @client)
    require "studio/s3/multipart"
    Studio::S3::Multipart.instance_variable_set(:@client, @client)
    @recording_files = []
  end

  def unstub_storage!
    Studio.s3_bucket_prefix = @previous_bucket_prefix
    Studio.s3_key_prefix = @previous_key_prefix
    Studio::S3.reset!
    Studio::S3::Multipart.reset! if defined?(Studio::S3::Multipart)
    @recording_files&.each(&:close!)
  end

  # head_object answers the size of what was uploaded to that key.
  def stored_size(key)
    requests(:upload_part).select { |part| part[:key] == key }.sum { |part| part[:body].bytesize }
  end

  def recording_file(bytes = MP4, name: ["standup", ".mp4"])
    file = Tempfile.new(name)
    file.binmode
    file.write(bytes)
    file.flush
    @recording_files << file
    file.path
  end

  def operations = @client.api_requests.map { |request| request[:operation_name] }

  def requests(operation)
    @client.api_requests.select { |request| request[:operation_name] == operation }.map { |request| request[:params] }
  end
end
