# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/studio/s3/multipart"
require "aws-sdk-s3"
require "digest/md5"
require "tempfile"

# [unit] Studio::S3::Multipart.upload_file: a local file to the bucket in
# parts, never whole in memory.
#
# Every client is a real Aws::S3::Client with stub_responses, so the assertions
# read the requests the SDK would have sent, in order, and (for the checksum
# test) the HTTP headers it built. NOTHING HERE REACHES A BUCKET: that a live
# R2 bucket accepts this request shape is not proven by this file.
class S3MultipartTest < Minitest::Test
  MP = Studio::S3::Multipart
  PART = MP::MIN_PART_SIZE
  SETTINGS = %i[s3_bucket_prefix s3_key_prefix s3_region s3_endpoint
                s3_access_key_id s3_secret_access_key s3_public_url].freeze

  def setup
    @previous = SETTINGS.to_h { |name| [name, Studio.public_send(name)] }
    @previous_qa = ENV["QA_ENV"]
    ENV.delete("QA_ENV")
    Studio.s3_bucket_prefix = "example-app"
    Studio.s3_key_prefix = nil
    Studio.s3_region = "auto"
    Studio.s3_endpoint = nil
    Studio.s3_access_key_id = nil
    Studio.s3_secret_access_key = nil
    Studio::S3.reset!
    MP.reset!
    @client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    @client.stub_responses(:create_multipart_upload, { upload_id: "upload-1" })
    @client.stub_responses(:upload_part, ->(context) { { etag: "\"etag-#{context.params[:part_number]}\"" } })
    @files = []
  end

  def teardown
    @previous.each { |name, value| Studio.public_send("#{name}=", value) }
    @previous_qa.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = @previous_qa
    Studio::S3.reset!
    MP.reset!
    @files.each(&:close!)
  end

  def file_of(bytes)
    file = Tempfile.new(["multipart", ".bin"])
    file.binmode
    file.write(bytes)
    file.flush
    @files << file
    file.path
  end

  def stored!(size)
    @client.stub_responses(:head_object, { content_length: size })
  end

  def operations = @client.api_requests.map { |request| request[:operation_name] }

  def requests(operation)
    @client.api_requests.select { |request| request[:operation_name] == operation }.map { |request| request[:params] }
  end

  def upload(path, **options)
    MP.upload_file(key: "knowledge/acme/call.mp4", path: path, content_type: "video/mp4",
                   max_bytes: 64 * 1024 * 1024, part_size: PART, client: @client, **options)
  end

  def test_a_file_is_sent_in_parts_of_part_size_and_completed_in_order
    bytes = Random.new(1).bytes(PART * 2 + 1234)
    stored!(bytes.bytesize)
    result = upload(file_of(bytes))

    assert_equal %i[create_multipart_upload upload_part upload_part upload_part complete_multipart_upload head_object],
                 operations
    parts = requests(:upload_part)
    assert_equal [PART, PART, 1234], parts.map { |part| part[:body].bytesize }
    assert_equal bytes, parts.map { |part| part[:body] }.join, "every byte, once, in order"
    assert_equal [1, 2, 3], parts.map { |part| part[:part_number] }
    assert(parts.all? { |part| part[:upload_id] == "upload-1" })
    assert_equal parts.map { |part| Digest::MD5.base64digest(part[:body]) }, parts.map { |part| part[:content_md5] }

    complete = requests(:complete_multipart_upload).first
    assert_equal [{ etag: '"etag-1"', part_number: 1 }, { etag: '"etag-2"', part_number: 2 },
                  { etag: '"etag-3"', part_number: 3 }], complete[:multipart_upload][:parts]
    assert_equal "upload-1", complete[:upload_id]

    assert_equal "knowledge/acme/call.mp4", result.key
    assert_equal bytes.bytesize, result.byte_size
    assert_equal 3, result.parts
  end

  def test_the_object_is_created_with_the_callers_content_type_in_the_apps_bucket_and_namespace
    Studio.s3_key_prefix = "tenant"
    stored!(10)
    upload(file_of("0123456789"))

    create = requests(:create_multipart_upload).first
    assert_equal "example-app-dev", create[:bucket]
    assert_equal "tenant/knowledge/acme/call.mp4", create[:key]
    assert_equal "video/mp4", create[:content_type]
    assert_equal ["tenant/knowledge/acme/call.mp4"], requests(:upload_part).map { |part| part[:key] }.uniq
  end

  def test_a_small_file_is_one_part
    stored!(3)
    assert_equal 1, upload(file_of("abc")).parts
    assert_equal ["abc"], requests(:upload_part).map { |part| part[:body] }
  end

  def test_a_file_that_is_an_exact_multiple_of_the_part_size_sends_no_empty_part
    stored!(PART * 2)
    assert_equal 2, upload(file_of("z" * (PART * 2))).parts
  end

  # The memory bound: no read is ever larger than one part.
  def test_no_read_is_larger_than_one_part
    path = file_of("q" * (PART * 2 + 5))
    stored!(PART * 2 + 5)
    sizes = []
    original = File.instance_method(:read)
    File.send(:define_method, :read) do |*args|
      sizes << args.first if path == self.path
      original.bind(self).call(*args)
    end
    begin
      upload(path)
    ensure
      File.send(:define_method, :read, original)
    end
    assert_equal [PART], sizes.uniq, "every read names the part size; none reads the file whole"
  end

  def test_an_empty_file_is_refused_before_any_request
    error = assert_raises(Studio::S3::Error) { upload(file_of("")) }
    assert_match(/empty/, error.message)
    assert_empty operations
  end

  def test_a_file_over_the_cap_is_refused_before_any_request
    error = assert_raises(Studio::S3::Error) { upload(file_of("x" * 11), max_bytes: 10) }
    assert_match(/over the 10-byte cap/, error.message)
    assert_empty operations
  end

  def test_bad_bounds_are_argument_errors
    path = file_of("abc")
    assert_raises(ArgumentError) { upload(path, max_bytes: 0) }
    assert_raises(ArgumentError) { upload(path, max_bytes: nil) }
    assert_raises(ArgumentError) { upload(path, part_size: MP::MIN_PART_SIZE - 1) }
    assert_empty operations
  end

  def test_a_failed_part_aborts_the_upload_and_raises_the_parts_own_error
    @client.stub_responses(:upload_part, [{ etag: '"etag-1"' }, "InternalError"])
    assert_raises(Aws::S3::Errors::InternalError) { upload(file_of("x" * (PART + 1))) }

    assert_equal %i[create_multipart_upload upload_part upload_part abort_multipart_upload], operations
    assert_equal "upload-1", requests(:abort_multipart_upload).first[:upload_id]
  end

  def test_a_failed_completion_aborts_the_upload
    @client.stub_responses(:complete_multipart_upload, "InternalError")
    assert_raises(Aws::S3::Errors::InternalError) { upload(file_of("abc")) }
    assert_equal :abort_multipart_upload, operations.last
  end

  def test_a_failed_abort_does_not_hide_the_error_that_caused_it
    @client.stub_responses(:upload_part, "SlowDown")
    @client.stub_responses(:abort_multipart_upload, "InternalError")
    assert_raises(Aws::S3::Errors::SlowDown) { upload(file_of("abc")) }
  end

  # A SIGTERM or Ctrl-C is not a StandardError. Parts left behind are
  # privileged bytes no listing shows, kept until a lifecycle rule runs.
  def test_a_signal_mid_upload_still_aborts_the_upload
    [Interrupt, SignalException, NoMemoryError].each do |klass|
      @client.api_requests.clear
      @client.stub_responses(:upload_part, [{ etag: '"etag-1"' }, ->(_context) { raise klass, klass == SignalException ? "SIGTERM" : "stop" }])
      assert_raises(klass) { upload(file_of("x" * (PART + 1))) }
      assert_equal %i[create_multipart_upload upload_part upload_part abort_multipart_upload], operations, klass.name
    end
  end

  def test_a_signal_during_completion_aborts_the_upload
    @client.stub_responses(:complete_multipart_upload, ->(_context) { raise Interrupt })
    assert_raises(Interrupt) { upload(file_of("abc")) }
    assert_equal :abort_multipart_upload, operations.last
  end

  def test_a_completed_upload_is_not_aborted
    stored!(3)
    upload(file_of("abc"))
    refute_includes operations, :abort_multipart_upload
    refute_includes operations, :delete_object
  end

  # After completion there IS an object. Any way out of the size check that is
  # not success removes it, so no whole recording is left with no row.
  def test_a_head_object_that_raises_after_completion_removes_the_object
    { "InternalError" => Aws::S3::Errors::InternalError, ->(_context) { raise Interrupt } => Interrupt,
      ->(_context) { raise Seahorse::Client::NetworkingError.new(RuntimeError.new("reset")) } => Seahorse::Client::NetworkingError }.each do |stub, klass|
      @client.api_requests.clear
      @client.stub_responses(:head_object, stub)
      assert_raises(klass) { upload(file_of("abc")) }
      assert_equal %i[create_multipart_upload upload_part complete_multipart_upload head_object delete_object], operations, klass.name
      assert_equal "knowledge/acme/call.mp4", requests(:delete_object).first[:key]
    end
  end

  def test_a_failed_cleanup_does_not_hide_the_error_that_caused_it
    @client.stub_responses(:head_object, "SlowDown")
    @client.stub_responses(:delete_object, "InternalError")
    assert_raises(Aws::S3::Errors::SlowDown) { upload(file_of("abc")) }
  end

  def test_the_upload_has_a_deadline_read_before_each_part
    error = assert_raises(Studio::S3::Error) { upload(file_of("abc"), deadline: -1) }
    assert_match(/passed its deadline after 0 part/, error.message)
    assert_equal %i[create_multipart_upload abort_multipart_upload], operations
    assert_equal 7_200, MP::UPLOAD_DEADLINE
  end

  # One request is bounded by the SDK client, not by the uploader. The module
  # comment and the README quote these; this is where a change would show.
  def test_the_sdk_timeouts_and_retries_the_bounds_table_quotes
    Studio.s3_access_key_id = "id"
    Studio.s3_secret_access_key = "secret"
    config = MP.client.config
    assert_equal 15, config.http_open_timeout
    assert_equal 60, config.http_read_timeout
    assert_equal 3, config.retry_limit
  end

  def test_a_file_that_grows_under_the_upload_is_aborted
    path = file_of("a" * PART)
    grown = false
    @client.stub_responses(:upload_part, lambda { |_context|
      File.open(path, "ab") { |file| file.write("b" * 10) } unless grown
      grown = true
      { etag: '"etag"' }
    })
    error = assert_raises(Studio::S3::Error) { upload(path) }
    assert_match(/changed during the upload/, error.message)
    assert_equal :abort_multipart_upload, operations.last
    refute_includes operations, :complete_multipart_upload
  end

  # A file appended to on every part would otherwise be chased ten bytes at a
  # time to MAX_PARTS. A short read is the last part, whatever comes after.
  def test_a_short_part_is_the_last_part_even_when_the_file_keeps_growing
    path = file_of("a" * (PART + 7))
    @client.stub_responses(:upload_part, lambda { |_context|
      File.open(path, "ab") { |file| file.write("b" * 10) }
      { etag: '"etag"' }
    })
    assert_raises(Studio::S3::Error) { upload(path) }
    assert_equal 2, requests(:upload_part).size, "the full part, the short part, and no third"
  end

  def test_a_file_that_grows_past_the_cap_stops_at_the_cap
    path = file_of("a" * PART)
    @client.stub_responses(:upload_part, lambda { |_context|
      File.open(path, "ab") { |file| file.write("b" * PART) }
      { etag: '"etag"' }
    })
    error = assert_raises(Studio::S3::Error) { upload(path, max_bytes: PART + 10) }
    assert_match(/passed the #{PART + 10}-byte cap/, error.message)
    assert_equal 1, requests(:upload_part).size, "the part that would pass the cap is never sent"
    assert_equal :abort_multipart_upload, operations.last
  end

  def test_a_stored_size_that_differs_removes_the_object_and_raises
    stored!(2)
    error = assert_raises(Studio::S3::Error) { upload(file_of("abc")) }
    assert_match(/stored 2 bytes of 3 sent/, error.message)
    assert_equal %i[head_object delete_object], operations.last(2)
  end

  def test_an_unconfigured_app_raises_not_configured_before_reading_the_file
    Studio.s3_bucket_prefix = nil
    assert_raises(Studio::S3::NotConfigured) { upload("/no/such/file.mp4") }
  end

  # ─── checksums: the request R2 is sent ──────────────────────────────────────

  def test_the_uploaders_own_client_turns_default_checksums_off_and_keeps_studio_s3s_options
    Studio.s3_endpoint = "https://account.r2.example.com"
    Studio.s3_access_key_id = "id"
    Studio.s3_secret_access_key = "secret"
    options = MP.client_options

    assert_equal "when_required", options[:request_checksum_calculation]
    assert_equal "when_required", options[:response_checksum_validation]
    assert_equal Studio::S3.client_options, options.except(:request_checksum_calculation, :response_checksum_validation)
    assert_equal "when_required", MP.client.config.request_checksum_calculation
    assert_equal "when_required", MP.client.config.response_checksum_validation
    refute_same Studio::S3.client, MP.client, "the shared client keeps the configuration it always had"
  end

  # The headers, as built: a Content-MD5 on each part and no flexible checksum
  # on any request. Built with the uploader's own options plus stubbing, and
  # read at the last handler before the (stubbed) send.
  def test_no_request_carries_a_crc_and_every_part_carries_content_md5
    Studio.s3_endpoint = "https://account.r2.example.com"
    Studio.s3_access_key_id = "id"
    Studio.s3_secret_access_key = "secret"
    client = Aws::S3::Client.new(**MP.client_options, stub_responses: true)
    client.stub_responses(:create_multipart_upload, { upload_id: "upload-1" })
    client.stub_responses(:upload_part, { etag: '"etag"' })
    client.stub_responses(:head_object, { content_length: PART + 3 })
    sent = []
    client.handle(step: :sign, priority: 0) do |context|
      sent << [context.operation_name, context.http_request.headers.to_h, context.http_request.endpoint.to_s]
      @handler.call(context)
    end

    body = "m" * (PART + 3)
    MP.upload_file(key: "knowledge/acme/call.mp4", path: file_of(body), content_type: "video/mp4",
                   max_bytes: PART * 2, part_size: PART, client: client)

    assert_equal %i[create_multipart_upload upload_part upload_part complete_multipart_upload head_object],
                 sent.map(&:first)
    sent.each do |operation, headers, _endpoint|
      flexible = headers.keys.grep(/\Ax-amz-(?:sdk-)?checksum|\Ax-amz-trailer/i)
      assert_empty flexible, "#{operation} must send no flexible checksum header, sent #{flexible.inspect}"
    end
    parts = sent.select { |operation, _, _| operation == :upload_part }
    assert_equal [Digest::MD5.base64digest("m" * PART), Digest::MD5.base64digest("mmm")],
                 parts.map { |_, headers, _| headers["content-md5"] }
    assert(sent.all? { |_, _, endpoint| endpoint.include?("r2.example.com") })
  end

  # The control for the test above: the SDK's DEFAULT client does add one, so
  # the assertion is able to fail.
  def test_control_the_default_client_does_send_a_crc_on_a_part
    client = Aws::S3::Client.new(stub_responses: true, region: "auto")
    headers = nil
    client.handle(step: :sign, priority: 0) do |context|
      headers = context.http_request.headers.to_h
      @handler.call(context)
    end
    client.upload_part(bucket: "b", key: "k", upload_id: "u", part_number: 1, body: "abc")
    refute_empty headers.keys.grep(/\Ax-amz-(?:sdk-)?checksum/i)
  end
end
